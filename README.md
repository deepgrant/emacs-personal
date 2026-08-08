# gm Emacs workstation

A reproducible GNU Emacs 30.2 configuration for Apple Silicon macOS. It uses a
Cursor Dark-inspired theme, Menlo 12, a project explorer, editor tabs, search and
terminal panels, language servers, debugging, Git tooling, and hybrid macOS/Emacs
keybindings.

## Supported languages

Scala, Python, TypeScript/TSX, Angular 20, Java, Groovy, Gradle, Bash, YAML,
HOCON, JSON, and Swift are configured. Tree-sitter is used where GNU Emacs 30
provides a corresponding major mode; LSP Mode supplies IDE navigation,
completion, diagnostics, actions, and debugger integration.

## First installation

The bootstrap installs Homebrew dependencies, the Node 24 language-server
toolchain, Metals 1.6.8, Emacs packages, and Tree-sitter grammars:

```bash
./bin/bootstrap-macos
```

It deliberately does not alter `/Applications` or `/Library`. After bootstrap,
register the JDKs and cut over the GUI application:

```bash
./bin/register-jdks-macos
./bin/cutover-emacs-macos
./bin/check
```

The JDK registration command uses `sudo` only for three explicit symlinks under
`/Library/Java/JavaVirtualMachines`. The cutover command accepts only a verified
Emacs Plus 30.2 build and a known Emacs 26.1 or 30.2 destination. It stages and
validates the new app before moving the previous app to the Trash.

### Rollback

If the new application must be rolled back, quit Emacs, move
`/Applications/Emacs.app` aside, and restore the timestamped Emacs 26.1 bundle
from `~/.Trash`. Runtime caches under `elpa/`, `tree-sitter/`, `var/`, `.local/`,
and `tools/node_modules/` can be discarded and rebuilt; none are tracked by Git.

## Java policy

| Version | Purpose |
|---|---|
| OpenJDK 17 | Metals and Java 17 projects |
| OpenJDK 18 | Legacy compilation and testing only |
| OpenJDK 21 | Default Emacs runtime, JDT LS, Groovy, and fallback projects |

Java 18 is an archived, non-LTS release. The bootstrap preserves the existing
Homebrew 18.0.2 bundle independently under `~/.local/share/jdks`; if it is
absent, it installs the official OpenJDK 18.0.2+9 archive after SHA-256
verification. This separation allows current Homebrew tools to use their
supported JDK without replacing Java 18. Java 18 is never the language-server
default.

Within Emacs:

- `M-x gm/java-status` reports paths, versions, roles, and the project selection.
- `M-x gm/java-use-version` selects 17, 18, or 21 for the current project and
  restarts its LSP workspace.
- Gradle and Scala project toolchains override the fallback when declared.

## Layout and shortcuts

Treemacs occupies the left sidebar, native tabs sit above editor windows, and
vterm, builds, tests, and diagnostics share a bottom panel. Project search uses a
persistent ripgrep results panel.

| Shortcut | Action |
|---|---|
| `Cmd-P` | Find project file |
| `Cmd-Shift-P` | Command palette |
| `Cmd-B` | Toggle explorer |
| `Cmd-Shift-F` | Project search panel |
| `Cmd-F` | Search current buffer |
| `Cmd-J` | Toggle integrated terminal |
| `Cmd-Shift-O` | Document symbols |
| `F12` / `Shift-F12` | Definition / references |
| `Cmd-.` | LSP code action |
| `Cmd-S` / `Cmd-W` | Save / close buffer |
| `Cmd-1`, `Cmd-2`, `Cmd-3` | Select editor window |
| `C-c f` | Explicitly format the current buffer |

Native `C-` and `M-` Emacs editing commands remain unchanged.

## Codex and Git

`M-x gm/codex` opens the installed Codex CLI in a project-scoped vterm. Agent
guidance lives in `AGENTS.md`. Magit provides repository operations and Diff-HL
shows changes in the fringe.

Generated tools, packages, grammars, language-server state, JDKs, native modules,
and credentials are ignored. Only source configuration, manifests, scripts,
tests, and documentation should be committed.

## Maintenance and troubleshooting

Run the workstation report with `M-x gm/health-check`. It reports the Emacs
features, JDK matrix, command paths, and language-server executables.

Run repository validation with:

```bash
./bin/check
```

If an Emacs Plus upgrade produces a missing-library error, uninstall and install
the versioned formula again, then rerun the guarded cutover. The preserved Java
18 bundle is independent of Homebrew and remains available when generic
`openjdk` is upgraded for Gradle, Groovy, or Coursier.
