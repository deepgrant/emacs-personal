;;; gm-tools.el --- Terminal, Codex, and health reporting -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'gm-core)
(require 'gm-java)

(declare-function vterm "vterm")
(declare-function vterm-send-return "vterm")
(declare-function vterm-send-string "vterm")

(defun gm/prepend-exec-path (directory)
  "Prepend existing DIRECTORY to both PATH and `exec-path'."
  (when (file-directory-p directory)
    (setq exec-path (cons directory (delete directory exec-path)))
    (setenv "PATH" (mapconcat #'identity
                              (cons directory
                                    (delete directory (split-string (or (getenv "PATH") "") path-separator t)))
                              path-separator))))

(defun gm/toggle-terminal ()
  "Toggle the project vterm in the bottom panel."
  (interactive)
  (let* ((name (format "*vterm:%s*" (file-name-nondirectory
                                      (directory-file-name (gm/project-root)))))
         (buffer (get-buffer name))
         (window (and buffer (get-buffer-window buffer t))))
    (cond
     (window (delete-window window))
     ((fboundp 'vterm)
      (let ((default-directory (gm/project-root)))
        (vterm name)))
     (t (user-error "vterm is not installed; run bin/bootstrap-macos")))))

(defun gm/health--line (label ok detail)
  "Print one health check LABEL with OK and DETAIL."
  (princ (format "%-24s %s  %s\n" label (if ok "OK " "FAIL") detail)))

(defun gm/health-check ()
  "Report runtime, package, language-server, and JDK readiness."
  (interactive)
  (with-help-window "*gm-health*"
    (princ "GNU Emacs workstation health\n\n")
    (gm/health--line "Emacs 30.2" (version= emacs-version "30.2") emacs-version)
    (gm/health--line "Native compilation"
                     (and (fboundp 'native-comp-available-p) (native-comp-available-p))
                     (if (fboundp 'native-comp-available-p) "checked" "unsupported"))
    (gm/health--line "Tree-sitter"
                     (and (fboundp 'treesit-available-p) (treesit-available-p)) "built-in")
    (gm/health--line "Dynamic modules" (bound-and-true-p module-file-suffix)
                     (or (bound-and-true-p module-file-suffix) "unsupported"))
    (gm/health--line "GnuTLS" (and (fboundp 'gnutls-available-p) (gnutls-available-p)) "TLS")
    (gm/health--line "vterm native module" (locate-library "vterm-module")
                     (or (locate-library "vterm-module") "missing"))
    (let ((groovy-ls (expand-file-name ".cache/lsp/groovy-language-server-all.jar"
                                       (or (bound-and-true-p gm/config-root)
                                           user-emacs-directory))))
      (gm/health--line "Groovy Language Server" (file-readable-p groovy-ls)
                       (if (file-readable-p groovy-ls)
                           groovy-ls
                         "run bin/install-groovy-language-server")))
    (dolist (version '(17 18 21))
      (gm/health--line (format "OpenJDK %s" version) (gm/java-home version)
                       (or (gm/java-home version) "missing")))
    (dolist (program '("rg" "fd" "node" "npm" "basedpyright-langserver"
                       "typescript-language-server" "ngserver" "bash-language-server"
                       "yaml-language-server" "sourcekit-lsp" "gradle" "groovy"
                       "shellcheck" "shfmt" "ruff" "metals" "codex"))
      (gm/health--line program (executable-find program)
                       (or (executable-find program) "missing")))
    (when (fboundp 'gm/codex-capabilities)
      (pcase-let ((`(,ok . ,detail) (gm/codex-capabilities)))
        (gm/health--line "Codex native API" ok detail)))))

(defun gm/tools-initialize ()
  "Expose managed tools and start the Emacs server."
  (let ((root (or (bound-and-true-p gm/config-root) user-emacs-directory)))
    (dolist (directory (list (expand-file-name ".local/bin" root)
                             (expand-file-name "tools/node_modules/.bin" root)
                             "/opt/homebrew/opt/node@24/bin"
                             "/Applications/ChatGPT.app/Contents/Resources"))
      (gm/prepend-exec-path directory)))
  (unless noninteractive
    (require 'server)
    (unless (server-running-p) (server-start))))

(provide 'gm-tools)
;;; gm-tools.el ends here
