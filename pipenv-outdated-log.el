;;; pipenv-outdated-log.el --- Logging and result caching for pipenv-outdated -*- lexical-binding: t; -*-

;;; Commentary:
;; Persistence layer: the raw-output log file and the cached dependency
;; check results.  Both live under `pipenv-outdated-cache-directory'.

;;; Code:

(require 'subr-x)
(require 'pipenv-outdated-core)

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

(provide 'pipenv-outdated-log)

;;; pipenv-outdated-log.el ends here
