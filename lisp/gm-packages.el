;;; gm-packages.el --- Package declarations -*- lexical-binding: t; -*-

(require 'package)
(require 'gm-java)

(declare-function global-diff-hl-mode "diff-hl")
(declare-function diff-hl-flydiff-mode "diff-hl-flydiff")
(declare-function gm/treemacs-reveal-current-file "gm-project")
(declare-function gm/treemacs-root-up "gm-project")
(declare-function gm/treemacs-setup-buffer "gm-project")
(declare-function gm/treemacs-show-home "gm-project")
(declare-function lsp-dependency "lsp-mode")
(declare-function treemacs-follow-mode "treemacs-follow-mode")

(defvar corfu-auto-delay)
(defvar lsp-clients-angular-language-server-command)
(defvar lsp-completion-provider)
(defvar lsp-metals-java-home)
(defvar lsp-metals-metals-store-path)
(defvar lsp-metals-server-command)
(defvar treemacs-mode-map)
(defvar treemacs-user-header-line-format)
(defvar use-package-always-defer)
(defvar use-package-always-ensure)
(defvar use-package-expand-minimally)

(defconst gm/treemacs-runtime-names
  '(".cache" ".local" "eln-cache" "elpa" "tree-sitter" "var"
    "history" "places" "projectile-frecency.eld" "recentf")
  "Generated configuration entries that Treemacs should not display.")

(defun gm/treemacs-ignore-runtime-p (filename _absolute-path)
  "Return non-nil when FILENAME is generated runtime state."
  (member filename gm/treemacs-runtime-names))

(setq package-archives
      '(("gnu" . "https://elpa.gnu.org/packages/")
        ("nongnu" . "https://elpa.nongnu.org/nongnu/")
        ("melpa" . "https://melpa.org/packages/")))

(package-initialize)

(defconst gm/package-install-enabled
  (not (string= (getenv "GM_EMACS_SKIP_PACKAGES") "1"))
  "Whether this startup may install missing packages.")

(unless (require 'use-package nil t)
  (when gm/package-install-enabled
    (unless package-archive-contents (package-refresh-contents))
    (package-install 'use-package)
    (require 'use-package)))

(unless (featurep 'use-package)
  (defmacro use-package (_name &rest _args) nil))

(setq use-package-always-ensure gm/package-install-enabled
      use-package-always-defer t
      use-package-expand-minimally t)

(defconst gm/required-packages
  '(apheleia cape consult consult-lsp corfu dap-mode deadgrep diff-hl doom-modeline
    embark embark-consult flycheck groovy-mode lsp-java lsp-metals lsp-mode lsp-pyright
    lsp-treemacs lsp-ui magit marginalia nerd-icons nerd-icons-dired orderless projectile
    sbt-mode scala-mode swift-mode treemacs treemacs-projectile vertico vterm web-mode
    which-key yaml-mode yasnippet yasnippet-snippets)
  "Packages that make up the supported editor environment.")

(use-package vertico
  :init (vertico-mode 1))

(use-package orderless
  :init
  (setq completion-styles '(orderless basic)
        completion-category-defaults nil
        completion-category-overrides '((file (styles partial-completion)))))

(use-package marginalia
  :init (marginalia-mode 1))

(use-package consult
  :bind (("M-g g" . consult-goto-line)
         ("M-g i" . consult-imenu)
         ("M-y" . consult-yank-pop)))

(use-package embark
  :bind (("C-." . embark-act)
         ("C-;" . embark-dwim)))

(use-package embark-consult :after (embark consult))

(use-package corfu
  :init
  (setq corfu-auto t
        corfu-auto-delay 0.15
        corfu-cycle t
        corfu-preview-current nil)
  (global-corfu-mode 1))

(use-package cape
  :init
  (add-to-list 'completion-at-point-functions #'cape-file))

(use-package yasnippet
  :init (yas-global-mode 1))
(use-package yasnippet-snippets :after yasnippet)

(use-package which-key
  :init (which-key-mode 1))

(use-package nerd-icons)
(use-package nerd-icons-dired
  :hook (dired-mode . nerd-icons-dired-mode))

(use-package doom-modeline
  :init
  (setq doom-modeline-height 26
        doom-modeline-buffer-file-name-style 'relative-to-project)
  (doom-modeline-mode 1))

(use-package projectile
  :init
  (setq projectile-cache-file (expand-file-name "projectile.cache" gm/var-directory)
        projectile-known-projects-file (expand-file-name "projectile-bookmarks.eld" gm/var-directory)
        projectile-frecency-file (expand-file-name "projectile-frecency.eld" gm/var-directory)
        projectile-enable-caching t)
  (projectile-mode 1))

(use-package treemacs
  :commands (treemacs treemacs-select-window treemacs-quit)
  :init
  (setq treemacs-width 34
        treemacs-follow-after-init t
        treemacs-is-never-other-window t
        treemacs-show-hidden-files t
        treemacs-silent-refresh t
        treemacs-user-header-line-format '(:eval (gm/treemacs-header-line)))
  :config
  (add-to-list 'treemacs-ignored-file-predicates #'gm/treemacs-ignore-runtime-p)
  (add-hook 'treemacs-mode-hook #'gm/treemacs-setup-buffer)
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'treemacs-mode)
        (gm/treemacs-setup-buffer))))
  (treemacs-follow-mode 1)
  (define-key treemacs-mode-map (kbd "^") #'gm/treemacs-root-up)
  (define-key treemacs-mode-map (kbd "~") #'gm/treemacs-show-home)
  (define-key treemacs-mode-map (kbd ".") #'gm/treemacs-reveal-current-file))
(use-package treemacs-projectile :after (treemacs projectile))

(use-package deadgrep :commands deadgrep)
(use-package vterm :commands vterm)

(use-package flycheck
  :hook (prog-mode . flycheck-mode))

(use-package lsp-mode
  :commands (lsp lsp-deferred lsp-execute-code-action lsp-find-definition lsp-find-references)
  :init
  (setq lsp-keymap-prefix "C-c l"
        lsp-completion-provider :none
        lsp-enable-file-watchers t
        lsp-enable-snippet t
        lsp-headerline-breadcrumb-enable t
        lsp-idle-delay 0.35
        lsp-log-io nil
        lsp-modeline-code-actions-enable t
        lsp-clients-angular-language-server-command
        (list (expand-file-name "bin/ngserver-angular20"
                                (or (bound-and-true-p gm/config-root)
                                    user-emacs-directory)))))

(use-package lsp-ui
  :after lsp-mode
  :init
  (setq lsp-ui-doc-enable t
        lsp-ui-doc-position 'at-point
        lsp-ui-doc-delay 0.6
        lsp-ui-sideline-enable t
        lsp-ui-peek-always-show t))

(use-package lsp-treemacs :after (lsp-mode treemacs))
(use-package consult-lsp :after (consult lsp-mode))

(use-package lsp-java
  :after lsp-mode
  :init
  (setq lsp-java-java-path
        (when-let ((home (gm/java-home 21))) (expand-file-name "bin/java" home))
        lsp-java-configuration-runtimes (gm/java-lsp-runtimes)))

(use-package lsp-metals
  :after lsp-mode
  :init
  (setq lsp-metals-server-command (gm/metals-server-command)
        lsp-metals-java-home (or (gm/java-home 17) ""))
  :config
  (lsp-dependency 'metals
                  `(:system ,lsp-metals-server-command)
                  `(:system ,lsp-metals-metals-store-path)))

(use-package lsp-pyright
  :after lsp-mode
  :init (setq lsp-pyright-langserver-command "basedpyright"))

(use-package dap-mode
  :after lsp-mode
  :commands (dap-debug dap-hydra))

(use-package magit :commands magit-status)
(use-package diff-hl
  :init
  (global-diff-hl-mode 1)
  (diff-hl-flydiff-mode 1))

(use-package apheleia :commands apheleia-format-buffer)
(use-package scala-mode :mode "\\.s\\(cala\\|bt\\)\\'")
(use-package sbt-mode :commands sbt-start sbt-command)
(use-package groovy-mode :mode ("\\.groovy\\'" "\\.gradle\\'"))
(use-package swift-mode :mode "\\.swift\\'")
(use-package yaml-mode :mode "\\.ya?ml\\'")
(use-package web-mode
  :mode ("\\.html\\'" "\\.component\\.html\\'")
  :init (setq web-mode-markup-indent-offset 2
              web-mode-code-indent-offset 2
              web-mode-css-indent-offset 2))

(defun gm/packages-initialize ()
  "Record the package manifest for package.el and bootstrap tooling."
  (setq package-selected-packages gm/required-packages))

(provide 'gm-packages)
;;; gm-packages.el ends here
