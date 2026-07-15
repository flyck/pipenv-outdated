# pipenv-outdated

[![CI](https://github.com/flyck/pipenv-outdated/actions/workflows/ci.yml/badge.svg)](https://github.com/flyck/pipenv-outdated/actions/workflows/ci.yml)
[![Emacs](https://img.shields.io/badge/Emacs-27.2%20%7C%2028.2%20%7C%2029.4%20%7C%2030.1-7F5AB6?logo=gnuemacs&logoColor=white)](https://www.gnu.org/software/emacs/)

Highlight outdated dependencies directly inside a Pipfile. When you visit a Pipfile, `pipenv
update --outdated` runs in the background and every stale top-level dependency lights up, with
one-click actions in the header line:

```
pipenv-outdated: 3 outdated - Update all | Apply | Refresh
```

## Features

- **Async & cached** — Emacs never blocks; results are cached per Pipfile (24h, invalidated when
  the Pipfile changes).
- **Update all** — installs packages one by one, rolling the Pipfile back when an update fails.
- **Apply** — rewrites version pins in the Pipfile without installing.
- **Private index support** — a configurable login snippet runs before pipenv when the Pipfile
  uses e.g. AWS CodeArtifact.

## Install & mandatory configuration

Requires Emacs 27.1+. Minor mode that can be used ontop of `conf-mode`. The defaults assume
`pyenv` + `pipenv` on your `PATH`:

```elisp
;; Mandatory: make Emacs open Pipfiles in conf-mode.
(add-to-list 'auto-mode-alist '("\\Pipfile\\'" . conf-mode))

(use-package pipenv-outdated
  :vc (:url "https://github.com/flyck/pipenv-outdated" :rev :newest)  ; Emacs 30+
  :hook (conf-mode . pipenv-outdated-maybe-enable))
```

Not using pyenv? Override the commands:

```elisp
(setq pipenv-outdated-command "pipenv update --outdated"
      pipenv-outdated-update-command "pipenv install --dev")
```

On Emacs 29 or earlier, swap `:vc (...)` for straight.el:
`:straight (pipenv-outdated :host github :repo "flyck/pipenv-outdated")`,
or clone manually and use `:load-path`.

## Optional configuration

```elisp
;; Much faster checks via `pip list --outdated` (skips pipenv's resolver):
(setq pipenv-outdated-use-installed-package-check t)

;; Cache lifetime in seconds (default: 24h):
(setq pipenv-outdated-cache-lifetime (* 60 60 24))
```

### AWS CodeArtifact credentials

If the Pipfile references a CodeArtifact source (detected via
`pipenv-outdated-codeartifact-marker`, default `"aws-codeartifact"`), the snippet in
`pipenv-outdated-aws-login-snippet` runs first so pipenv gets a fresh token. A fictitious example
for the ACME corporation:

```elisp
(setq pipenv-outdated-aws-login-snippet
      "if ! aws sts get-caller-identity --profile acme-dev --output text &>/dev/null; then
  export AWS_PROFILE=acme-dev; aws sso login;
fi;
export CODEARTIFACT_TOKEN=$(aws codeartifact get-authorization-token \\
  --domain acme --domain-owner 123456789012 --region us-east-1 \\
  --query authorizationToken --output text);")
```

with a matching Pipfile source:

```toml
[[source]]
name = "aws-codeartifact"
url = "https://acme-123456789012.d.codeartifact.us-east-1.amazonaws.com/pypi/acme-pypi/simple/"
verify_ssl = true
```

Never hardcode tokens — the snippet should fetch them at runtime.

## Troubleshooting

Raw pipenv output is logged to `pipenv-outdated.log` in `pipenv-outdated-cache-directory`;
failures open a `*pipenv-outdated error*` buffer with command, exit code and full output.

## Development

Tests are plain [ERT](https://www.gnu.org/software/emacs/manual/html_node/ert/) run via
[Eldev](https://emacs-eldev.github.io/eldev/), which auto-discovers everything under `tests/`:

```sh
eldev test                                  # unit + integration tests
eldev lint doc re package                   # checkdoc, relint, package-lint
eldev compile --set all --warnings-as-errors
```

The integration test drives the real async refresh against `tests/mock/pipenv`, a script faking
pipenv's output. CI runs the suite on Emacs 27.2, 28.2, 29.4 and 30.1.

### Demo (no pipenv required)

Open a fixture Pipfile with the check mocked — handy for screenshots:

```sh
emacs -Q -L . -l pipenv-outdated \
  --eval '(setq pipenv-outdated-command (expand-file-name "tests/mock/pipenv update --outdated"))' \
  --eval '(setq pipenv-outdated-update-command (expand-file-name "tests/mock/pipenv install --dev"))' \
  tests/fixtures/basic/Pipfile \
  -f pipenv-outdated-mode
```

All header-line actions work against the mock — "Update all" rewrites the pins in the fixture
without touching pyenv or any real environment.
