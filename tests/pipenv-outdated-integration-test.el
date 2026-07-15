;;; pipenv-outdated-integration-test.el --- End-to-end tests via the pipenv mock -*- lexical-binding: t; -*-

;;; Commentary:
;; Runs the real async refresh flow against tests/mock/pipenv, a shell
;; script that fakes `pipenv update --outdated' output.

;;; Code:

(require 'ert)
(require 'pipenv-outdated)

(defconst pipenv-outdated-integration-test--dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing this test file.")

(ert-deftest pipenv-outdated-test-integration-refresh ()
  "A refresh spawns the mock pipenv, parses its output and filters it.
The mock reports `requests', `flask', `typing_extensions' and `moto' as
outdated; `moto' is not declared in the fixture Pipfile and must be
filtered out."
  (skip-unless (executable-find "bash"))
  (let* ((tmp (make-temp-file "pipenv-outdated-test" t))
         (pipfile (expand-file-name "Pipfile" tmp))
         (pipenv-outdated-cache-directory (expand-file-name "cache/" tmp))
         (pipenv-outdated-log-file nil)
         (pipenv-outdated-use-installed-package-check nil)
         (pipenv-outdated-command
          (format "%s update --outdated"
                  (shell-quote-argument
                   (expand-file-name "mock/pipenv"
                                     pipenv-outdated-integration-test--dir))))
         (buffer nil))
    (copy-file (expand-file-name "fixtures/basic/Pipfile"
                                 pipenv-outdated-integration-test--dir)
               pipfile)
    (unwind-protect
        (progn
          (setq buffer (find-file-noselect pipfile))
          (with-current-buffer buffer
            (pipenv-outdated-refresh t)
            (let ((deadline (+ (float-time) 10)))
              (while (and pipenv-outdated--process
                          (< (float-time) deadline))
                (accept-process-output nil 0.05)))
            (should (null pipenv-outdated--process))
            (should (eq pipenv-outdated--status 'ready))
            (should (equal pipenv-outdated--last-result
                           '(("requests" . "2.32.3")
                             ("flask" . "3.0.3")
                             ("typing_extensions" . "4.12.2"))))
            ;; One overlay per outdated package, each on its Pipfile line.
            (should (= (length pipenv-outdated--overlays) 3))
            (should (equal (sort (mapcar (lambda (ov)
                                           (save-excursion
                                             (goto-char (overlay-start ov))
                                             (thing-at-point 'symbol t)))
                                         pipenv-outdated--overlays)
                                 #'string<)
                           '("flask" "requests" "typing_extensions")))
            ;; A forced refresh (the header-line Refresh action) resets
            ;; results and highlights while the new check runs...
            (pipenv-outdated-refresh-force)
            (should (eq pipenv-outdated--status 'pending))
            (should (null pipenv-outdated--last-result))
            (should (= (length pipenv-outdated--overlays) 0))
            ;; ...and they come back once it finishes.
            (let ((deadline (+ (float-time) 10)))
              (while (and pipenv-outdated--process
                          (< (float-time) deadline))
                (accept-process-output nil 0.05)))
            (should (eq pipenv-outdated--status 'ready))
            (should (= (length pipenv-outdated--overlays) 3))
            ;; Killing a pending check by starting another one must not
            ;; pop the error buffer ("killed: 9").
            (pipenv-outdated-refresh-force)
            (pipenv-outdated-refresh-force)
            (let ((deadline (+ (float-time) 10)))
              (while (and pipenv-outdated--process
                          (< (float-time) deadline))
                (accept-process-output nil 0.05)))
            (should (eq pipenv-outdated--status 'ready))
            (should (null (get-buffer pipenv-outdated--error-buffer-name)))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (delete-directory tmp t))))

(ert-deftest pipenv-outdated-test-integration-apply-all ()
  "Apply rewrites the pins, saves, and re-checks without spurious errors.
This mirrors clicking \"Apply\" in the header line with the mode enabled,
which used to pop the error buffer via a killed duplicate check."
  (skip-unless (executable-find "bash"))
  (let* ((tmp (make-temp-file "pipenv-outdated-test" t))
         (pipfile (expand-file-name "Pipfile" tmp))
         (pipenv-outdated-cache-directory (expand-file-name "cache/" tmp))
         (pipenv-outdated-log-file nil)
         (pipenv-outdated-use-installed-package-check nil)
         (pipenv-outdated-command
          (format "%s update --outdated"
                  (shell-quote-argument
                   (expand-file-name "mock/pipenv"
                                     pipenv-outdated-integration-test--dir))))
         (buffer nil))
    (copy-file (expand-file-name "fixtures/basic/Pipfile"
                                 pipenv-outdated-integration-test--dir)
               pipfile)
    (when (get-buffer pipenv-outdated--error-buffer-name)
      (kill-buffer pipenv-outdated--error-buffer-name))
    (unwind-protect
        (progn
          (setq buffer (find-file-noselect pipfile))
          (with-current-buffer buffer
            (pipenv-outdated-mode 1)
            (let ((deadline (+ (float-time) 10)))
              (while (and pipenv-outdated--process
                          (< (float-time) deadline))
                (accept-process-output nil 0.05)))
            (should (= (length pipenv-outdated--last-result) 3))
            (pipenv-outdated-apply-all)
            (should-not (buffer-modified-p))
            (should (string-match-p "^requests = \"==2\\.32\\.3\"$" (buffer-string)))
            (should (string-match-p "version = \"==3\\.0\\.3\"" (buffer-string)))
            (should (string-match-p "^typing_extensions = \"==4\\.12\\.2\"$" (buffer-string)))
            (let ((deadline (+ (float-time) 10)))
              (while (and pipenv-outdated--process
                          (< (float-time) deadline))
                (accept-process-output nil 0.05)))
            (should (eq pipenv-outdated--status 'ready))
            (should (null (get-buffer pipenv-outdated--error-buffer-name)))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (delete-directory tmp t))))

(ert-deftest pipenv-outdated-test-integration-codeartifact-refresh ()
  "Private-index Pipfiles work end to end.
The login snippet is prepended to the executed command and the private
`acme-billing-client' package is reported alongside public ones."
  (skip-unless (executable-find "bash"))
  (let* ((tmp (make-temp-file "pipenv-outdated-test" t))
         (pipfile (expand-file-name "Pipfile" tmp))
         (pipenv-outdated-cache-directory (expand-file-name "cache/" tmp))
         (pipenv-outdated-log-file nil)
         (pipenv-outdated-use-installed-package-check nil)
         (pipenv-outdated-aws-login-snippet "export CODEARTIFACT_TOKEN=fake-token;")
         (pipenv-outdated-command
          (format "%s update --outdated"
                  (shell-quote-argument
                   (expand-file-name "mock/pipenv"
                                     pipenv-outdated-integration-test--dir))))
         (buffer nil))
    (copy-file (expand-file-name "fixtures/codeartifact/Pipfile"
                                 pipenv-outdated-integration-test--dir)
               pipfile)
    (unwind-protect
        (progn
          (setq buffer (find-file-noselect pipfile))
          (with-current-buffer buffer
            (pipenv-outdated-refresh t)
            (let ((deadline (+ (float-time) 10)))
              (while (and pipenv-outdated--process
                          (< (float-time) deadline))
                (accept-process-output nil 0.05)))
            (should (eq pipenv-outdated--status 'ready))
            ;; The CodeArtifact login snippet ran before the check.
            (should (string-prefix-p "export CODEARTIFACT_TOKEN=fake-token;"
                                     pipenv-outdated--last-command))
            (should (equal pipenv-outdated--last-result
                           '(("requests" . "2.32.3")
                             ("acme-billing-client" . "1.3.0"))))
            (should (= (length pipenv-outdated--overlays) 2))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (delete-directory tmp t))))

(provide 'pipenv-outdated-integration-test)

;;; pipenv-outdated-integration-test.el ends here
