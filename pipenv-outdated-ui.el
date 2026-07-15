;;; pipenv-outdated-ui.el --- Header line, overlays and error buffer for pipenv-outdated -*- lexical-binding: t; -*-

;;; Commentary:
;; Everything the user sees: the status header line with its clickable
;; buttons, the overlays highlighting outdated packages in the Pipfile,
;; and the buffer shown when a dependency check fails.

;;; Code:

(require 'subr-x)
(require 'pipenv-outdated-core)

;; Commands bound to the header-line buttons; defined in pipenv-outdated.el.
(declare-function pipenv-outdated-refresh-force "pipenv-outdated")
(declare-function pipenv-outdated-update-all "pipenv-outdated")
(declare-function pipenv-outdated-apply-all "pipenv-outdated")

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
  "Return LABEL propertized to invoke COMMAND when clicked."
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

(defun pipenv-outdated--clear-overlays ()
  "Delete overlays previously added by this mode."
  (mapc #'delete-overlay pipenv-outdated--overlays)
  (setq pipenv-outdated--overlays nil))

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

(provide 'pipenv-outdated-ui)

;;; pipenv-outdated-ui.el ends here
