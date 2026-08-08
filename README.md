# gm Emacs workstation

A reproducible GNU Emacs 30.2 configuration for Apple Silicon macOS. It uses a
Cursor Dark-inspired theme, Menlo 12, a project explorer, editor tabs, search and
terminal panels, language servers, debugging, Git tooling, and hybrid macOS/Emacs
keybindings. A native Codex task panel gives project-scoped coding agents direct,
sandboxed access to the active Git workspace.

## Screen layout

![GNU Emacs workstation with the home-directory explorer, Scala editor, tabs, Git status, and code minimap](docs/images/emacs-workstation-layout.png)

The VSCodium-style workspace combines the `$HOME` explorer, editor tabs, LSP
status, Git integration, and an optional right-side code minimap.

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

The bootstrap builds the Groovy Language Server from a pinned upstream revision
because that project does not publish binary releases. To repair or reinstall
only that server, run `./bin/install-groovy-language-server`.

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

Treemacs occupies the left sidebar, starts at `$HOME`, and automatically reveals
the file selected in an editor window. Its clickable header provides **Parent**,
**Home**, **Reveal**, and **Refresh** controls. From the keyboard, `^` moves the
root to its parent, `~` returns to `$HOME`, `.` reveals the active file, and `g`
refreshes the tree. Native tabs sit above editor windows; vterm, builds, tests,
and diagnostics share a bottom panel. Project search uses a persistent ripgrep
results panel. An optional code minimap opens on the right edge of the active
editor and supports mouse navigation; it remains off until requested so the
Codex sidebar can retain the full panel width.

| Shortcut | Action |
|---|---|
| `Cmd-P` | Find project file |
| `Cmd-Shift-P` | Command palette |
| `Cmd-B` | Toggle explorer |
| `Cmd-Shift-F` | Project search panel |
| `Cmd-F` | Search current buffer |
| `Cmd-J` | Toggle integrated terminal |
| `Cmd-I` | Start a workspace-writing Codex task |
| `Cmd-Shift-I` | Toggle the Codex sidebar |
| `Cmd-Shift-O` | Document symbols |
| `F12` / `Shift-F12` | Definition / references |
| `Cmd-.` | LSP code action |
| `Cmd-S` / `Cmd-W` | Save / close buffer |
| `Cmd-1`, `Cmd-2`, `Cmd-3` | Select editor window |
| `C-c f` | Explicitly format the current buffer |
| `C-c m` | Toggle the code minimap |

Native `C-` and `M-` Emacs editing commands remain unchanged.

## Codex and Git

`M-x gm/codex` opens a project-scoped panel on the right and prompts for a task
when the project has no existing panel. Output streams from `codex exec --json`;
commands are invoked directly without a shell. Writing tasks use the
`workspace-write` sandbox, disable shell network access, and cannot write outside
the canonical Git root. The integration never requests `danger-full-access`,
approval bypasses, or additional writable directories.

| Command | Action |
|---|---|
| `M-x gm/codex-task` | Start a task that may edit the current Git workspace |
| `M-x gm/codex-ask` | Start a concurrent read-only question |
| `M-x gm/codex-follow-up` | Continue the panel's recorded session |
| `M-x gm/codex-review` | Review staged, unstaged, and untracked changes |
| `M-x gm/codex-cancel` | Interrupt the active task without hiding its output |
| `M-x gm/codex-terminal` | Open or resume the interactive CLI in vterm |

`C-c a` is the prefix for task, ask, review, follow-up, cancel, diff, and terminal
commands. In a Codex panel, use `k` to cancel, `f` to follow up, `d` for Magit,
`v` to visit a changed file, `t` for interactive terminal handoff, and `q` to
hide the panel.

Only one workspace-writing task may run per project, though read-only questions
may run concurrently. Codex may orchestrate child agents inside that one writing
task. Before it starts, Emacs offers to save modified project buffers. When it
finishes, clean buffers, Treemacs, Diff-HL, and Magit refresh; unsaved buffers
are reported and never reverted automatically.

Native tasks use a noninteractive approval policy, so attempts outside the
sandbox fail and are returned to the agent. Use `M-x gm/codex-terminal` when a
task genuinely needs an interactive approval. Session identifiers are stored in
ignored `var/codex-sessions.el`; authentication remains owned by the Codex CLI
and no credential is stored in Emacs.

Repository guidance lives in `AGENTS.md`. Magit provides repository operations
and Diff-HL shows changes in the fringe. Codex does not automatically commit,
push, or open pull requests.

Generated tools, packages, grammars, language-server state, JDKs, native modules,
and credentials are ignored. Only source configuration, manifests, scripts,
tests, and documentation should be committed.

## Maintenance and troubleshooting

Run the workstation report with `M-x gm/health-check`. It reports the Emacs
features, JDK matrix, command paths, language-server executables, and whether the
installed Codex CLI exposes JSON output, sandboxing, resume, and review support.

Run repository validation with:

```bash
./bin/check
```

If an Emacs Plus upgrade produces a missing-library error, uninstall and install
the versioned formula again, then rerun the guarded cutover. The preserved Java
18 bundle is independent of Homebrew and remains available when generic
`openjdk` is upgraded for Gradle, Groovy, or Coursier.

If a native Codex task reports a sandbox or approval failure, hand the recorded
session to `M-x gm/codex-terminal`. If no session identifier appears, run
`M-x gm/health-check` and confirm that `codex` is authenticated and its `exec`
help lists `--json`, `--sandbox`, `resume`, and `review`.

Metals runs one server per Git project even though Treemacs exposes `$HOME`.
Run Metals commands such as `M-x lsp-metals-reset-workspace` from a Scala source
buffer, not from `*lsp session*`, `*LSP Error List*`, or another panel. Merely
showing the source above a focused panel is not sufficient: click in the source
text first. Separate checkouts of the same repository intentionally receive
separate Metals processes and build imports. If a project was imported before a
Homebrew JDK upgrade, run `M-x lsp-metals-build-import` from that project's Scala
buffer to regenerate its ignored `.bloop` metadata with the stable OpenJDK 17
path.
