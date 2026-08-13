;;; gm-core.el --- Core editor behavior -*- lexical-binding: t; -*-

(require 'subr-x)
(require 'display-line-numbers)
(require 'project)
(require 'recentf)
(require 'savehist)
(require 'saveplace)

(declare-function gm/workspace-current-root "gm-project")

(defgroup gm nil "Personal VSCodium-style Emacs configuration." :group 'environment)

(defconst gm/var-directory
  (expand-file-name "var/" (or (bound-and-true-p gm/config-root) user-emacs-directory)))

(defun gm/project-root ()
  "Return the selected workspace/project root, or `default-directory'."
  (or (and (fboundp 'gm/workspace-current-root)
           (gm/workspace-current-root))
      (when-let* ((project (project-current nil)))
        (expand-file-name (project-root project)))
      (locate-dominating-file default-directory ".git")
      default-directory))

(defun gm/core-initialize ()
  "Configure durable, package-independent editor behavior."
  (make-directory gm/var-directory t)
  (let ((backup-dir (expand-file-name "backups/" gm/var-directory))
        (auto-save-dir (expand-file-name "auto-save/" gm/var-directory)))
    (make-directory backup-dir t)
    (make-directory auto-save-dir t)
    (setq backup-directory-alist `(("." . ,backup-dir))
          auto-save-file-name-transforms `((".*" ,auto-save-dir t))))

  (setq custom-file (expand-file-name "custom.el" gm/var-directory)
        savehist-file (expand-file-name "savehist" gm/var-directory)
        save-place-file (expand-file-name "saveplace" gm/var-directory)
        recentf-save-file (expand-file-name "recentf" gm/var-directory)
        user-emacs-directory (or (bound-and-true-p gm/config-root) user-emacs-directory)
        create-lockfiles nil
        require-final-newline t
        ring-bell-function #'ignore
        visible-bell nil
        use-short-answers t
        sentence-end-double-space nil
        scroll-conservatively 101
        scroll-margin 3
        read-process-output-max (* 4 1024 1024)
        gc-cons-threshold (* 64 1024 1024))

  (set-default-coding-systems 'utf-8)
  (setq-default indent-tabs-mode nil
                tab-width 2
                fill-column 100
                truncate-lines t)

  (delete-selection-mode 1)
  (electric-pair-mode 1)
  (global-auto-revert-mode 1)
  (save-place-mode 1)
  (savehist-mode 1)
  (recentf-mode 1)
  (column-number-mode 1)
  (global-display-line-numbers-mode 1)
  (setq display-line-numbers-type t)

  (dolist (mode '(term-mode-hook
                  shell-mode-hook
                  eshell-mode-hook
                  vterm-mode-hook
                  treemacs-mode-hook))
    (add-hook mode (lambda () (display-line-numbers-mode -1))))

  (when (file-exists-p custom-file)
    (load custom-file 'noerror 'nomessage)))

(provide 'gm-core)
;;; gm-core.el ends here
