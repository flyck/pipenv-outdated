;;; pipenv-outdated-core.el --- Customization and shared helpers for pipenv-outdated -*- lexical-binding: t; -*-

;;; Commentary:
;; Customization options, faces, buffer-local state, and small Pipfile
;; helpers shared by the other pipenv-outdated files.  This file must not
;; require any other pipenv-outdated file.

;;; Code:

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

(defvar pipenv-outdated--inhibit-refresh nil
  "When non-nil, `pipenv-outdated-refresh' does nothing.
Bound around saves performed by this package so `after-save-hook' does
not spawn a duplicate check.")

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

(defun pipenv-outdated--pipfile-path ()
  "Return the absolute path of the current Pipfile."
  (when (pipenv-outdated--pipfile-buffer-p)
    buffer-file-name))

(defun pipenv-outdated--pipfile-directory ()
  "Return the directory containing the current Pipfile."
  (file-name-directory (buffer-file-name)))

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

(defun pipenv-outdated--normalize-name (name)
  "Normalize NAME per PEP 503: lowercase and replace underscores/dots with hyphens."
  (replace-regexp-in-string "[_.]" "-" (downcase name)))

(provide 'pipenv-outdated-core)

;;; pipenv-outdated-core.el ends here
