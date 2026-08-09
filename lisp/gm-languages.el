;;; gm-languages.el --- Language modes, Tree-sitter, and LSP -*- lexical-binding: t; -*-

(require 'gm-core)
(require 'gm-hocon-mode)
(require 'treesit)

(declare-function apheleia-format-buffer "apheleia")
(declare-function flycheck-mode "flycheck")
(declare-function lsp-deferred "lsp-mode")
(declare-function lsp-format-buffer "lsp-mode")

(defvar gm/session-restoring-p)

(defconst gm/treesit-language-sources
  '((bash "https://github.com/tree-sitter/tree-sitter-bash")
    (java "https://github.com/tree-sitter/tree-sitter-java")
    (javascript "https://github.com/tree-sitter/tree-sitter-javascript" "master" "src")
    (json "https://github.com/tree-sitter/tree-sitter-json")
    (python "https://github.com/tree-sitter/tree-sitter-python")
    (typescript "https://github.com/tree-sitter/tree-sitter-typescript" "master" "typescript/src")
    (tsx "https://github.com/tree-sitter/tree-sitter-typescript" "master" "tsx/src")
    (yaml "https://github.com/tree-sitter-grammars/tree-sitter-yaml"))
  "Tree-sitter grammars managed by this configuration.")

(defun gm/treesit-install-all ()
  "Install every missing managed Tree-sitter grammar."
  (interactive)
  (unless (and (fboundp 'treesit-available-p) (treesit-available-p))
    (user-error "This Emacs build does not support Tree-sitter"))
  (setq treesit-language-source-alist gm/treesit-language-sources)
  (dolist (entry gm/treesit-language-sources)
    (unless (treesit-language-available-p (car entry))
      (message "Installing Tree-sitter grammar: %s" (car entry))
      (treesit-install-language-grammar (car entry)))))

(defun gm/lsp-start-for-current-buffer ()
  "Load and start the current buffer's external language client."
  (pcase major-mode
    ((or 'scala-mode 'scala-ts-mode) (require 'lsp-metals nil t))
    ((or 'java-mode 'java-ts-mode) (require 'lsp-java nil t))
    ((or 'python-mode 'python-ts-mode) (require 'lsp-pyright nil t)))
  (when (fboundp 'lsp-deferred) (lsp-deferred)))

(defun gm/language-services-after-session-command ()
  "Start deferred diagnostics and LSP after using a restored file buffer."
  (unless (bound-and-true-p gm/session-restoring-p)
    (remove-hook 'post-command-hook
                 #'gm/language-services-after-session-command t)
    (when (fboundp 'flycheck-mode) (flycheck-mode 1))
    (gm/lsp-start-for-current-buffer)))

(defun gm/lsp-deferred-if-available ()
  "Start LSP, or defer it until a restored buffer receives input."
  (if (bound-and-true-p gm/session-restoring-p)
      (add-hook 'post-command-hook
                #'gm/language-services-after-session-command nil t)
    (gm/lsp-start-for-current-buffer)))

(defun gm/flycheck-mode-unless-restoring-session ()
  "Enable Flycheck except while Desktop is reconstructing file buffers."
  (unless (bound-and-true-p gm/session-restoring-p)
    (flycheck-mode 1)))

(defun gm/format-buffer ()
  "Format the current buffer explicitly using configured tooling."
  (interactive)
  (cond ((and (fboundp 'apheleia-format-buffer)
              (bound-and-true-p apheleia-mode))
         (apheleia-format-buffer))
        ((and (bound-and-true-p lsp-mode) (fboundp 'lsp-format-buffer))
         (lsp-format-buffer))
        (t (indent-region (point-min) (point-max)))))

(defun gm/languages-initialize ()
  "Configure file associations, Tree-sitter remaps, and LSP hooks."
  (setq treesit-language-source-alist gm/treesit-language-sources)

  (when (boundp 'major-mode-remap-alist)
    (dolist (mapping '((bash-mode . bash-ts-mode)
                       (java-mode . java-ts-mode)
                       (javascript-mode . js-ts-mode)
                       (js-mode . js-ts-mode)
                       (json-mode . json-ts-mode)
                       (python-mode . python-ts-mode)
                       (typescript-mode . typescript-ts-mode)
                       (yaml-mode . yaml-ts-mode)))
      (add-to-list 'major-mode-remap-alist mapping)))

  (add-to-list 'auto-mode-alist '("\\.tsx\\'" . tsx-ts-mode))
  (add-to-list 'auto-mode-alist '("\\.ts\\'" . typescript-ts-mode))
  (add-to-list 'auto-mode-alist '("\\.jsonc?\\'" . json-ts-mode))
  (add-to-list 'auto-mode-alist '("\\.ya?ml\\'" . yaml-ts-mode))

  (dolist (hook '(scala-mode-hook
                  python-mode-hook python-ts-mode-hook
                  typescript-ts-mode-hook tsx-ts-mode-hook js-ts-mode-hook
                  java-mode-hook java-ts-mode-hook groovy-mode-hook
                  bash-mode-hook bash-ts-mode-hook
                  yaml-mode-hook yaml-ts-mode-hook
                  json-mode-hook json-ts-mode-hook
                  swift-mode-hook web-mode-hook))
    (add-hook hook #'gm/lsp-deferred-if-available))

  (global-set-key (kbd "C-c f") #'gm/format-buffer))

(provide 'gm-languages)
;;; gm-languages.el ends here
