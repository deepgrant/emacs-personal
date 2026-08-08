;;; run-tests.el --- ERT entrypoint -*- lexical-binding: t; -*-

(setq gm/config-root
      (file-name-directory (directory-file-name
                            (file-name-directory (or load-file-name buffer-file-name)))))
(setq load-prefer-newer t)
(add-to-list 'load-path (expand-file-name "lisp" gm/config-root))
(add-to-list 'custom-theme-load-path (expand-file-name "themes" gm/config-root))
(setenv "GM_EMACS_SKIP_PACKAGES" "1")

(require 'ert)
(require 'gm-core)
(require 'gm-java)
(require 'gm-hocon-mode)
(require 'gm-ui)
(require 'gm-tools)
(require 'gm-project)
(require 'gm-languages)

(ert-deftest gm-theme-loads ()
  (load-theme 'gm-cursor-dark t)
  (should (custom-theme-enabled-p 'gm-cursor-dark)))

(ert-deftest gm-hocon-file-associations ()
  (should (eq (cdr (assoc "\\.hocon\\'" auto-mode-alist)) 'gm-hocon-mode))
  (should (eq (cdr (assoc "/\\(?:application\\|reference\\)\\.conf\\'" auto-mode-alist))
              'gm-hocon-mode)))

(ert-deftest gm-hocon-indentation ()
  (with-temp-buffer
    (gm-hocon-mode)
    (insert "service {\nport = 8080\nnested {\nenabled = true\n}\n}\n")
    (indent-region (point-min) (point-max))
    (should (equal (buffer-string)
                   "service {\n  port = 8080\n  nested {\n    enabled = true\n  }\n}\n"))))

(ert-deftest gm-java-runtime-registration ()
  (let ((runtimes (gm/java-lsp-runtimes)))
    (dolist (runtime runtimes)
      (should (file-directory-p (plist-get runtime :path))))
    (when (gm/java-home 21)
      (should (seq-some (lambda (runtime) (plist-get runtime :default)) runtimes)))))

(ert-deftest gm-language-file-associations ()
  (gm/languages-initialize)
  (should (eq (cdr (assoc "\\.ts\\'" auto-mode-alist)) 'typescript-ts-mode))
  (should (eq (cdr (assoc "\\.tsx\\'" auto-mode-alist)) 'tsx-ts-mode)))

(ert-deftest gm-hybrid-keybindings ()
  (gm/project-initialize)
  (should (eq (key-binding (kbd "s-p")) #'gm/project-find-file))
  (should (eq (key-binding (kbd "s-b")) #'gm/toggle-explorer))
  (should (eq (key-binding (kbd "s-j")) #'gm/toggle-terminal)))

(ert-deftest gm-line-numbers-match-vscodium-default ()
  (gm/core-initialize)
  (should (eq display-line-numbers-type t)))

(ert-deftest gm-display-panel-rules ()
  (gm/ui-initialize)
  (should (assoc "\\*deadgrep.*\\*" display-buffer-alist))
  (should (assoc "\\*\\(?:vterm\\|compilation\\|Flycheck errors\\|sbt\\|Gradle\\).*\\*"
                 display-buffer-alist)))

(ert-run-tests-batch-and-exit)
;;; run-tests.el ends here
