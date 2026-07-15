;;; pipenv-outdated-test.el --- ERT tests for pipenv-outdated -*- lexical-binding: t; -*-

;;; Commentary:
;; Basic unit tests for the pure parsing/rewriting helpers.  Run them with
;; ./run-tests.sh from the repository root.  All Pipfile data comes from the
;; fictitious fixtures in tests/fixtures/.

;;; Code:

(require 'ert)
(require 'pipenv-outdated)

(defconst pipenv-outdated-test--fixture-dir
  (expand-file-name "fixtures"
                    (file-name-directory
                     (or load-file-name buffer-file-name)))
  "Directory holding the Pipfile fixtures.")

(defun pipenv-outdated-test--fixture (name)
  "Return the absolute path of the Pipfile inside fixture directory NAME."
  (expand-file-name (concat name "/Pipfile") pipenv-outdated-test--fixture-dir))

(defmacro pipenv-outdated-test--with-fixture-buffer (name &rest body)
  "Insert the NAME fixture Pipfile into a temp buffer and evaluate BODY."
  (declare (indent 1))
  `(with-temp-buffer
     (insert-file-contents (pipenv-outdated-test--fixture ,name))
     ,@body))

(defmacro pipenv-outdated-test--with-visited-fixture (name &rest body)
  "Visit the NAME fixture Pipfile in a buffer, evaluate BODY, kill the buffer."
  (declare (indent 1))
  `(let ((buffer (find-file-noselect (pipenv-outdated-test--fixture ,name))))
     (unwind-protect
         (with-current-buffer buffer
           ,@body)
       (kill-buffer buffer))))

;;; Output parsing

(ert-deftest pipenv-outdated-test-parse-skipped-format ()
  "The \"Skipped Update of Package\" line format is parsed."
  (should (equal (pipenv-outdated--parse-output
                  "Skipped Update of Package requests: 2.29.0 installed, ==2.29.0 required (==2.29.0 set in Pipfile), 2.30.0 available.")
                 '(("requests" . "2.30.0")))))

(ert-deftest pipenv-outdated-test-parse-out-of-date-format ()
  "The \"Package 'foo' out-of-date\" line format is parsed."
  (should (equal (pipenv-outdated--parse-output
                  "Package 'pytest' out-of-date: <Version('7.4.0')> installed, <Version('8.0.0')> available.")
                 '(("pytest" . "8.0.0")))))

(ert-deftest pipenv-outdated-test-parse-mixed-output ()
  "Noise lines are ignored and both formats parse from one blob."
  (should (equal (pipenv-outdated--parse-output
                  (concat "Building requirements...\n"
                          "Resolving dependencies...\n"
                          "Skipped Update of Package requests: 2.29.0 installed, 2.30.0 available.\n"
                          "Package 'pytest' out-of-date: '7.4.0' installed, '8.0.0' available.\n"))
                 '(("requests" . "2.30.0")
                   ("pytest" . "8.0.0")))))

(ert-deftest pipenv-outdated-test-parse-wrapped-lines ()
  "Lines wrapped by pipenv are re-joined before parsing."
  (should (equal (pipenv-outdated--parse-output
                  (concat "Skipped Update of Package requests: 2.29.0 installed,\n"
                          "   ==2.29.0 required,\n"
                          "   2.30.0 available.\n"))
                 '(("requests" . "2.30.0")))))

(ert-deftest pipenv-outdated-test-parse-json-output ()
  "The pip list --outdated --format=json fast path is parsed."
  (should (equal (pipenv-outdated--parse-output
                  "[{\"name\": \"requests\", \"version\": \"2.29.0\", \"latest_version\": \"2.30.0\", \"latest_filetype\": \"wheel\"}]")
                 '(("requests" . "2.30.0")))))

(ert-deftest pipenv-outdated-test-parse-empty-output ()
  "Empty or unparseable output yields an empty result."
  (should (null (pipenv-outdated--parse-output "")))
  (should (null (pipenv-outdated--parse-output "✔ Success!\n"))))

(ert-deftest pipenv-outdated-test-resolution-conflict-summary ()
  "Resolver conflicts are condensed into a one-line summary."
  (should (equal (pipenv-outdated--extract-resolution-conflict
                  (concat "ERROR: Cannot install ...\n"
                          "The user requested requests==2.31.0\n"
                          "acme-billing-client 1.2.3 depends on requests<2.30\n"))
                 "Dependency conflict: requests==2.31.0 conflicts with acme-billing-client 1.2.3 (requires requests<2.30)"))
  (should (null (pipenv-outdated--extract-resolution-conflict "some other failure"))))

;;; Pipfile parsing

(ert-deftest pipenv-outdated-test-pipfile-buffer-p ()
  "Only buffers visiting a file named Pipfile count as Pipfile buffers."
  (pipenv-outdated-test--with-visited-fixture "basic"
    (should (pipenv-outdated--pipfile-buffer-p)))
  (with-temp-buffer
    (should-not (pipenv-outdated--pipfile-buffer-p))))

(ert-deftest pipenv-outdated-test-parse-pipfile-packages ()
  "Names from [packages] and [dev-packages] are collected, others ignored."
  (pipenv-outdated-test--with-visited-fixture "basic"
    (should (equal (sort (pipenv-outdated--parse-pipfile-packages) #'string<)
                   '("flask" "pytest" "requests" "typing_extensions")))))

(ert-deftest pipenv-outdated-test-normalize-name ()
  "Names are normalized per PEP 503."
  (should (equal (pipenv-outdated--normalize-name "Typing_Extensions") "typing-extensions"))
  (should (equal (pipenv-outdated--normalize-name "zope.interface") "zope-interface")))

(ert-deftest pipenv-outdated-test-filter-top-level-packages ()
  "Only packages declared in the Pipfile survive filtering."
  (let ((pipenv-outdated--top-level-packages '("requests" "typing_extensions")))
    (should (equal (pipenv-outdated--filter-top-level-packages
                    '(("requests" . "2.30.0")
                      ("Typing-Extensions" . "4.8.0")
                      ("urllib3" . "2.0.4")))
                   '(("requests" . "2.30.0")
                     ("Typing-Extensions" . "4.8.0"))))))

;;; Pipfile rewriting

(ert-deftest pipenv-outdated-test-apply-simple-version ()
  "Inline string pins are rewritten in place."
  (pipenv-outdated-test--with-fixture-buffer "basic"
    (should (pipenv-outdated--apply-version-to-pipfile "requests" "2.31.0"))
    (should (string-match-p "^requests = \"==2\\.31\\.0\"$" (buffer-string)))))

(ert-deftest pipenv-outdated-test-apply-table-version ()
  "Table-style pins keep their extras and only bump the version."
  (pipenv-outdated-test--with-fixture-buffer "basic"
    (should (pipenv-outdated--apply-version-to-pipfile "flask" "2.4.0"))
    (should (string-match-p
             "^flask = {version = \"==2\\.4\\.0\", extras = \\[\"async\"\\]}$"
             (buffer-string)))))

(ert-deftest pipenv-outdated-test-apply-missing-package ()
  "Applying a version for an undeclared package reports failure."
  (pipenv-outdated-test--with-fixture-buffer "basic"
    (should-not (pipenv-outdated--apply-version-to-pipfile "left-pad" "1.0.0"))))

;;; Command construction

(ert-deftest pipenv-outdated-test-codeartifact-detection ()
  "The CodeArtifact marker is detected only when present in the Pipfile."
  (pipenv-outdated-test--with-fixture-buffer "codeartifact"
    (should (pipenv-outdated--uses-aws-codeartifact-p)))
  (pipenv-outdated-test--with-fixture-buffer "basic"
    (should-not (pipenv-outdated--uses-aws-codeartifact-p))))

(ert-deftest pipenv-outdated-test-build-shell-command ()
  "The login snippet is prepended only for CodeArtifact Pipfiles."
  (let ((pipenv-outdated-aws-login-snippet "export CODEARTIFACT_TOKEN=fake-token;"))
    (pipenv-outdated-test--with-fixture-buffer "codeartifact"
      (should (equal (pipenv-outdated--build-shell-command "pipenv update --outdated")
                     "export CODEARTIFACT_TOKEN=fake-token;\npipenv update --outdated")))
    (pipenv-outdated-test--with-fixture-buffer "basic"
      (should (equal (pipenv-outdated--build-shell-command "pipenv update --outdated")
                     "pipenv update --outdated")))))

(provide 'pipenv-outdated-test)

;;; pipenv-outdated-test.el ends here
