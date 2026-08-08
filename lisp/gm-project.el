;;; gm-project.el --- Explorer, search, tabs, and shortcuts -*- lexical-binding: t; -*-

(require 'gm-core)
(require 'gm-tools)
(require 'seq)

(declare-function consult-imenu "consult")
(declare-function lsp-execute-code-action "lsp-mode")
(declare-function lsp-find-definition "lsp-mode")
(declare-function lsp-find-references "lsp-mode")
(declare-function treemacs "treemacs")
(declare-function treemacs--show-single-project "treemacs-rendering")
(declare-function treemacs-find-file "treemacs")
(declare-function treemacs-follow-mode "treemacs-follow-mode")
(declare-function treemacs-quit "treemacs")
(declare-function treemacs-refresh "treemacs-interface")
(declare-function treemacs-root-up "treemacs-interface")
(declare-function treemacs-select-window "treemacs")

(defun gm/treemacs-home-directory ()
  "Return the canonical home directory used as the explorer root."
  (directory-file-name (file-truename (expand-file-name "~/"))))

(defun gm/treemacs-root-up ()
  "Move the explorer root to its parent directory."
  (interactive)
  (treemacs-select-window)
  (treemacs-root-up))

(defun gm/treemacs-refresh ()
  "Refresh the explorer without requiring it to be focused first."
  (interactive)
  (treemacs-select-window)
  (treemacs-refresh))

(defun gm/treemacs-reveal-current-file ()
  "Reveal the file in the most recently used editor window."
  (interactive)
  (let ((editor-window
         (if (buffer-file-name (window-buffer (selected-window)))
             (selected-window)
           (get-mru-window nil nil t))))
    (unless (and editor-window
                 (buffer-file-name (window-buffer editor-window)))
      (user-error "The active editor is not visiting a file"))
    (with-selected-window editor-window
      (treemacs-find-file))))

(defvar gm/treemacs-parent-button-map
  (let ((map (make-sparse-keymap)))
    (define-key map [header-line mouse-1] #'gm/treemacs-root-up)
    map))

(defvar gm/treemacs-home-button-map
  (let ((map (make-sparse-keymap)))
    (define-key map [header-line mouse-1] #'gm/treemacs-show-home)
    map))

(defvar gm/treemacs-reveal-button-map
  (let ((map (make-sparse-keymap)))
    (define-key map [header-line mouse-1] #'gm/treemacs-reveal-current-file)
    map))

(defvar gm/treemacs-refresh-button-map
  (let ((map (make-sparse-keymap)))
    (define-key map [header-line mouse-1] #'gm/treemacs-refresh)
    map))

(defun gm/treemacs-header-line ()
  "Return the clickable navigation controls for the explorer header."
  (concat
   (propertize " ↑ Parent "
               'face 'mode-line
               'mouse-face 'mode-line-highlight
               'help-echo "Move the explorer root to its parent (^ or M-H)"
               'local-map gm/treemacs-parent-button-map)
   (propertize " ⌂ Home "
               'face 'mode-line
               'mouse-face 'mode-line-highlight
               'help-echo "Reset the explorer root to $HOME (~)"
               'local-map gm/treemacs-home-button-map)
   (propertize " ◎ "
               'face 'mode-line
               'mouse-face 'mode-line-highlight
               'help-echo "Reveal the active editor file (.)"
               'local-map gm/treemacs-reveal-button-map)
   (propertize " ↻ "
               'face 'mode-line
               'mouse-face 'mode-line-highlight
               'help-echo "Refresh the explorer (g)"
               'local-map gm/treemacs-refresh-button-map)))

(defun gm/treemacs-setup-buffer ()
  "Install the explorer navigation header in the current Treemacs buffer."
  (setq-local header-line-format '(:eval (gm/treemacs-header-line))))

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

(defun gm/treemacs-show-home ()
  "Open the explorer with `$HOME' as its single root."
  (interactive)
  (unless (require 'treemacs nil t)
    (user-error "Treemacs is not installed; run bin/bootstrap-macos"))
  (let ((origin-buffer (current-buffer))
        (home (gm/treemacs-home-directory)))
    (save-selected-window
      (treemacs--show-single-project home "Home")
      (treemacs-follow-mode 1)
      (when (and (buffer-live-p origin-buffer)
                 (buffer-file-name origin-buffer)
                 (file-in-directory-p (buffer-file-name origin-buffer) home))
        (with-current-buffer origin-buffer
          (treemacs-find-file))))))

(defun gm/open-explorer ()
  "Open Treemacs at `$HOME' and follow the active editor buffer."
  (when (and (display-graphic-p)
             (not (window-minibuffer-p)))
    (gm/treemacs-show-home)))

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
