;;; pipenv-outdated-process.el --- pipenv plumbing for pipenv-outdated -*- lexical-binding: t; -*-

;;; Commentary:
;; Everything that talks to pipenv: shell command construction (including
;; the AWS CodeArtifact login snippet), raw output parsing, and the
;; asynchronous process lifecycle.  The rest of the package interacts with
;; pipenv exclusively through the high-level entry points
;; `pipenv-outdated--run-check' and `pipenv-outdated--run-update-process';
;; callers receive parsed results via callbacks and never touch
;; `make-process' or raw output themselves.

;;; Code:

(require 'json)
(require 'subr-x)
(require 'pipenv-outdated-core)

;;;; Shell command construction

(defun pipenv-outdated--uses-aws-codeartifact-p ()
  "Return non-nil when the current Pipfile references aws-codeartifact."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (search-forward pipenv-outdated-codeartifact-marker nil t))))

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

;;;; Output parsing

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

;;;; Process lifecycle

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

(defun pipenv-outdated--run-check (callback)
  "Start the dependency check for the current Pipfile buffer.
Kills any check that is already running.  When the process finishes,
CALLBACK is called in the Pipfile buffer with four arguments:
EXIT-CODE, the parsed (PACKAGE . VERSION) alist, the raw OUTPUT
string, and the process EVENT.  Returns the shell command string."
  (pipenv-outdated--kill-process)
  (let* ((pipfile-buffer (current-buffer))
         (default-directory (pipenv-outdated--pipfile-directory))
         (base-command (if pipenv-outdated-use-installed-package-check
                           pipenv-outdated-installed-package-command
                         pipenv-outdated-command))
         (command (pipenv-outdated--build-shell-command base-command))
         (buffer (generate-new-buffer " *pipenv-outdated*")))
    (setq pipenv-outdated--last-command command)
    (setq pipenv-outdated--process
          (make-process
           :name "pipenv-outdated"
           :buffer buffer
           :command (pipenv-outdated--shell-command-list command)
           :noquery t
           :sentinel (lambda (proc event)
                       (when (buffer-live-p pipfile-buffer)
                         (pipenv-outdated--check-sentinel
                          pipfile-buffer proc event callback)))))
    command))

(defun pipenv-outdated--check-sentinel (buffer process event callback)
  "Collect PROCESS output on EVENT and hand the parsed result to CALLBACK.
BUFFER is the Pipfile buffer the check was started from."
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
        (funcall callback
                 exit-code
                 (pipenv-outdated--parse-output (or output ""))
                 (or output "")
                 event)))))

(defun pipenv-outdated--run-install-process (buffer callback)
  "Run `pipenv-outdated-update-command', streaming output into BUFFER.
The command receives no package arguments; it is expected to install
whatever the (already rewritten) Pipfile declares.  CALLBACK is called
with the finished process object; use `process-exit-status' on it to
decide whether the install succeeded.  Returns the shell command
string."
  (let* ((base (or (pipenv-outdated--nonempty-string pipenv-outdated-update-command)
                   (user-error "No update command configured; set `pipenv-outdated-update-command'")))
         (command (pipenv-outdated--build-shell-command base)))
    (make-process
     :name "pipenv-outdated-install"
     :buffer buffer
     :command (pipenv-outdated--shell-command-list command)
     :noquery t
     :sentinel (lambda (proc _event)
                 (when (memq (process-status proc) '(exit signal))
                   (funcall callback proc))))
    command))

(provide 'pipenv-outdated-process)

;;; pipenv-outdated-process.el ends here
