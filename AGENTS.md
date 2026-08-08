# Agent guidance

This repository is a vanilla GNU Emacs 30.2 configuration for Apple Silicon macOS.

- Keep startup files small; add behavior to the focused modules under `lisp/`.
- Keep the theme original and maintain its palette in `themes/gm-cursor-dark-theme.el`.
- Never commit `elpa/`, `.local/`, `tree-sitter/`, `var/`, native modules, JDKs, language servers, or credentials.
- Preserve the Java contract: Emacs/JDT LS use JDK 21, Metals uses JDK 17, and JDK 18 is compatibility-only.
- Keep Angular 20 on the managed `bin/ngserver-angular20` wrapper so its TypeScript and Angular probe paths remain deterministic.
- Do not add format-on-save globally. Formatting must remain explicit or project-controlled.
- Run `bin/check` after changes. In environments without the workstation dependencies, run `emacs --batch -Q -l test/run-tests.el` with Emacs 30.2.
- System cutover scripts must identify exact source and target versions and keep recoverable backups.
