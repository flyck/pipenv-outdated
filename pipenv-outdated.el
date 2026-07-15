;;; pipenv-outdated.el --- Highlight outdated Pipfile packages -*- lexical-binding: t; -*-

;; Author: Felix Brilej
;; URL: https://github.com/flyck/pipenv-outdated
;; Version: 0.1.0
;; Keywords: tools, convenience
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:
;; Provides a minor mode that checks `pyenv exec pipenv update --outdated`
;; when visiting a Pipfile, highlights stale dependencies, and exposes an
;; "Update all" action that runs `pyenv exec pipenv install --dev`.
;;
;; Enable it automatically for Pipfiles:
;;
;;   (add-to-list 'auto-mode-alist '("\\Pipfile\\'" . conf-mode))
;;   (add-hook 'conf-mode-hook #'pipenv-outdated-maybe-enable)
;;
;; Private package indexes (e.g. AWS CodeArtifact) are supported via
;; `pipenv-outdated-aws-login-snippet', which is prepended to every pipenv
;; command when the Pipfile references `pipenv-outdated-codeartifact-marker'.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

(defgroup pipenv-outdated nil
  "Highlight outdated packages listed in a Pipfile."
  :group 'tools
  :prefix "pipenv-outdated-")

(defface pipenv-outdated-highlight-face
  '((t :inherit font-lock-warning-face :weight bold))
  "Face used to highlight outdated dependency lines."
  :group 'pipenv-outdated)

(defcustom pipenv-outdated-command "pyenv exec pipenv update --outdated"
  "Shell command used to list outdated pip packages."
  :type 'string
  :group 'pipenv-outdated)

(defcustom pipenv-outdated-update-command "pyenv exec pipenv install --dev"
  "Shell command prefix used for the \"Update all\" action.

Package/version specs are appended to this command automatically."
  :type 'string
  :group 'pipenv-outdated)

(defcustom pipenv-outdated-aws-login-snippet nil
  "Shell snippet prepended before pipenv commands when using AWS CodeArtifact."
  :type 'string
  :group 'pipenv-outdated)

(defcustom pipenv-outdated-cache-directory
  (let ((base (cond
               ((boundp 'no-littering-etc-directory)
                (expand-file-name "pipenv-outdated/" no-littering-etc-directory))
               (t (locate-user-emacs-file "pipenv-outdated/")))))
    base)
  "Directory used to store cached pipenv-outdated results."
  :type 'directory
  :group 'pipenv-outdated)

(defcustom pipenv-outdated-cache-lifetime (* 60 60 24)
  "Number of seconds cached results remain valid."
  :type 'integer
  :group 'pipenv-outdated)

(defcustom pipenv-outdated-codeartifact-marker "aws-codeartifact"
  "Text searched for in the Pipfile to determine whether aws-codeartifact is used."
  :type 'string
  :group 'pipenv-outdated)

(defcustom pipenv-outdated-shell
  (or (executable-find "bash") shell-file-name)
  "Shell executable used to run pipenv commands."
  :type 'file
  :group 'pipenv-outdated)

(defcustom pipenv-outdated-log-file "pipenv-outdated.log"
  "File used to log raw pipenv stderr/stdout.
When set to a relative path the file lives inside
`pipenv-outdated-cache-directory'.  Set to nil to disable logging."
  :type '(choice (const :tag "Disable logging" nil) file)
  :group 'pipenv-outdated)

(defcustom pipenv-outdated-use-installed-package-check nil
  "When non-nil run `pipenv-outdated-installed-package-command'.
This avoids pipenv's dependency resolver by using `pip list --outdated'
inside the environment, which is usually much faster but may miss
dependency conflicts that only appear during locking."
  :type 'boolean
  :group 'pipenv-outdated)

(defcustom pipenv-outdated-installed-package-command
  "pyenv exec pipenv run python -m pip list --outdated --format=json"
  "Command used when `pipenv-outdated-use-installed-package-check' is non-nil."
  :type 'string
  :group 'pipenv-outdated)

(defvar-local pipenv-outdated--overlays nil
  "Track overlays used to highlight outdated packages.")

(defvar-local pipenv-outdated--process nil
  "The running background process for the current Pipfile buffer.")

(defvar-local pipenv-outdated--status 'idle
  "Internal status flag.")

(defvar-local pipenv-outdated--status-message nil
  "Optional status details for the header line.")

(defvar-local pipenv-outdated--last-result nil
  "Last parsed result from `pipenv update --outdated`.")

(defvar-local pipenv-outdated--saved-header nil
  "Original value of `header-line-format` before enabling the mode.")

(defvar-local pipenv-outdated--header-installed nil
  "Whether the custom header line has been installed.")

(defvar pipenv-outdated--update-buffer-name "*pipenv-outdated update*"
  "Buffer used to show the output of the update command.")

(defvar pipenv-outdated--error-buffer-name "*pipenv-outdated error*"
  "Buffer used to show dependency-check failures.")

(defvar-local pipenv-outdated--top-level-packages nil
  "Set of package names defined in the current Pipfile.")

(defvar-local pipenv-outdated--last-command nil
  "Last shell command executed for the current Pipfile.")

(defun pipenv-outdated--pipfile-path ()
  "Return the absolute path of the current Pipfile."
  (when (pipenv-outdated--pipfile-buffer-p)
    buffer-file-name))

(defun pipenv-outdated--current-pipfile-mtime ()
  "Return the float timestamp of the Pipfile's modification time."
  (when-let* ((attrs (and (pipenv-outdated--pipfile-path)
                          (file-attributes (pipenv-outdated--pipfile-path)))))
    (float-time (file-attribute-modification-time attrs))))

(defun pipenv-outdated--read-pipfile-contents (&optional buffer)
  "Return the contents of the Pipfile visited by BUFFER."
  (with-current-buffer (or buffer (current-buffer))
    (when buffer-file-name
      (let ((path buffer-file-name))
        (with-temp-buffer
          (insert-file-contents path)
          (buffer-string))))))

(defun pipenv-outdated--restore-pipfile (contents &optional buffer)
  "Restore Pipfile in BUFFER to CONTENTS."
  (when (and contents (pipenv-outdated--pipfile-buffer-p buffer))
    (with-current-buffer (or buffer (current-buffer))
      (when buffer-file-name
        (let ((path buffer-file-name))
          (with-temp-file path
            (insert contents))
          (revert-buffer t t t))))))


(defun pipenv-outdated--cache-directory ()
  "Return the cache directory, creating it if required."
  (when pipenv-outdated-cache-directory
    (make-directory pipenv-outdated-cache-directory t)
    pipenv-outdated-cache-directory))

(defun pipenv-outdated--cache-file ()
  "Return the cache file path for the current Pipfile."
  (when-let* ((dir (pipenv-outdated--cache-directory))
              (path (pipenv-outdated--pipfile-path)))
    (expand-file-name (concat (secure-hash 'sha1 path) ".eld") dir)))

(defun pipenv-outdated--write-cache (result)
  "Persist RESULT for the current Pipfile."
  (when-let* ((file (pipenv-outdated--cache-file)))
    (let ((data (list :timestamp (float-time (current-time))
                      :pipfile-mtime (pipenv-outdated--current-pipfile-mtime)
                      :result result))
          (print-length nil)
          (print-level nil))
      (with-temp-file file
        (prin1 data (current-buffer))))))

(defun pipenv-outdated--read-cache ()
  "Read the cache entry for the current Pipfile."
  (when-let* ((file (pipenv-outdated--cache-file)))
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (condition-case nil
            (read (current-buffer))
          (error nil))))))

(defun pipenv-outdated--cache-valid-p (data)
  "Return non-nil when DATA represents a valid cached result."
  (when data
    (let ((timestamp (plist-get data :timestamp))
          (pipfile-mtime (plist-get data :pipfile-mtime)))
      (and timestamp pipfile-mtime
           (< (- (float-time (current-time)) timestamp) pipenv-outdated-cache-lifetime)
           (equal pipfile-mtime (pipenv-outdated--current-pipfile-mtime))))))

(defun pipenv-outdated--invalidate-cache ()
  "Remove the cached result for the current Pipfile."
  (when-let* ((file (pipenv-outdated--cache-file)))
    (when (file-exists-p file)
      (delete-file file))))

(defun pipenv-outdated--log-file-path ()
  "Return the absolute path to the log file, creating directories when needed."
  (when pipenv-outdated-log-file
    (let* ((base (if (file-name-absolute-p pipenv-outdated-log-file)
                     pipenv-outdated-log-file
                   (expand-file-name pipenv-outdated-log-file
                                     (or (pipenv-outdated--cache-directory)
                                         (locate-user-emacs-file "pipenv-outdated/")))))
           (dir (file-name-directory base)))
      (when dir
        (make-directory dir t))
      base)))

(defun pipenv-outdated--log (title &optional body)
  "Append TITLE and optional BODY to the log file.
Returns the log file path when logging is enabled."
  (when-let* ((file (pipenv-outdated--log-file-path)))
    (with-temp-buffer
      (insert (format "[%s] %s\n"
                      (format-time-string "%Y-%m-%d %H:%M:%S")
                      title))
      (when (pipenv-outdated--nonempty-string body)
        (insert body)
        (unless (string-suffix-p "\n" body)
          (insert "\n")))
      (insert "\n")
      (write-region (point-min) (point-max) file 'append 'silent))
    file))

(defun pipenv-outdated--maybe-use-cache ()
  "Apply cached pipenv data when valid.
Returns t when cached data has been applied."
  (let ((data (pipenv-outdated--read-cache)))
    (when (pipenv-outdated--cache-valid-p data)
      (setq pipenv-outdated--last-result (pipenv-outdated--filter-top-level-packages
                                          (plist-get data :result)))
      (pipenv-outdated--apply-overlays pipenv-outdated--last-result)
      (pipenv-outdated--set-status
       'ready
       (format "Using cached data (%d outdated)"
               (length pipenv-outdated--last-result)))
      t)))

(defun pipenv-outdated--nonempty-string (value)
  "Return VALUE when it is a non-empty string, otherwise nil."
  (when (and (stringp value) (not (string-empty-p value)))
    value))

(defun pipenv-outdated--pipfile-buffer-p (&optional buffer)
  "Return non-nil when BUFFER (or the current buffer) visits a Pipfile."
  (with-current-buffer (or buffer (current-buffer))
    (and buffer-file-name
         (string-match-p (rx "Pipfile" string-end) buffer-file-name))))

(defun pipenv-outdated--ensure-pipfile ()
  "Signal an error when the current buffer is not a Pipfile."
  (unless (pipenv-outdated--pipfile-buffer-p)
    (user-error "Not a Pipfile buffer; pipenv-outdated-mode requires one")))

(defun pipenv-outdated--pipfile-directory ()
  "Return the directory containing the current Pipfile."
  (file-name-directory (buffer-file-name)))

(defun pipenv-outdated--uses-aws-codeartifact-p ()
  "Return non-nil when the current Pipfile references aws-codeartifact."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (search-forward pipenv-outdated-codeartifact-marker nil t))))

(defun pipenv-outdated--clear-overlays ()
  "Delete overlays previously added by this mode."
  (mapc #'delete-overlay pipenv-outdated--overlays)
  (setq pipenv-outdated--overlays nil))

(defun pipenv-outdated--install-header ()
  "Install the header line used to surface mode status."
  (unless pipenv-outdated--header-installed
    (setq pipenv-outdated--saved-header header-line-format)
    (setq-local header-line-format '(:eval (pipenv-outdated--header-line)))
    (setq pipenv-outdated--header-installed t)))

(defun pipenv-outdated--remove-header ()
  "Restore the header line that was present before enabling the mode."
  (when pipenv-outdated--header-installed
    (setq header-line-format pipenv-outdated--saved-header)
    (setq pipenv-outdated--saved-header nil)
    (setq pipenv-outdated--header-installed nil)))

(defun pipenv-outdated--header-line ()
  "Render the header line content."
  (let* ((prefix (propertize "pipenv-outdated" 'face 'mode-line-buffer-id))
         (message (or pipenv-outdated--status-message "")))
    (pcase pipenv-outdated--status
      ('pending (format "%s: checking... %s" prefix message))
      ('error (format "%s: %s" prefix message))
      (_
       (let ((refresh-button (pipenv-outdated--header-button "Refresh" #'pipenv-outdated-refresh-force)))
         (if (and pipenv-outdated--last-result
                  (> (length pipenv-outdated--last-result) 0))
             (format "%s: %d outdated - %s | %s | %s"
                     prefix
                     (length pipenv-outdated--last-result)
                     (pipenv-outdated--header-button "Update all" #'pipenv-outdated-update-all)
                     (pipenv-outdated--header-button "Apply" #'pipenv-outdated-apply-all)
                     refresh-button)
           (format "%s: %s | %s" prefix
                   (if (string-empty-p message) "All dependencies up to date" message)
                   refresh-button)))))))

(defun pipenv-outdated--header-button (label command)
  "Return LABEL propertized so that COMMAND runs when clicked."
  (let ((map (make-sparse-keymap)))
    (define-key map [header-line mouse-1] command)
    (define-key map [header-line mouse-2] command)
    (define-key map (kbd "RET") command)
    (propertize label
                'face 'link
                'mouse-face 'mode-line-highlight
                'help-echo (format "mouse-1: %s" label)
                'local-map map)))

(defun pipenv-outdated--set-status (status &optional message)
  "Set STATUS and optional MESSAGE for the header line."
  (setq pipenv-outdated--status status
        pipenv-outdated--status-message message)
  (force-mode-line-update))

(defvar pipenv-outdated--inhibit-refresh nil
  "When non-nil, `pipenv-outdated-refresh' does nothing.
Bound around saves performed by this package so `after-save-hook' does
not spawn a duplicate check.")

(defun pipenv-outdated--kill-process ()
  "Stop a running background process, if any.
The sentinel is detached first so the intentional kill is not reported
as a dependency-check failure."
  (when (process-live-p pipenv-outdated--process)
    (set-process-sentinel
     pipenv-outdated--process
     (lambda (proc _event)
       (when (buffer-live-p (process-buffer proc))
         (kill-buffer (process-buffer proc)))))
    (kill-process pipenv-outdated--process))
  (setq pipenv-outdated--process nil))

(defun pipenv-outdated--build-shell-command (base-command)
  "Construct the shell command string for BASE-COMMAND."
  (let* ((aws-snippet (when (and (pipenv-outdated--uses-aws-codeartifact-p)
                                 (pipenv-outdated--nonempty-string pipenv-outdated-aws-login-snippet))
                        pipenv-outdated-aws-login-snippet))
         (parts (delq nil (list aws-snippet base-command))))
    (mapconcat #'identity parts "\n")))

(defun pipenv-outdated--shell-command-list (command)
  "Return the program/arguments list to execute COMMAND through the shell."
  (list (or pipenv-outdated-shell shell-file-name "/bin/sh") "-lc" command))

(defun pipenv-outdated--build-update-command-line (package)
  "Return the update command string for a single PACKAGE cons cell."
  (unless (and package (car package) (cdr package))
    (user-error "Invalid package entry: %S" package))
  (let ((prefix (pipenv-outdated--nonempty-string pipenv-outdated-update-command)))
    (unless prefix
      (user-error "No update command configured; set `pipenv-outdated-update-command'"))
    (format "%s %s"
            prefix
            (shell-quote-argument (format "%s==%s" (car package) (cdr package))))))

(defun pipenv-outdated--join-wrapped-lines (output)
  "Join lines in OUTPUT that are continuations of a previous entry.
pipenv wraps long lines; a continuation starts with whitespace or
does not begin with \"Skipped\" / \"Package\" / a known header word."
  (let ((lines (split-string output "\n"))
        (joined nil)
        (current ""))
    (dolist (line lines)
      (if (string-match "^\\(Skipped\\|Package\\|Building\\|Resolving\\|Locking\\|Success\\|✔\\)" (string-trim line))
          (progn
            (unless (string-empty-p (string-trim current))
              (push current joined))
            (setq current line))
        (setq current (concat current " " (string-trim line)))))
    (unless (string-empty-p (string-trim current))
      (push current joined))
    (string-join (nreverse joined) "\n")))

(defun pipenv-outdated--parse-json-output (output)
  "Parse OUTPUT produced by `pip list --outdated --format=json'."
  (condition-case err
      (let* ((data (json-parse-string output
                                      :object-type 'plist
                                      :array-type 'list
                                      :null-object nil
                                      :false-object nil))
             (result nil))
        (dolist (entry data (nreverse result))
          (let ((name (plist-get entry :name))
                (latest (or (plist-get entry :latest_version)
                            (plist-get entry :latest-version))))
            (when (and name latest)
              (push (cons name latest) result)))))
    (error
     (message "pipenv-outdated: failed to parse JSON output: %s"
              (error-message-string err))
     nil)))

(defun pipenv-outdated--parse-output (output)
  "Parse OUTPUT from `pipenv update --outdated` into an alist.
Handles two line formats:
  Skipped Update of Package foo: 1.0 installed, ... required ..., 2.0 available.
  Package \"foo\" out-of-date: \"1.0\" installed, \"2.0\" available."
  (let* ((trimmed (string-trim-left output))
         (json-output (and (> (length trimmed) 0)
                           (eq (aref trimmed 0) ?\[))))
    (if json-output
        (pipenv-outdated--parse-json-output (string-trim output))
      (let ((lines (split-string (pipenv-outdated--join-wrapped-lines output) "\n"))
            (result nil))
        (dolist (line lines)
          (let ((line-trimmed (string-trim line)))
            (cond
             ((string-match
               "Skipped Update of Package \\([^:]+\\):.*,[ \t]*\\([^ \t]+\\) available"
               line-trimmed)
              (push (cons (string-trim (match-string 1 line-trimmed))
                          (string-trim (match-string 2 line-trimmed) "[ \t.]+"))
                    result))
             ((string-match
               "Package '\\([^']+\\)' out-of-date:.*[,' (]\\([0-9][^') ]*\\)[') >]* available"
               line-trimmed)
              (push (cons (match-string 1 line-trimmed)
                          (string-trim (match-string 2 line-trimmed) "[ \t.]+"))
                     result)))))
        (nreverse result)))))

(defun pipenv-outdated--extract-resolution-conflict (output)
  "Return a concise dependency conflict summary parsed from OUTPUT.
Return nil when OUTPUT does not contain a recognizable resolver conflict."
  (when output
    (let ((requested nil)
          (dependency nil)
          (lines (split-string output "\n" t)))
      (dolist (line lines)
        (let ((trimmed (string-trim line)))
          (cond
           ((and (null requested)
                 (string-match "The user requested \\(.+\\)" trimmed))
            (setq requested (string-trim (match-string 1 trimmed))))
           ((and (null dependency)
                 (string-match "\\([^ ]+\\)[[:space:]]+\\([^[:space:]]+\\)[[:space:]]+depends on \\(.+\\)" trimmed))
            (setq dependency
                  (list (match-string 1 trimmed)
                        (match-string 2 trimmed)
                        (string-trim (match-string 3 trimmed))))))))
      (when (and requested dependency)
        (format "Dependency conflict: %s conflicts with %s %s (requires %s)"
                requested
                (nth 0 dependency)
                (nth 1 dependency)
                (nth 2 dependency))))))

(defun pipenv-outdated--show-error-buffer (pipfile exit-code event output)
  "Show a buffer with failure details for PIPFILE.
EXIT-CODE, EVENT and OUTPUT come from the failed check process."
  (let ((buffer (get-buffer-create pipenv-outdated--error-buffer-name))
        (directory (and pipfile (file-name-directory pipfile)))
        (command pipenv-outdated--last-command))
    (with-current-buffer buffer
      (read-only-mode -1)
      (erase-buffer)
      (insert (format "pipenv-outdated failed for %s\n\n"
                      (or pipfile "<unknown Pipfile>")))
      (insert (format "Directory: %s\n"
                      (or directory "<unknown>")))
      (insert (format "Command: %s\n"
                      (or command "<unknown command>")))
      (insert (format "Exit code: %s\n" exit-code))
      (insert (format "Event: %s\n\n" (string-trim (or event ""))))
      (when-let* ((summary (pipenv-outdated--extract-resolution-conflict output)))
        (insert (format "Summary: %s\n\n" summary)))
      (insert "Output:\n\n")
      (insert (or output ""))
      (goto-char (point-min))
      (view-mode 1))
    (display-buffer buffer)
    buffer))

(defun pipenv-outdated--error-status-message (output)
  "Return the user-facing error status message for OUTPUT."
  (or (pipenv-outdated--extract-resolution-conflict output)
      "Command failed; see *pipenv-outdated error*"))

(defun pipenv-outdated--apply-overlays (packages)
  "Highlight PACKAGES entries in the current Pipfile."
  (pipenv-outdated--clear-overlays)
  (when packages
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (dolist (pkg packages)
          (goto-char (point-min))
          (let* ((case-fold-search t)
                 (normalized (replace-regexp-in-string
                              "[-_.]" "[-_.]"
                              (regexp-quote (car pkg))))
                 (regex (format "^[[:space:]]*%s[[:space:]]*=" normalized)))
            (while (re-search-forward regex nil t)
              (let ((ov (make-overlay (line-beginning-position) (line-end-position))))
                (overlay-put ov 'face 'pipenv-outdated-highlight-face)
                (overlay-put ov 'help-echo (format "Latest available: %s" (cdr pkg)))
                (push ov pipenv-outdated--overlays)))))))))

(defun pipenv-outdated--process-sentinel (buffer process event)
  "Sentinel for BUFFER's PROCESS responding to EVENT."
  (when (and (buffer-live-p buffer)
             (memq (process-status process) '(exit signal)))
    (let ((exit-code (process-exit-status process))
          (output (when (buffer-live-p (process-buffer process))
                    (with-current-buffer (process-buffer process)
                      (buffer-string)))))
      (when (buffer-live-p (process-buffer process))
        (kill-buffer (process-buffer process)))
      (with-current-buffer buffer
        (setq pipenv-outdated--process nil)
        (let* ((all-parsed (pipenv-outdated--parse-output (or output "")))
               (parsed (pipenv-outdated--filter-top-level-packages all-parsed))
               (pipfile (or (pipenv-outdated--pipfile-path) "<unknown Pipfile>"))
               (log-body (format "Directory: %s\nCommand: %s\nExit code: %s\nParsed entries: %d (matched %d)\nEvent: %s\n\nOutput:\n%s"
                                 (or (pipenv-outdated--pipfile-directory) "<unknown>")
                                 (or pipenv-outdated--last-command "<unknown command>")
                                 exit-code
                                 (length all-parsed)
                                 (length parsed)
                                 (string-trim event)
                                 (or output ""))))
          (pipenv-outdated--log
           (format "Finished dependency check for %s" pipfile)
           log-body)
          (message "pipenv-outdated: parsed %d entries, %d matched Pipfile: %s"
                   (length all-parsed)
                   (length parsed)
                   (mapcar #'car parsed))
          ;; pipenv update --outdated exits non-zero when outdated packages exist,
          ;; so only treat it as a real error when nothing was parsed.
           (if (and (not (zerop exit-code)) (null parsed))
               (progn
                 (pipenv-outdated--clear-overlays)
                 (let* ((log-path (pipenv-outdated--log-file-path))
                        (status-message (pipenv-outdated--error-status-message output)))
                   (pipenv-outdated--show-error-buffer pipfile exit-code event output)
                   (message "pipenv-outdated: dependency check failed (exit %s)%s"
                            exit-code
                            (if log-path
                                (format "; see %s" (abbreviate-file-name log-path))
                              ""))
                  (pipenv-outdated--set-status 'error status-message)))
            (setq pipenv-outdated--last-result parsed)
            (pipenv-outdated--write-cache pipenv-outdated--last-result)
            (pipenv-outdated--apply-overlays pipenv-outdated--last-result)
            (if pipenv-outdated--last-result
                (pipenv-outdated--set-status 'ready (format "%d outdated packages" (length pipenv-outdated--last-result)))
              (pipenv-outdated--set-status 'ready "All dependencies up to date"))))))))

(defun pipenv-outdated-apply-all ()
  "Apply latest versions to the Pipfile without installing packages."
  (interactive)
  (pipenv-outdated--ensure-pipfile)
  (unless pipenv-outdated--last-result
    (user-error "No outdated package data available - run `pipenv-outdated-refresh' first"))
  (let ((modified 0)
        (missing '()))
    (save-excursion
      (save-restriction
        (widen)
        (dolist (pkg pipenv-outdated--last-result)
          (if (pipenv-outdated--apply-version-to-pipfile (car pkg) (cdr pkg))
              (setq modified (1+ modified))
            (push (car pkg) missing)))))
    (when (and buffer-file-name (buffer-modified-p))
      ;; The forced refresh below re-checks; don't let after-save-hook
      ;; spawn a duplicate that would immediately be killed.
      (let ((pipenv-outdated--inhibit-refresh t))
        (save-buffer)))
    (pipenv-outdated-refresh-force)
    (message "pipenv-outdated: applied %d entries%s"
             modified
             (if missing
                 (format " (missing: %s)" (string-join (nreverse missing) ", "))
               ""))))

;;;###autoload
(cl-defun pipenv-outdated-refresh (&optional force)
  "Refresh the outdated package information for the current buffer's Pipfile.
When FORCE is non-nil, bypasses any cached pip output."
  (interactive "P")
  (when pipenv-outdated--inhibit-refresh
    (cl-return-from pipenv-outdated-refresh))
  (if (pipenv-outdated--pipfile-buffer-p)
      (progn
        (pipenv-outdated--update-top-level-packages)
        (let ((using-cache (and (not force) (pipenv-outdated--maybe-use-cache))))
          (unless using-cache
            (pipenv-outdated--kill-process)
            (pipenv-outdated--set-status 'pending)
            (let* ((pipfile-buffer (current-buffer))
                   (default-directory (pipenv-outdated--pipfile-directory))
                   (base-command (if pipenv-outdated-use-installed-package-check
                                     pipenv-outdated-installed-package-command
                                   pipenv-outdated-command))
                   (command (pipenv-outdated--build-shell-command base-command))
                   (buffer (generate-new-buffer " *pipenv-outdated*")))
              (setq pipenv-outdated--last-command command)
              (pipenv-outdated--log
               (format "Starting dependency check for %s"
                       (or (pipenv-outdated--pipfile-path) "<unknown Pipfile>"))
               (format "Command: %s\nMode: %s\nDirectory: %s"
                       command
                       (if pipenv-outdated-use-installed-package-check
                           "pip list --outdated (fast path)"
                         "pipenv update --outdated")
                       default-directory))
              (message "pipenv-outdated: running command:\n%s" command)
              (setq pipenv-outdated--process
                    (make-process
                     :name "pipenv-outdated"
                     :buffer buffer
                     :command (pipenv-outdated--shell-command-list command)
                     :noquery t
                     :sentinel (lambda (proc event)
                                 (when (buffer-live-p pipfile-buffer)
                                   (pipenv-outdated--process-sentinel pipfile-buffer proc event)))))
              (message "pipenv-outdated: checking for outdated packages...")))))
    (message "pipenv-outdated: not a Pipfile buffer; refresh skipped")))

(defun pipenv-outdated-refresh-force ()
  "Refresh outdated packages ignoring any cached value.
Unlike automatic refreshes, this clears the current results and
highlights while the new check runs."
  (interactive)
  (if (pipenv-outdated--pipfile-buffer-p)
      (progn
        (pipenv-outdated--invalidate-cache)
        (pipenv-outdated--clear-overlays)
        (setq pipenv-outdated--last-result nil)
        (pipenv-outdated-refresh t))
    (message "pipenv-outdated: not a Pipfile buffer; refresh skipped")))

(defun pipenv-outdated--run-update-command ()
  "Execute the update command sequentially for each outdated package."
  (let* ((pipfile-buffer (current-buffer))
         (packages pipenv-outdated--last-result))
    (unless (and packages (> (length packages) 0))
      (user-error "No outdated package list available - run `pipenv-outdated-refresh' first"))
    (let* ((default-directory (pipenv-outdated--pipfile-directory))
           (buffer (get-buffer-create pipenv-outdated--update-buffer-name))
           (snapshot (pipenv-outdated--read-pipfile-contents pipfile-buffer)))
      (with-current-buffer buffer
        (read-only-mode -1)
        (erase-buffer)
        (insert "Running sequential updates:\n\n")
        (read-only-mode 1))
      (display-buffer buffer)
      (pipenv-outdated--run-update-sequence packages pipfile-buffer buffer 0 0 snapshot))))

(defun pipenv-outdated--run-update-sequence (queue pipfile-buffer buffer success failure snapshot)
  "Helper used by `pipenv-outdated--run-update-command'.
Installs the QUEUE of packages one by one for PIPFILE-BUFFER, logging
progress to BUFFER and counting SUCCESS and FAILURE outcomes.  SNAPSHOT
holds the last good Pipfile contents used for rollback on failure."
  (if (null queue)
      (progn
        (message "pipenv-outdated: update finished (%d succeeded, %d failed)" success failure)
        (when (buffer-live-p pipfile-buffer)
          (with-current-buffer pipfile-buffer
            (pipenv-outdated--invalidate-cache)
            (pipenv-outdated-refresh))))
    (let* ((pkg (car queue))
           (pkg-name (car pkg))
           (command (pipenv-outdated--build-shell-command
                     (pipenv-outdated--build-update-command-line pkg))))
      (with-current-buffer buffer
        (read-only-mode -1)
        (goto-char (point-max))
        (insert (format "-> %s\n" pkg-name))
        (read-only-mode 1))
      (make-process
       :name (format "pipenv-outdated-update-%s" pkg-name)
       :buffer buffer
       :command (pipenv-outdated--shell-command-list command)
       :sentinel
       (lambda (proc _event)
         (let ((succeeded-p (zerop (process-exit-status proc)))
               (next-snapshot snapshot))
           (when (buffer-live-p (process-buffer proc))
             (with-current-buffer (process-buffer proc)
               (read-only-mode -1)
               (goto-char (point-max))
               (insert (format "\n[%s] %s (exit %s)\n"
                               pkg-name
                               (if succeeded-p "completed" "failed")
                               (process-exit-status proc)))
               (read-only-mode 1)))
           (if succeeded-p
               (when (buffer-live-p pipfile-buffer)
                 (setq next-snapshot (pipenv-outdated--read-pipfile-contents pipfile-buffer))
                 (pipenv-outdated--invalidate-cache)
                 (pipenv-outdated-refresh))
             (when (and snapshot (buffer-live-p pipfile-buffer))
               (pipenv-outdated--restore-pipfile snapshot pipfile-buffer)
               (with-current-buffer pipfile-buffer
                 (setq pipenv-outdated--last-result
                       (cons pkg pipenv-outdated--last-result))
                 (pipenv-outdated--apply-overlays pipenv-outdated--last-result)
                 (pipenv-outdated--set-status 'ready
                                              (format "%d outdated packages"
                                                      (length pipenv-outdated--last-result))))
               (pipenv-outdated-refresh-force)))
           (pipenv-outdated--run-update-sequence
            (cdr queue) pipfile-buffer buffer
            (if succeeded-p (1+ success) success)
            (if succeeded-p failure (1+ failure))
            next-snapshot)))))))

;;;###autoload
(defun pipenv-outdated-update-all ()
  "Run `pipenv-outdated-update-command' and refresh highlights afterwards."
  (interactive)
  (pipenv-outdated--ensure-pipfile)
  (pipenv-outdated--run-update-command))

(defun pipenv-outdated--enable ()
  "Internal helper to enable the mode."
  (pipenv-outdated--install-header)
  (add-hook 'after-save-hook #'pipenv-outdated-refresh nil t)
  (add-hook 'after-revert-hook #'pipenv-outdated-refresh nil t)
  (pipenv-outdated-refresh))

(defun pipenv-outdated--disable ()
  "Internal helper to disable the mode."
  (remove-hook 'after-save-hook #'pipenv-outdated-refresh t)
  (remove-hook 'after-revert-hook #'pipenv-outdated-refresh t)
  (pipenv-outdated--kill-process)
  (pipenv-outdated--clear-overlays)
  (setq pipenv-outdated--last-result nil)
  (pipenv-outdated--remove-header)
  (pipenv-outdated--set-status 'idle))

;;;###autoload
(define-minor-mode pipenv-outdated-mode
  "Minor mode that highlights outdated packages inside a Pipfile."
  :lighter " Pip^"
  (if pipenv-outdated-mode
      (progn
        (pipenv-outdated--ensure-pipfile)
        (pipenv-outdated--enable))
    (pipenv-outdated--disable)))

;;;###autoload
(defun pipenv-outdated-maybe-enable ()
  "Enable `pipenv-outdated-mode' when visiting a Pipfile."
  (when (pipenv-outdated--pipfile-buffer-p)
    (pipenv-outdated-mode 1)))

(defun pipenv-outdated--parse-pipfile-packages ()
  "Return names declared in the Pipfile's packages sections."
  (when (pipenv-outdated--pipfile-buffer-p)
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (let ((case-fold-search t)
              (section nil)
              (names '()))
          (while (not (eobp))
            (cond
             ((looking-at "^[ \t]*#"))
             ((looking-at "^[ \t]*\\[\\([^]]+\\)\\]")
              (setq section (downcase (match-string 1))))
             ((and (member section '("packages" "dev-packages"))
                   (looking-at "^[ \t]*\\([^=\n[:space:]]+\\)[ \t]*="))
              (push (downcase (match-string 1)) names)))
            (forward-line 1))
          names)))))

(defun pipenv-outdated--update-top-level-packages ()
  "Refresh the cached list of Pipfile package names."
  (setq pipenv-outdated--top-level-packages
        (pipenv-outdated--parse-pipfile-packages)))

(defun pipenv-outdated--normalize-name (name)
  "Normalize NAME per PEP 503: lowercase and replace underscores/dots with hyphens."
  (replace-regexp-in-string "[_.]" "-" (downcase name)))

(defun pipenv-outdated--filter-top-level-packages (entries)
  "Keep only ENTRIES whose names appear in the Pipfile."
  (if (null pipenv-outdated--top-level-packages)
      entries
    (cl-remove-if-not
     (lambda (pkg)
       (member (pipenv-outdated--normalize-name (car pkg))
               (mapcar #'pipenv-outdated--normalize-name pipenv-outdated--top-level-packages)))
     entries)))

(defun pipenv-outdated--replace-simple-version (line-end version)
  "Replace inline string spec before LINE-END with VERSION."
  (when (re-search-forward "\"[^\"]+\"" line-end t)
    (replace-match (format "\"==%s\"" version) t t)
    t))

(defun pipenv-outdated--replace-table-version (line-end version)
  "Replace table-style version spec before LINE-END with VERSION."
  (when (re-search-forward "version[ \t]*=[ \t]*\"[^\"]+\"" line-end t)
    (replace-match (format "version = \"==%s\"" version) t t)
    t))

(defun pipenv-outdated--apply-version-to-pipfile (pkg version)
  "Update the Pipfile entry for PKG to VERSION.  Returns non-nil on success."
  (let ((case-fold-search nil)
        (name (regexp-quote pkg))
        (found nil))
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (while (and (not found) (re-search-forward (format "^[ \t]*%s[ \t]*=" name) nil t))
          (let ((line-end (line-end-position)))
            (setq found (or (pipenv-outdated--replace-table-version line-end version)
                            (pipenv-outdated--replace-simple-version line-end version)))))))
    found))

(provide 'pipenv-outdated)

;;; pipenv-outdated.el ends here
