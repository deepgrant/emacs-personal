;;; gm-project.el --- Explorer, search, tabs, and shortcuts -*- lexical-binding: t; -*-

(require 'gm-core)
(require 'gm-tools)
(require 'seq)

(declare-function consult-imenu "consult")
(declare-function lsp-execute-code-action "lsp-mode")
(declare-function lsp-find-definition "lsp-mode")
(declare-function lsp-find-references "lsp-mode")
(declare-function treemacs "treemacs")
(declare-function treemacs-add-and-display-current-project-exclusively "treemacs")
(declare-function treemacs-quit "treemacs")

(defun gm/project-find-file ()
  "Find a file in the current project."
  (interactive)
  (cond ((fboundp 'projectile-find-file) (call-interactively #'projectile-find-file))
        ((fboundp 'project-find-file) (call-interactively #'project-find-file))
        (t (call-interactively #'find-file))))

(defun gm/toggle-explorer ()
  "Toggle the Treemacs project explorer."
  (interactive)
  (if (fboundp 'treemacs)
      (treemacs)
    (user-error "Treemacs is not installed; run bin/bootstrap-macos")))

(defun gm/open-explorer ()
  "Open Treemacs on the active project, falling back to this repository."
  (when (and (display-graphic-p)
             (fboundp 'treemacs-add-and-display-current-project-exclusively)
             (not (window-minibuffer-p)))
    (let ((default-directory
           (or (locate-dominating-file default-directory ".git")
               (and (bound-and-true-p gm/config-root) gm/config-root)
               default-directory)))
      (treemacs-add-and-display-current-project-exclusively))))

(defun gm/project-search-panel ()
  "Open persistent project search and temporarily close the explorer."
  (interactive)
  (when (fboundp 'treemacs-quit) (ignore-errors (treemacs-quit)))
  (cond ((fboundp 'deadgrep) (call-interactively #'deadgrep))
        ((fboundp 'consult-ripgrep) (consult-ripgrep (gm/project-root)))
        (t (user-error "Install deadgrep or consult to search projects"))))

(defun gm/select-editor-window (number)
  "Select editor window NUMBER, ignoring side windows."
  (let ((windows (seq-filter
                  (lambda (window) (not (window-parameter window 'window-side)))
                  (window-list))))
    (if-let ((window (nth (1- number) windows)))
        (select-window window)
      (user-error "Editor window %s does not exist" number))))

(defun gm/project-initialize ()
  "Install hybrid macOS/VSCodium shortcuts and explorer startup."
  (when (eq system-type 'darwin)
    (setq mac-command-modifier 'super
          mac-option-modifier 'meta))
  (global-set-key (kbd "s-p") #'gm/project-find-file)
  (global-set-key (kbd "s-P") #'execute-extended-command)
  (global-set-key (kbd "s-b") #'gm/toggle-explorer)
  (global-set-key (kbd "s-F") #'gm/project-search-panel)
  (global-set-key (kbd "s-f") #'isearch-forward)
  (global-set-key (kbd "s-j") #'gm/toggle-terminal)
  (global-set-key (kbd "s-O") #'consult-imenu)
  (global-set-key (kbd "<f12>") #'lsp-find-definition)
  (global-set-key (kbd "S-<f12>") #'lsp-find-references)
  (global-set-key (kbd "s-.") #'lsp-execute-code-action)
  (global-set-key (kbd "s-s") #'save-buffer)
  (global-set-key (kbd "s-w") #'kill-current-buffer)
  (global-set-key (kbd "s-1") (lambda () (interactive) (gm/select-editor-window 1)))
  (global-set-key (kbd "s-2") (lambda () (interactive) (gm/select-editor-window 2)))
  (global-set-key (kbd "s-3") (lambda () (interactive) (gm/select-editor-window 3)))
  (unless noninteractive
    (add-hook 'emacs-startup-hook #'gm/open-explorer)))

(provide 'gm-project)
;;; gm-project.el ends here
