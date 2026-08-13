;;; gm-project.el --- Explorer, search, tabs, and shortcuts -*- lexical-binding: t; -*-

(require 'gm-core)
(require 'gm-session)
(require 'gm-tools)
(require 'cl-lib)
(require 'seq)
(require 'tab-bar)
(require 'tab-line)
(require 'vc-git)

(declare-function consult-imenu "consult")
(declare-function magit-status-setup-buffer "magit-status")
(declare-function projectile-find-file-in-directory "projectile")
(declare-function lsp-execute-code-action "lsp-mode")
(declare-function lsp-find-definition "lsp-mode")
(declare-function lsp-find-references "lsp-mode")
(declare-function treemacs "treemacs")
(declare-function treemacs--find-project-for-path "treemacs-workspaces")
(declare-function treemacs--show-single-project "treemacs-rendering")
(declare-function treemacs-dom-node->position "treemacs-dom")
(declare-function treemacs-find-file "treemacs")
(declare-function treemacs-find-file-node "treemacs-core-utils")
(declare-function treemacs-find-in-dom "treemacs-dom")
(declare-function treemacs-follow-mode "treemacs-follow-mode")
(declare-function treemacs-project->path "treemacs-workspaces")
(declare-function treemacs-quit "treemacs")
(declare-function treemacs-refresh "treemacs-interface")
(declare-function treemacs-root-up "treemacs-interface")
(declare-function treemacs-select-window "treemacs")

;; Declaring these package variables here makes the safety bindings in
;; `gm/workspace-sync-explorer' dynamically visible to Treemacs even though
;; this module uses lexical binding and Treemacs is loaded lazily.
(defvar treemacs-follow-after-init)
(defvar treemacs-follow-mode)

(defconst gm/workspace-global-name "Global"
  "Display name of the permanent loose-file workspace.")

(defvar gm/workspace-routing-enabled nil
  "Non-nil when interactive file selection may switch workspace tabs.")

(defvar gm/workspace--routing nil
  "Internal guard against recursive workspace routing.")

(defvar gm/workspace--creating-tab nil
  "Dynamically non-nil while `gm/workspace-open' creates a tab.")

(defvar gm/workspace--suppress-explorer-sync nil
  "Dynamically non-nil while Treemacs synchronization is unsafe.")

(defvar-local gm/workspace--cached-git-root 'unknown
  "Cached canonical Git root for the current file buffer.")

(defun gm/treemacs--find-file-node-when-root-ready
    (function path &optional project)
  "Call Treemacs file-node FUNCTION only when its project DOM is ready.
PATH and PROJECT are the arguments originally passed to
`treemacs-find-file-node'.  Returning nil while the root is temporarily
absent lets a later follow event retry without entering Treemacs's unbounded
parent walk."
  (let* ((resolved-project
          (or project (funcall 'treemacs--find-project-for-path path)))
         (root (and resolved-project
                    (funcall 'treemacs-project->path resolved-project)))
         (root-node (and root (funcall 'treemacs-find-in-dom root))))
    (when (and root-node
               (funcall 'treemacs-dom-node->position root-node))
      (funcall function path resolved-project))))

(defun gm/workspace-git-root (&optional path)
  "Return the canonical Git worktree root containing PATH, or nil."
  (let* ((expanded (expand-file-name (or path buffer-file-name default-directory)))
         (probe (if (file-directory-p expanded)
                    (file-name-as-directory expanded)
                  (file-name-directory expanded)))
         (root (and probe (vc-git-root probe))))
    (when root
      (file-name-as-directory (file-truename root)))))

(defun gm/workspace--tabs ()
  "Return the selected frame's tab-bar tabs."
  (tab-bar-tabs))

(defun gm/workspace--current-tab ()
  "Return the selected frame's current tab object."
  (tab-bar--current-tab-find (gm/workspace--tabs)))

(defun gm/workspace--tab-kind (tab)
  "Return workspace kind metadata stored on TAB."
  (alist-get 'gm-workspace-kind tab))

(defun gm/workspace--tab-root (tab)
  "Return canonical repository root metadata stored on TAB."
  (alist-get 'gm-workspace-root tab))

(defun gm/workspace-current-root ()
  "Return the selected repository workspace root, or nil in Global."
  (let ((tab (gm/workspace--current-tab)))
    (when (eq (gm/workspace--tab-kind tab) 'repository)
      (gm/workspace--tab-root tab))))

(defun gm/workspace--tab-index-if (predicate)
  "Return the one-based index of the first tab matching PREDICATE."
  (let ((index (cl-position-if predicate (gm/workspace--tabs))))
    (and index (1+ index))))

(defun gm/workspace--global-tab-index ()
  "Return the one-based index of the permanent Global tab."
  (gm/workspace--tab-index-if
   (lambda (tab) (eq (gm/workspace--tab-kind tab) 'global))))

(defun gm/workspace--repository-tab-index (root)
  "Return the one-based tab index registered for canonical ROOT."
  (gm/workspace--tab-index-if
   (lambda (tab)
     (and (eq (gm/workspace--tab-kind tab) 'repository)
          (equal (gm/workspace--tab-root tab) root)))))

(defun gm/workspace--registered-roots ()
  "Return every canonical Git root registered in a workspace tab."
  (delq nil
        (mapcar (lambda (tab)
                  (and (eq (gm/workspace--tab-kind tab) 'repository)
                       (gm/workspace--tab-root tab)))
                (gm/workspace--tabs))))

(defun gm/workspace--mark-tab (tab kind &optional root)
  "Store workspace KIND and canonical ROOT metadata on TAB."
  (dolist (entry `((gm-workspace-kind . ,kind)
                   (gm-workspace-root . ,root)))
    (if-let ((cell (assq (car entry) tab)))
        (setcdr cell (cdr entry))
      (setcdr tab (cons entry (cdr tab))))))

(defun gm/workspace--ensure-global-tab ()
  "Ensure exactly one existing tab is designated as Global."
  (let* ((tabs (gm/workspace--tabs))
         (globals (seq-filter
                   (lambda (tab) (eq (gm/workspace--tab-kind tab) 'global))
                   tabs))
         (global (or (car globals) (gm/workspace--current-tab))))
    (gm/workspace--mark-tab global 'global)
    (setf (alist-get 'name global) gm/workspace-global-name
          (alist-get 'explicit-name global) t)
    (dolist (duplicate (cdr globals))
      (gm/workspace--mark-tab duplicate 'unassigned))))

(defun gm/workspace--repository-name (root duplicate-p)
  "Return the workspace display name for ROOT.
Include its abbreviated parent directory when DUPLICATE-P is non-nil."
  (let ((base (file-name-nondirectory (directory-file-name root))))
    (if duplicate-p
        (format "%s (%s)" base
                (abbreviate-file-name
                 (directory-file-name
                  (file-name-directory (directory-file-name root)))))
      base)))

(defun gm/workspace--refresh-tab-names ()
  "Refresh deterministic names for Global and repository tabs."
  (let* ((tabs (gm/workspace--tabs))
         (repo-tabs (seq-filter
                     (lambda (tab) (eq (gm/workspace--tab-kind tab) 'repository))
                     tabs)))
    (dolist (tab tabs)
      (pcase (gm/workspace--tab-kind tab)
        ('global
         (setf (alist-get 'name tab) gm/workspace-global-name
               (alist-get 'explicit-name tab) t))
        ('repository
         (let* ((root (gm/workspace--tab-root tab))
                (base (file-name-nondirectory (directory-file-name root)))
                (duplicate-p
                 (> (cl-count base repo-tabs
                              :test #'string=
                              :key (lambda (candidate)
                                     (file-name-nondirectory
                                      (directory-file-name
                                       (gm/workspace--tab-root candidate)))))
                    1)))
           (setf (alist-get 'name tab) (gm/workspace--repository-name root duplicate-p)
                 (alist-get 'explicit-name tab) t)))))
    (force-mode-line-update t)))

(defun gm/workspace--new-tab (tab)
  "Mark a native TAB not created by workspace commands as unassigned."
  (unless gm/workspace--creating-tab
    (gm/workspace--mark-tab tab 'unassigned)))

(defun gm/workspace--prevent-global-close (tab _only-tab-p)
  "Prevent closure of the permanent Global TAB."
  (when (eq (gm/workspace--tab-kind tab) 'global)
    (message "The Global workspace cannot be closed")
    t))

(defun gm/workspace--reset-buffer-root-cache ()
  "Invalidate the current buffer's cached Git root."
  (setq gm/workspace--cached-git-root 'unknown))

(defun gm/workspace-buffer-git-root (&optional buffer)
  "Return the cached canonical Git root for BUFFER's visited file."
  (with-current-buffer (or buffer (current-buffer))
    (when (eq gm/workspace--cached-git-root 'unknown)
      (setq gm/workspace--cached-git-root
            (or (and buffer-file-name (gm/workspace-git-root buffer-file-name))
                'none)))
    (unless (eq gm/workspace--cached-git-root 'none)
      gm/workspace--cached-git-root)))

(defun gm/workspace--buffer-belongs-to-tab-p (buffer tab)
  "Return non-nil when file BUFFER belongs in workspace TAB."
  (let ((root (gm/workspace-buffer-git-root buffer)))
    (pcase (gm/workspace--tab-kind tab)
      ('repository (equal root (gm/workspace--tab-root tab)))
      ('global (or (null root)
                   (not (member root (gm/workspace--registered-roots)))))
      (_ nil))))

(defun gm/workspace-tab-line-buffers ()
  "Return file tabs belonging to the selected repository or Global tab."
  (let ((tab (gm/workspace--current-tab))
        (current (current-buffer)))
    (seq-uniq
     (cons current
           (seq-filter
            (lambda (buffer)
              (and (buffer-live-p buffer)
                   (buffer-file-name buffer)
                   (gm/workspace--buffer-belongs-to-tab-p buffer tab)))
            (buffer-list))))))

(defun gm/workspace--select-tab (index &optional buffer)
  "Select one-based tab INDEX and optionally display BUFFER there."
  (let ((gm/workspace--routing t))
    (tab-bar-select-tab index)
    (if (buffer-live-p buffer)
        (let ((window (gm/session--editor-window)))
          (when (window-live-p window)
            (select-window window)
            (switch-to-buffer buffer)))
      (gm/workspace--select-compatible-buffer))
    (gm/workspace-sync-explorer)))

(defun gm/workspace-route-selected-file ()
  "Route the interactively selected file into its registered workspace tab."
  (when (and gm/workspace-routing-enabled
             (not gm/workspace--routing)
             (not (active-minibuffer-window))
             (not (window-parameter (selected-window) 'window-side))
             buffer-file-name
             (eq (current-buffer) (window-buffer (selected-window))))
    (let* ((buffer (current-buffer))
           (root (gm/workspace-buffer-git-root buffer))
           (destination (or (and root (gm/workspace--repository-tab-index root))
                            (gm/workspace--global-tab-index)))
           (current (1+ (tab-bar--current-tab-index (gm/workspace--tabs)))))
      (when (and destination (/= destination current))
        (gm/workspace--select-tab destination buffer)))))

(defun gm/workspace--select-compatible-buffer ()
  "Display a buffer belonging to the newly selected workspace tab.
Repository tabs recover their most recently used matching file when their
saved editor window contains `*scratch*' or another unrelated buffer."
  (let* ((tab (gm/workspace--current-tab))
         (kind (gm/workspace--tab-kind tab))
         (current-file-p (buffer-file-name (current-buffer)))
         (current-compatible-p
          (and current-file-p
               (gm/workspace--buffer-belongs-to-tab-p (current-buffer) tab))))
    (when (or (and current-file-p (not current-compatible-p))
              (and (eq kind 'repository) (not current-file-p)))
      (let ((replacement
             (seq-find (lambda (buffer)
                         (and (buffer-file-name buffer)
                              (gm/workspace--buffer-belongs-to-tab-p buffer tab)))
                       (buffer-list))))
        (switch-to-buffer (or replacement (get-buffer-create "*scratch*")))))))

(defun gm/workspace-explorer-root ()
  "Return the explorer root for the selected workspace tab."
  (or (gm/workspace-current-root) (gm/treemacs-home-directory)))

(defun gm/workspace-explorer-name ()
  "Return the explorer root label for the selected workspace tab."
  (if-let ((root (gm/workspace-current-root)))
      (file-name-nondirectory (directory-file-name root))
    "Home"))

(defun gm/workspace-sync-explorer ()
  "Render Treemacs at the selected tab's root without stealing focus."
  (when (and (not gm/workspace--suppress-explorer-sync)
             (display-graphic-p)
             (not (window-minibuffer-p))
             (require 'treemacs nil t))
    ;; Treemacs keys project roots without a trailing slash.  Its file-follow
    ;; parent walker strips slashes as it ascends, so storing "/repo/" in the
    ;; DOM makes the otherwise equivalent "/repo" impossible to find.
    (let ((root (directory-file-name (gm/workspace-explorer-root)))
          (name (gm/workspace-explorer-name)))
      (if (not (file-directory-p root))
          (message "Workspace root is unavailable: %s" root)
        (save-selected-window
          ;; Treemacs follows the origin file from inside its initialization.
          ;; With a newly replaced single-project workspace its DOM may not yet
          ;; contain the root node, and `treemacs-find-file-node' then walks the
          ;; parent of "/" forever.  Render with following disabled and let the
          ;; normal post-command follow hook synchronize once initialization has
          ;; completely unwound.
          (let ((follow-after-init (and (boundp 'treemacs-follow-after-init)
                                        (symbol-value 'treemacs-follow-after-init))))
            (unwind-protect
                (progn
                  (set 'treemacs-follow-after-init nil)
                  (treemacs-follow-mode -1)
                  (treemacs--show-single-project root name))
              (set 'treemacs-follow-after-init follow-after-init)
              (treemacs-follow-mode 1))))))))

;;;###autoload
(defun gm/workspace-open (directory)
  "Create or select the Git workspace containing DIRECTORY."
  (interactive
   (list (read-directory-name
          "Open Git workspace: "
          (or (gm/workspace-current-root)
              (gm/workspace-git-root)
              default-directory)
          nil t)))
  (let ((root (gm/workspace-git-root directory)))
    (unless root
      (user-error "%s is not inside a Git worktree" directory))
    (if-let ((existing (gm/workspace--repository-tab-index root)))
        (gm/workspace--select-tab existing)
      (let ((gm/workspace--creating-tab t)
            (gm/workspace--routing t))
        (tab-bar-new-tab)
        (gm/workspace--mark-tab (gm/workspace--current-tab) 'repository root)
        (gm/workspace--refresh-tab-names)
        (gm/workspace--select-compatible-buffer)
        (gm/workspace-sync-explorer)))
    (message "Workspace: %s" root)))

;;;###autoload
(defun gm/workspace-switch ()
  "Select Global or one of the registered repository workspaces."
  (interactive)
  (let* ((tabs (gm/workspace--tabs))
         (choices
          (cl-loop for tab in tabs
                   for index from 1
                   when (memq (gm/workspace--tab-kind tab) '(global repository))
                   collect (cons (alist-get 'name tab) index)))
         (choice (completing-read "Workspace: " choices nil t nil nil
                                  (alist-get 'name (gm/workspace--current-tab)))))
    (gm/workspace--select-tab (alist-get choice choices nil nil #'string=))))

;;;###autoload
(defun gm/workspace-global ()
  "Switch to the permanent Global loose-file workspace."
  (interactive)
  (gm/workspace--ensure-global-tab)
  (gm/workspace--select-tab (gm/workspace--global-tab-index))
  (gm/workspace--select-compatible-buffer))

;;;###autoload
(defun gm/workspace-close ()
  "Close the current repository workspace without killing its buffers."
  (interactive)
  (let* ((tab (gm/workspace--current-tab))
         (kind (gm/workspace--tab-kind tab)))
    (unless (eq kind 'repository)
      (user-error "Only repository workspaces can be closed"))
    (let ((current (1+ (tab-bar--current-tab-index (gm/workspace--tabs))))
          (global (gm/workspace--global-tab-index))
          (root (gm/workspace--tab-root tab))
          (gm/workspace--routing t))
      (tab-bar-close-tab current global)
      (gm/workspace--refresh-tab-names)
      (gm/workspace-sync-explorer)
      (message "Closed workspace %s; its buffers remain open" root))))

(defun gm/workspace--after-tab-select (_from-tab _to-tab)
  "Synchronize buffers and explorer after a tab-bar selection."
  (unless gm/workspace--routing
    (let ((gm/workspace--routing t))
      (gm/workspace--select-compatible-buffer)
      (gm/workspace-sync-explorer))))

(defun gm/workspace-after-session-restore ()
  "Normalize restored tabs, enable routing, and render the active explorer."
  (let ((gm/workspace--suppress-explorer-sync t))
    (gm/workspace--ensure-global-tab)
    (gm/workspace--refresh-tab-names)
    (setq gm/workspace-routing-enabled nil)
    (let* ((root (and (gm/session--local-file-p gm/session-last-file)
                      (file-readable-p gm/session-last-file)
                      (gm/workspace-git-root gm/session-last-file)))
           (destination (or (and root (gm/workspace--repository-tab-index root))
                            (gm/workspace--global-tab-index))))
      (when destination
        (gm/workspace--select-tab destination)))
    (gm/workspace--select-compatible-buffer)
    (setq gm/workspace-routing-enabled t)))

(defun gm/treemacs-home-directory ()
  "Return the canonical home directory used as the explorer root."
  (directory-file-name (file-truename (expand-file-name "~/"))))

(defun gm/treemacs-root-up ()
  "Move the explorer root to its parent directory."
  (interactive)
  (when (gm/workspace-current-root)
    (user-error "Repository roots are fixed; switch to Global to browse outside"))
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

(defvar gm/treemacs-global-button-map
  (let ((map (make-sparse-keymap)))
    (define-key map [header-line mouse-1] #'gm/workspace-global)
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
   (if (gm/workspace-current-root)
       (concat
        (propertize " ◉ Global "
                    'face 'mode-line
                    'mouse-face 'mode-line-highlight
                    'help-echo "Switch to the Global loose-file workspace (~)"
                    'local-map gm/treemacs-global-button-map)
        (propertize (format " %s " (gm/workspace-explorer-name))
                    'face 'mode-line-emphasis))
     (concat
      (propertize " ↑ Parent "
                  'face 'mode-line
                  'mouse-face 'mode-line-highlight
                  'help-echo "Move the Global explorer root to its parent (^)"
                  'local-map gm/treemacs-parent-button-map)
      (propertize " ⌂ Home "
                  'face 'mode-line
                  'mouse-face 'mode-line-highlight
                  'help-echo "Reset the Global explorer root to $HOME (~)"
                  'local-map gm/treemacs-home-button-map)))
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
  (cond ((and (gm/workspace-current-root)
              (fboundp 'projectile-find-file-in-directory))
         (projectile-find-file-in-directory (gm/workspace-current-root)))
        ((fboundp 'projectile-find-file) (call-interactively #'projectile-find-file))
        ((fboundp 'project-find-file) (call-interactively #'project-find-file))
        (t (call-interactively #'find-file))))

(defun gm/project-status ()
  "Open Magit or VC status at the active workspace/project root."
  (interactive)
  (let ((root (gm/project-root)))
    (if (fboundp 'magit-status-setup-buffer)
        (magit-status-setup-buffer root)
      (vc-dir root))))

(defun gm/toggle-explorer ()
  "Toggle the Treemacs project explorer."
  (interactive)
  (if (fboundp 'treemacs)
      (treemacs)
    (user-error "Treemacs is not installed; run bin/bootstrap-macos")))

(defun gm/treemacs-show-home ()
  "Switch to Global and reset its explorer root to `$HOME'."
  (interactive)
  (gm/workspace-global)
  (gm/workspace-sync-explorer))

(defun gm/open-explorer ()
  "Open Treemacs at the selected workspace root and follow the editor."
  (when (and (display-graphic-p)
             (not (window-minibuffer-p)))
    (gm/workspace-sync-explorer)))

(defun gm/project-search-panel ()
  "Open persistent project search and temporarily close the explorer."
  (interactive)
  (when (fboundp 'treemacs-quit) (ignore-errors (treemacs-quit)))
  (let ((default-directory (gm/project-root)))
    (cond ((fboundp 'deadgrep) (call-interactively #'deadgrep))
          ((fboundp 'consult-ripgrep) (consult-ripgrep default-directory))
          (t (user-error "Install deadgrep or consult to search projects")))))

(defun gm/select-editor-window (number)
  "Select editor window NUMBER, ignoring side windows."
  (let ((windows (seq-filter
                  (lambda (window) (not (window-parameter window 'window-side)))
                  (window-list))))
    (if-let ((window (nth (1- number) windows)))
        (select-window window)
      (user-error "Editor window %s does not exist" number))))

(defvar-keymap gm/workspace-prefix-map
  :doc "Workspace and session commands."
  "o" #'gm/workspace-open
  "s" #'gm/workspace-switch
  "g" #'gm/workspace-global
  "c" #'gm/workspace-close
  "S" #'gm/session-save-now
  "m" #'gm/project-status)

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
  (global-set-key (kbd "s-{") #'tab-bar-switch-to-prev-tab)
  (global-set-key (kbd "s-}") #'tab-bar-switch-to-next-tab)
  (global-set-key (kbd "s-1") (lambda () (interactive) (gm/select-editor-window 1)))
  (global-set-key (kbd "s-2") (lambda () (interactive) (gm/select-editor-window 2)))
  (global-set-key (kbd "s-3") (lambda () (interactive) (gm/select-editor-window 3)))
  (global-set-key (kbd "C-c w") gm/workspace-prefix-map)
  (setq tab-bar-show t
        tab-bar-close-button-show t
        tab-bar-tab-name-truncated-max 48
        tab-line-tabs-function #'gm/workspace-tab-line-buffers)
  (setq tab-bar-format (remove 'tab-bar-format-add-tab tab-bar-format))
  (tab-bar-mode 1)
  (gm/workspace--ensure-global-tab)
  (gm/workspace--refresh-tab-names)
  (add-hook 'tab-bar-tab-post-open-functions #'gm/workspace--new-tab)
  (add-hook 'tab-bar-tab-post-select-functions #'gm/workspace--after-tab-select)
  (add-hook 'tab-bar-tab-prevent-close-functions #'gm/workspace--prevent-global-close)
  (add-hook 'after-set-visited-file-name-hook #'gm/workspace--reset-buffer-root-cache)
  (add-hook 'post-command-hook #'gm/workspace-route-selected-file)
  (add-hook 'gm/session-after-restore-hook #'gm/workspace-after-session-restore)
  (unless noninteractive
    (add-hook 'emacs-startup-hook #'gm/open-explorer)))

(provide 'gm-project)
;;; gm-project.el ends here
