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
;;
;; The package is split across five files:
;;   pipenv-outdated-core.el     customization, faces, state, Pipfile helpers
;;   pipenv-outdated-log.el      logging and cached-result persistence
;;   pipenv-outdated-ui.el       header line, overlays, error buffer
;;   pipenv-outdated-process.el  pipenv plumbing: commands, parsing, processes
;;   pipenv-outdated.el          orchestration, commands, minor mode

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(require 'pipenv-outdated-core)
(require 'pipenv-outdated-log)
(require 'pipenv-outdated-ui)
(require 'pipenv-outdated-process)

;;;; Pipfile package parsing

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

(defun pipenv-outdated--filter-top-level-packages (entries)
  "Keep only ENTRIES whose names appear in the Pipfile."
  (if (null pipenv-outdated--top-level-packages)
      entries
    (cl-remove-if-not
     (lambda (pkg)
       (member (pipenv-outdated--normalize-name (car pkg))
               (mapcar #'pipenv-outdated--normalize-name pipenv-outdated--top-level-packages)))
     entries)))

;;;; Pipfile version rewriting

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
  "Update the Pipfile entry for PKG to VERSION.  Return non-nil on success."
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

;;;; Check orchestration

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

(defun pipenv-outdated--handle-check-result (exit-code all-parsed output event)
  "Update cache, overlays and status after a dependency check.
Called in the Pipfile buffer with the check's EXIT-CODE, the parsed
ALL-PARSED alist, the raw OUTPUT string, and the process EVENT."
  (let* ((parsed (pipenv-outdated--filter-top-level-packages all-parsed))
         (pipfile (or (pipenv-outdated--pipfile-path) "<unknown Pipfile>"))
         (log-body (format "Directory: %s\nCommand: %s\nExit code: %s\nParsed entries: %d (matched %d)\nEvent: %s\n\nOutput:\n%s"
                           (or (pipenv-outdated--pipfile-directory) "<unknown>")
                           (or pipenv-outdated--last-command "<unknown command>")
                           exit-code
                           (length all-parsed)
                           (length parsed)
                           (string-trim event)
                           output)))
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
        (pipenv-outdated--set-status 'ready "All dependencies up to date")))))

;;;; Commands

(defun pipenv-outdated--apply-pins ()
  "Write the latest known version of every outdated package to the Pipfile.
Entries are rewritten in place, preserving their position, table style
and extras.  Return a cons cell (MODIFIED . MISSING) with the number of
rewritten entries and the names that were not found."
  (let ((modified 0)
        (missing '()))
    (save-excursion
      (save-restriction
        (widen)
        (dolist (pkg pipenv-outdated--last-result)
          (if (pipenv-outdated--apply-version-to-pipfile (car pkg) (cdr pkg))
              (setq modified (1+ modified))
            (push (car pkg) missing)))))
    (cons modified (nreverse missing))))

(defun pipenv-outdated--applied-pins-summary (applied)
  "Return a short human-readable summary of APPLIED, an (N . MISSING) cons."
  (format "%d entries%s"
          (car applied)
          (if (cdr applied)
              (format " (missing: %s)" (string-join (cdr applied) ", "))
            "")))

(defun pipenv-outdated-apply-all ()
  "Apply latest versions to the Pipfile without installing packages."
  (interactive)
  (pipenv-outdated--ensure-pipfile)
  (unless pipenv-outdated--last-result
    (user-error "No outdated package data available - run `pipenv-outdated-refresh' first"))
  (let ((applied (pipenv-outdated--apply-pins)))
    (when (and buffer-file-name (buffer-modified-p))
      ;; The forced refresh below re-checks; don't let after-save-hook
      ;; spawn a duplicate that would immediately be killed.
      (let ((pipenv-outdated--inhibit-refresh t))
        (save-buffer)))
    (pipenv-outdated-refresh-force)
    (message "pipenv-outdated: applied %s"
             (pipenv-outdated--applied-pins-summary applied))))

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
            (pipenv-outdated--set-status 'pending)
            (let ((command (pipenv-outdated--run-check
                            #'pipenv-outdated--handle-check-result)))
              (pipenv-outdated--log
               (format "Starting dependency check for %s"
                       (or (pipenv-outdated--pipfile-path) "<unknown Pipfile>"))
               (format "Command: %s\nMode: %s\nDirectory: %s"
                       command
                       (if pipenv-outdated-use-installed-package-check
                           "pip list --outdated (fast path)"
                         "pipenv update --outdated")
                       (pipenv-outdated--pipfile-directory)))
              (message "pipenv-outdated: running command:\n%s" command)
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
  "Apply the latest versions to the Pipfile, then install them.
The pins are rewritten in place first (exactly like
`pipenv-outdated-apply-all'), so entries keep their position, table
style and extras.  A single `pipenv-outdated-update-command' run then
installs from the rewritten Pipfile.  On failure the previous Pipfile
contents are restored."
  (let* ((pipfile-buffer (current-buffer))
         (packages pipenv-outdated--last-result))
    (unless (and packages (> (length packages) 0))
      (user-error "No outdated package list available - run `pipenv-outdated-refresh' first"))
    (let* ((default-directory (pipenv-outdated--pipfile-directory))
           (buffer (get-buffer-create pipenv-outdated--update-buffer-name))
           (snapshot (pipenv-outdated--read-pipfile-contents pipfile-buffer))
           (applied (pipenv-outdated--apply-pins)))
      (when (and buffer-file-name (buffer-modified-p))
        ;; The follow-up check runs from the install callback; don't let
        ;; after-save-hook spawn one that races the install.
        (let ((pipenv-outdated--inhibit-refresh t))
          (save-buffer)))
      (with-current-buffer buffer
        (read-only-mode -1)
        (erase-buffer)
        (insert (format "Applied %s to the Pipfile.\nRunning %s\n\n"
                        (pipenv-outdated--applied-pins-summary applied)
                        pipenv-outdated-update-command))
        (read-only-mode 1))
      (display-buffer buffer)
      (let ((command
             (pipenv-outdated--run-install-process
              buffer
              (lambda (proc)
                (pipenv-outdated--handle-install-result proc pipfile-buffer snapshot)))))
        (pipenv-outdated--log
         (format "Starting update install for %s"
                 (or (buffer-file-name pipfile-buffer) "<unknown Pipfile>"))
         (format "Command: %s\nDirectory: %s\nApplied: %s"
                 command
                 default-directory
                 (pipenv-outdated--applied-pins-summary applied)))))))

(defun pipenv-outdated--handle-install-result (proc pipfile-buffer snapshot)
  "Handle the finished install PROC for PIPFILE-BUFFER.
SNAPSHOT holds the pre-update Pipfile contents, restored on failure."
  (let* ((exit-code (process-exit-status proc))
         (succeeded-p (zerop exit-code))
         (buffer (process-buffer proc))
         (output (when (buffer-live-p buffer)
                   (with-current-buffer buffer
                     (buffer-string)))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (read-only-mode -1)
        (goto-char (point-max))
        (insert (format "\nInstall %s (exit %s)\n"
                        (if succeeded-p
                            "completed"
                          "failed - restoring previous Pipfile")
                        exit-code))
        (read-only-mode 1)))
    (pipenv-outdated--log
     (format "Update install finished (exit %s)" exit-code)
     output)
    (if succeeded-p
        (when (buffer-live-p pipfile-buffer)
          (with-current-buffer pipfile-buffer
            (pipenv-outdated--invalidate-cache)
            (pipenv-outdated-refresh))
          (message "pipenv-outdated: update finished successfully"))
      (when (buffer-live-p pipfile-buffer)
        (when snapshot
          ;; The restore reverts the buffer; the forced refresh below
          ;; re-checks, so silence the after-revert-hook duplicate.
          (let ((pipenv-outdated--inhibit-refresh t))
            (pipenv-outdated--restore-pipfile snapshot pipfile-buffer)))
        (with-current-buffer pipfile-buffer
          (pipenv-outdated-refresh-force))
        (message "pipenv-outdated: update failed (exit %s); previous Pipfile restored"
                 exit-code)))))

;;;###autoload
(defun pipenv-outdated-update-all ()
  "Apply the latest versions to the Pipfile and install them."
  (interactive)
  (pipenv-outdated--ensure-pipfile)
  (pipenv-outdated--run-update-command))

;;;; Minor mode

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

(provide 'pipenv-outdated)

;;; pipenv-outdated.el ends here
