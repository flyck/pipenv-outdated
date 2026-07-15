# pipenv-outdated

An Emacs minor mode that highlights **outdated dependencies directly inside a
Pipfile**. When you visit a Pipfile it runs `pipenv update --outdated` (or the
much faster `pip list --outdated`) in the background, highlights every stale
top-level dependency, shows the latest available version on hover, and offers
one-click **Update all** / **Apply** / **Refresh** actions in the header line.

- Runs fully asynchronously — Emacs never blocks while pipenv resolves.
- Results are cached per Pipfile (24h by default, invalidated on file change).
- Only top-level packages declared in `[packages]` / `[dev-packages]` are
  highlighted — transitive noise is filtered out.
- **Update all** installs packages one by one and rolls the Pipfile back to the
  last good state when a single update fails.
- **Apply** rewrites the version pins in the Pipfile without installing.
- Dependency-resolver conflicts are parsed into a one-line summary
  (`Dependency conflict: X conflicts with Y (requires Z)`) instead of a wall
  of pip output.
- Private package indexes (e.g. AWS CodeArtifact) are supported: a
  configurable login snippet is prepended to every pipenv command when the
  Pipfile references your private index.

> Nothing is hardcoded — commands, shell, cache lifetime, log file and the
> private-index login snippet are all `defcustom`s.

## Install

**Emacs 30+** with `use-package`'s built-in `:vc`:

```elisp
(add-to-list 'auto-mode-alist '("\\Pipfile\\'" . conf-mode))

(use-package pipenv-outdated
  :vc (:url "https://github.com/flyck/pipenv-outdated" :rev :newest)
  :hook (conf-mode . pipenv-outdated-maybe-enable))
```

**Emacs 29 or earlier** — same form, but with
[straight.el](https://github.com/radian-software/straight.el): swap `:vc (...)`
for `:straight (pipenv-outdated :host github :repo "flyck/pipenv-outdated")`.

**Manual clone** — clone anywhere (e.g. `~/.emacs.d/lisp/pipenv-outdated`) and
replace the recipe line with `:load-path "~/.emacs.d/lisp/pipenv-outdated"`.

## Usage

Open a Pipfile. The mode enables itself (via
`pipenv-outdated-maybe-enable`), kicks off a background check and installs a
header line:

```
pipenv-outdated: 3 outdated - Update all | Apply | Refresh
```

- Outdated dependency lines are highlighted
  (`pipenv-outdated-highlight-face`); hovering shows the latest version.
- **Update all** runs `pipenv-outdated-update-command` per package
  sequentially, rolling back the Pipfile if one fails.
- **Apply** only rewrites the pins (`pkg = "==1.2.3"`) in the buffer, for when
  you want to review before installing.
- **Refresh** re-runs the check, bypassing the cache. Also available as
  `M-x pipenv-outdated-refresh-force`.

The check re-runs automatically after every save or revert of the Pipfile.

## Configuration

```elisp
;; Faster check via `pip list --outdated` inside the existing virtualenv
;; (skips pipenv's dependency resolver):
(setq pipenv-outdated-use-installed-package-check t)

;; The commands used (defaults assume pyenv + pipenv):
(setq pipenv-outdated-command "pyenv exec pipenv update --outdated"
      pipenv-outdated-update-command "pyenv exec pipenv install --dev")

;; Cache lifetime in seconds (default: 24h):
(setq pipenv-outdated-cache-lifetime (* 60 60 24))
```

### Private indexes (AWS CodeArtifact)

When the Pipfile contains `pipenv-outdated-codeartifact-marker` (default:
`"aws-codeartifact"`), the shell snippet in
`pipenv-outdated-aws-login-snippet` is prepended to every pipenv command —
use it to obtain a fresh auth token:

```elisp
(setq pipenv-outdated-aws-login-snippet
      "export CODEARTIFACT_TOKEN=$(aws codeartifact get-authorization-token \\
         --domain YOUR_DOMAIN --domain-owner 123456789012 \\
         --query authorizationToken --output text);")
```

## Troubleshooting

Raw pipenv output for every run is appended to
`pipenv-outdated.log` inside `pipenv-outdated-cache-directory`
(set `pipenv-outdated-log-file` to nil to disable). Failures open a
`*pipenv-outdated error*` buffer with the command, exit code and full output.
