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
The mock reports `requests' and `moto' as outdated; only `requests' is
declared in the fixture Pipfile, so it alone must survive."
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
                           '(("requests" . "2.30.0"))))
            ;; The overlay sits on the requests line of the Pipfile.
            (should (= (length pipenv-outdated--overlays) 1))
            (goto-char (overlay-start (car pipenv-outdated--overlays)))
            (should (looking-at "requests = "))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (delete-directory tmp t))))

(provide 'pipenv-outdated-integration-test)

;;; pipenv-outdated-integration-test.el ends here
