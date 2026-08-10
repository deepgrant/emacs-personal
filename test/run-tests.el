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
(require 'gm-session)
(require 'gm-java)
(require 'gm-hocon-mode)
(require 'gm-ui)
(require 'gm-tools)
(require 'gm-codex)
(require 'gm-packages)
(require 'gm-project)
(require 'gm-languages)

(defun gm-test-git-init (directory)
  "Create and return a Git repository at DIRECTORY."
  (make-directory directory t)
  (should (zerop (process-file "git" nil nil nil "init" "--quiet" directory)))
  (file-name-as-directory (file-truename directory)))

(defmacro gm-test-with-workspace-tabs (&rest body)
  "Run BODY with an isolated tab-bar workspace list."
  (declare (indent 0) (debug t))
  `(let ((saved-tabs (copy-tree (tab-bar-tabs)))
         (gm/workspace-routing-enabled nil)
         (gm/workspace--routing nil))
     (unwind-protect
         (progn
           (set-frame-parameter nil 'tabs nil)
           (tab-bar-tabs)
           (gm/workspace--ensure-global-tab)
           ,@body)
       (tab-bar-tabs-set saved-tabs))))

(defun gm-test-window-state-buffer-names (state)
  "Return the leaf buffer names serialized in window STATE."
  (mapcar (lambda (leaf)
            (cadr (assq 'buffer (gm/session--window-state-node-body leaf))))
          (gm/session--window-state-leaves state)))

(defun gm-test-editor-windows ()
  "Return non-side windows in the selected frame."
  (seq-remove (lambda (window) (window-parameter window 'window-side))
              (window-list)))

(defun gm-test-window-width-ratio (buffer)
  "Return BUFFER's share of the selected frame's editor-window width."
  (let* ((windows (gm-test-editor-windows))
         (window (seq-find (lambda (candidate)
                             (eq (window-buffer candidate) buffer))
                           windows)))
    (/ (float (window-total-width window))
       (apply #'+ (mapcar #'window-total-width windows)))))

(defun gm-test-readable-elisp-file-p (file)
  "Return non-nil when every Lisp form in FILE can be read."
  (condition-case nil
      (with-temp-buffer
        (insert-file-contents file)
        (emacs-lisp-mode)
        (check-parens)
        (goto-char (point-min))
        (while (progn
                 (forward-comment (point-max))
                 (not (eobp)))
          (read (current-buffer)))
        t)
    (error nil)))

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

(ert-deftest gm-metals-command-is-an-executable-path-not-a-list ()
  (let ((command (gm/metals-server-command)))
    (should (stringp command))
    (should (file-executable-p command))
    (should (string-suffix-p "/bin/metals-java17" command))))

(ert-deftest gm-metals-commands-are-discoverable-before-client-loads ()
  (dolist (command '(lsp-metals-build-import
                     lsp-metals-doctor-run
                     lsp-metals-reset-workspace))
    (should (commandp command))))

(ert-deftest gm-metals-settings-precede-deferred-client-loading ()
  (should-not lsp-metals-multi-root)
  (should (equal lsp-metals-server-command (gm/metals-server-command)))
  (should (equal lsp-metals-java-home (or (gm/java-home 17) ""))))

(ert-deftest gm-groovy-server-uses-managed-jar-java-and-classpath ()
  (let ((command (gm/groovy-language-server-command)))
    (should (= (length command) 1))
    (should (file-executable-p (car command)))
    (should (string-suffix-p "/bin/groovy-language-server-java21" (car command))))
  (should (string-suffix-p "/.cache/lsp/groovy-language-server-all.jar"
                           lsp-groovy-server-file))
  (should (equal lsp-groovy-classpath
                 ["/opt/homebrew/opt/groovy/libexec/lib"])))

(ert-deftest gm-minimap-is-a-right-side-on-demand-editor-map ()
  (should (eq (key-binding (kbd "C-c m")) #'minimap-mode))
  (should (eq minimap-window-location 'right))
  (should (= minimap-width-fraction 0.12))
  (should (member 'prog-mode minimap-major-modes))
  (should minimap-hide-fringes))

(ert-deftest gm-language-file-associations ()
  (gm/languages-initialize)
  (should (eq (cdr (assoc "\\.ts\\'" auto-mode-alist)) 'typescript-ts-mode))
  (should (eq (cdr (assoc "\\.tsx\\'" auto-mode-alist)) 'tsx-ts-mode)))

(ert-deftest gm-hybrid-keybindings ()
  (gm/project-initialize)
  (gm/codex-initialize)
  (should (eq (key-binding (kbd "s-p")) #'gm/project-find-file))
  (should (eq (key-binding (kbd "s-b")) #'gm/toggle-explorer))
  (should (eq (key-binding (kbd "s-j")) #'gm/toggle-terminal))
  (should (eq (key-binding (kbd "s-{")) #'tab-bar-switch-to-prev-tab))
  (should (eq (key-binding (kbd "s-}")) #'tab-bar-switch-to-next-tab))
  (should (eq (key-binding (kbd "s-i")) #'gm/codex-task))
  (should (eq (key-binding (kbd "s-I")) #'gm/codex-toggle))
  (should (keymapp (key-binding (kbd "C-c a"))))
  (should (keymapp (key-binding (kbd "C-c w"))))
  (should (eq (key-binding (kbd "C-c w o")) #'gm/workspace-open))
  (should (eq (key-binding (kbd "C-c w S")) #'gm/session-save-now)))

(ert-deftest gm-explorer-home-and-navigation-controls ()
  (should (equal (gm/treemacs-home-directory)
                 (directory-file-name (file-truename (expand-file-name "~/")))))
  (let ((header (gm/treemacs-header-line)))
    (should (string-match-p "Parent" header))
    (should (string-match-p "Home" header))
    (should (get-text-property 1 'local-map header))))

(ert-deftest gm-explorer-does-not-initialize-inside-desktop-restoration ()
  (let ((gm/workspace--suppress-explorer-sync t))
    (cl-letf (((symbol-function 'display-graphic-p)
               (lambda (&optional _display) (error "Treemacs was reached"))))
      (should-not (gm/workspace-sync-explorer)))))

(ert-deftest gm-explorer-renders-before-enabling-file-follow ()
  (let ((gm/workspace--suppress-explorer-sync nil)
        (treemacs-follow-after-init t)
        (treemacs-follow-mode t)
        rendered-root
        calls)
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
              ((symbol-function 'require) (lambda (&rest _) t))
              ((symbol-function 'gm/workspace-explorer-root)
               (lambda () temporary-file-directory))
              ((symbol-function 'gm/workspace-explorer-name) (lambda () "tmp"))
              ((symbol-function 'treemacs--show-single-project)
               (lambda (root _name)
                 (setq rendered-root root)
                 (push (list 'render
                             (symbol-value 'treemacs-follow-after-init)
                             (symbol-value 'treemacs-follow-mode))
                       calls)))
              ((symbol-function 'treemacs-follow-mode)
               (lambda (argument)
                 (set 'treemacs-follow-mode (> argument 0))
                 (push (list 'follow argument) calls))))
      (gm/workspace-sync-explorer)
      (should (equal rendered-root
                     (directory-file-name temporary-file-directory)))
      (should (equal (nreverse calls)
                     '((follow -1) (render nil nil) (follow 1)))))))

(ert-deftest gm-explorer-defers-follow-until-root-dom-is-ready ()
  (let ((called nil)
        (root-position nil))
    (cl-letf (((symbol-function 'treemacs--find-project-for-path)
               (lambda (_) 'project))
              ((symbol-function 'treemacs-project->path)
               (lambda (_) "/workspace"))
              ((symbol-function 'treemacs-find-in-dom)
               (lambda (_) 'root-node))
              ((symbol-function 'treemacs-dom-node->position)
               (lambda (_) root-position)))
      (should-not
       (gm/treemacs--find-file-node-when-root-ready
        (lambda (&rest _) (setq called t)) "/workspace/file"))
      (should-not called)
      (setq root-position 1)
      (should
       (gm/treemacs--find-file-node-when-root-ready
        (lambda (&rest _) (setq called t)) "/workspace/file"))
      (should called))))

(ert-deftest gm-session-restores-only-local-file-buffers ()
  (should (gm/session-save-buffer-p "/tmp/example" "example" 'text-mode))
  (should-not (gm/session-save-buffer-p nil "*vterm*" 'vterm-mode))
  (should-not (gm/session-save-buffer-p "/ssh:host:/tmp/example" "example" 'text-mode)))

(ert-deftest gm-session-uses-ignored-pid-safe-desktop-state ()
  (let ((gm/session-directory (file-name-as-directory
                               (make-temp-file "gm-session-state-" t)))
        (desktop-globals-to-save (copy-sequence desktop-globals-to-save)))
    (unwind-protect
        (progn
          (gm/session-initialize)
          (should (equal desktop-path (list gm/session-directory)))
          (should (equal desktop-dirname gm/session-directory))
          (should (eq desktop-load-locked-desktop 'check-pid))
          (should (= desktop-auto-save-timeout 60))
          (should desktop-restore-frames)
          (should (eq desktop-buffers-not-to-save-function
                      #'gm/session-save-buffer-p))
          (should (assq 'lsp-mode desktop-minor-mode-table))
          (should-not (cadr (assq 'lsp-mode desktop-minor-mode-table)))
          (should (eq (alist-get 'lsp-mode desktop-minor-mode-handlers)
                      #'gm/session--ignore-restored-minor-mode))
          (should (memq 'gm/session-last-file desktop-globals-to-save))
          (should (advice-member-p #'gm/session--read-with-recovery
                                   #'desktop-read))
          (should (memq #'gm/session--startup-failsafe emacs-startup-hook))
          (should-not desktop-save-mode))
      (remove-hook 'buffer-list-update-hook #'gm/session-track-focused-file)
      (remove-hook 'desktop-after-read-hook #'gm/session--finish-restore)
      (remove-hook 'desktop-no-desktop-file-hook #'gm/session--initialize-new-desktop)
      (remove-hook 'desktop-not-loaded-hook #'gm/session--decline-locked-desktop)
      (remove-hook 'emacs-startup-hook #'gm/session--startup-failsafe)
      (delete-directory gm/session-directory t))))

(ert-deftest gm-session-defers-language-processes-until-the-buffer-is-used ()
  (with-temp-buffer
    (let ((gm/session-restoring-p t)
          flycheck-started
          lsp-started)
      (gm/lsp-deferred-if-available)
      (should (memq #'gm/language-services-after-session-command
                    post-command-hook))
      (setq gm/session-restoring-p nil)
      (cl-letf (((symbol-function 'flycheck-mode)
                 (lambda (&optional _argument) (setq flycheck-started t)))
                ((symbol-function 'gm/lsp-start-for-current-buffer)
                 (lambda () (setq lsp-started t))))
        (gm/language-services-after-session-command))
      (should flycheck-started)
      (should lsp-started)
      (should-not (memq #'gm/language-services-after-session-command
                        post-command-hook)))))

(ert-deftest gm-session-corrupt-desktop-is-quarantined-and-services-recover ()
  (let* ((gm/session-directory
          (file-name-as-directory (make-temp-file "gm-session-corrupt-" t)))
         (desktop-dirname gm/session-directory)
         (desktop-path (list gm/session-directory))
         (desktop-base-file-name "gm-desktop.el")
         (desktop-base-lock-name "gm-desktop.lock")
         (desktop-globals-to-save (copy-sequence desktop-globals-to-save))
         (desktop-buffers-not-to-save-function #'gm/session-save-buffer-p)
         (desktop-restore-frames t)
         (desktop-save-mode nil)
         (gm/session-restoring-p t)
         (gm/session-restored-p nil)
         (gm/session-last-file nil)
         (gm/session--last-restore-error nil)
         (routing-enabled nil)
         (gm/session-after-restore-hook
          (list (lambda () (setq routing-enabled t))))
         (corrupt-contents "(setq gm/session-last-file \"truncated\"")
         warning-text
         flycheck-started
         lsp-started)
    (unwind-protect
        (with-temp-buffer
          (with-temp-file (desktop-full-file-name gm/session-directory)
            (insert corrupt-contents))
          (gm/lsp-deferred-if-available)
          (should (memq #'gm/language-services-after-session-command
                        post-command-hook))
          (cl-letf (((symbol-function 'display-warning)
                     (lambda (_type message &optional _level _buffer-name)
                       (setq warning-text message))))
            (should-not
             (gm/session--read-with-recovery
              (lambda (&rest _) (error "truncated desktop")))))
          (let ((quarantined
                 (directory-files gm/session-directory t
                                  "\\`gm-desktop\\.el\\.corrupt-")))
            (should (= (length quarantined) 1))
            (should (equal (with-temp-buffer
                             (insert-file-contents-literally (car quarantined))
                             (buffer-string))
                           corrupt-contents))
            (should (string-match-p (regexp-quote (car quarantined))
                                    warning-text)))
          (should (file-exists-p (desktop-full-file-name gm/session-directory)))
          (should (gm-test-readable-elisp-file-p
                   (desktop-full-file-name gm/session-directory)))
          (should desktop-save-mode)
          (should gm/session-restored-p)
          (should-not gm/session-restoring-p)
          (should routing-enabled)
          (should (string-match-p "truncated desktop" warning-text))
          (cl-letf (((symbol-function 'flycheck-mode)
                     (lambda (&optional _argument) (setq flycheck-started t)))
                    ((symbol-function 'gm/lsp-start-for-current-buffer)
                     (lambda () (setq lsp-started t))))
            (gm/language-services-after-session-command))
          (should flycheck-started)
          (should lsp-started)
          (should-not (memq #'gm/language-services-after-session-command
                            post-command-hook)))
      (desktop-save-mode -1)
      (ignore-errors (desktop-release-lock gm/session-directory))
      (delete-directory gm/session-directory t))))

(ert-deftest gm-session-quarantine-failure-disables-saving-but-finishes ()
  (let* ((gm/session-directory
          (file-name-as-directory (make-temp-file "gm-session-quarantine-fail-" t)))
         (desktop-dirname gm/session-directory)
         (desktop-base-file-name "gm-desktop.el")
         (desktop-base-lock-name "gm-desktop.lock")
         (gm/session-restoring-p t)
         (gm/session-restored-p nil)
         (gm/session-last-file nil)
         (gm/session-after-restore-hook nil)
         mode-calls
         warning-text)
    (unwind-protect
        (progn
          (with-temp-file (desktop-full-file-name gm/session-directory)
            (insert "broken"))
          (cl-letf (((symbol-function 'desktop-save-mode)
                     (lambda (argument) (push argument mode-calls)))
                    ((symbol-function 'rename-file)
                     (lambda (&rest _) (error "quarantine denied")))
                    ((symbol-function 'display-warning)
                     (lambda (_type message &optional _level _buffer-name)
                       (setq warning-text message))))
            (should-not
             (gm/session--read-with-recovery
              (lambda (&rest _) (error "unreadable desktop")))))
          (should (equal mode-calls '(-1)))
          (should (file-exists-p (desktop-full-file-name gm/session-directory)))
          (should (string-match-p "quarantine denied" warning-text))
          (should gm/session-restored-p)
          (should-not gm/session-restoring-p))
      (delete-directory gm/session-directory t))))

(ert-deftest gm-session-fresh-save-failure-preserves-quarantine-and-finishes ()
  (let* ((gm/session-directory
          (file-name-as-directory (make-temp-file "gm-session-save-fail-" t)))
         (desktop-dirname gm/session-directory)
         (desktop-base-file-name "gm-desktop.el")
         (desktop-base-lock-name "gm-desktop.lock")
         (gm/session-restoring-p t)
         (gm/session-restored-p nil)
         (gm/session-last-file nil)
         (gm/session-after-restore-hook nil)
         mode-calls
         warning-text)
    (unwind-protect
        (progn
          (with-temp-file (desktop-full-file-name gm/session-directory)
            (insert "broken"))
          (cl-letf (((symbol-function 'desktop-save-mode)
                     (lambda (argument) (push argument mode-calls)))
                    ((symbol-function 'desktop-save)
                     (lambda (&rest _) (error "fresh save denied")))
                    ((symbol-function 'display-warning)
                     (lambda (_type message &optional _level _buffer-name)
                       (setq warning-text message))))
            (should-not
             (gm/session--read-with-recovery
              (lambda (&rest _) (error "unreadable desktop")))))
          (should (equal mode-calls '(-1)))
          (should-not (file-exists-p
                       (desktop-full-file-name gm/session-directory)))
          (should (= (length (directory-files
                              gm/session-directory t
                              "\\`gm-desktop\\.el\\.corrupt-"))
                     1))
          (should (string-match-p "fresh save denied" warning-text))
          (should gm/session-restored-p)
          (should-not gm/session-restoring-p))
      (delete-directory gm/session-directory t))))

(ert-deftest gm-session-finish-clears-restoring-flag-when-hook-fails ()
  (let ((gm/session-restoring-p t)
        (gm/session-restored-p nil)
        (gm/session-after-restore-hook
         (list (lambda () (error "after-restore failure")))))
    (should-error (gm/session--finish-restore)
                  :type 'error)
    (should gm/session-restored-p)
    (should-not gm/session-restoring-p)
    ;; Completion is idempotent and does not run the failing hook again.
    (should-not (gm/session--finish-restore))))

(ert-deftest gm-session-startup-failsafe-releases-incomplete-restore-once ()
  (let* ((gm/session-restoring-p t)
         (gm/session-restored-p nil)
         (gm/session-last-file nil)
         (finish-count 0)
         (gm/session-after-restore-hook
          (list (lambda () (setq finish-count (1+ finish-count)))))
         warnings)
    (cl-letf (((symbol-function 'display-warning)
               (lambda (_type message &optional _level _buffer-name)
                 (push message warnings))))
      (gm/session--startup-failsafe)
      (gm/session--startup-failsafe))
    (should (= finish-count 1))
    (should (= (length warnings) 1))
    (should gm/session-restored-p)
    (should-not gm/session-restoring-p)))

(ert-deftest gm-session-manual-desktop-read-errors-are-not-swallowed ()
  (let ((gm/session-restoring-p nil)
        (gm/session-restored-p t))
    (should-error
     (gm/session--read-with-recovery
      (lambda (&rest _) (error "manual desktop failure")))
     :type 'error)))

(ert-deftest gm-session-surgically-removes-side-window-and-preserves-split ()
  (let ((file-a (make-temp-file "gm-session-window-a-"))
        (file-b (make-temp-file "gm-session-window-b-"))
        file-buffer-a file-buffer-b generated-buffer)
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (setq file-buffer-a (find-file-noselect file-a)
                file-buffer-b (find-file-noselect file-b)
                generated-buffer (get-buffer-create " *gm-session-generated*"))
          (switch-to-buffer file-buffer-a)
          (let ((peer (split-window-right 29)))
            (set-window-buffer peer file-buffer-b))
          (display-buffer-in-side-window
           generated-buffer '((side . left) (slot . 0)))
          (let* ((before-ratio (gm-test-window-width-ratio file-buffer-a))
                 (state (window-state-get (frame-root-window) 'writable))
                 (original (copy-tree state))
                 (safe (gm/session-sanitize-window-state state)))
            (should-not (gm/session--safe-window-state-node-p state))
            (should (equal state original))
            (should (gm/session--safe-window-state-node-p safe))
            (should (equal (sort (gm-test-window-state-buffer-names safe)
                                 #'string<)
                           (sort (list (buffer-name file-buffer-a)
                                       (buffer-name file-buffer-b))
                                 #'string<)))
            (should-not (string-match-p "gm-session-generated"
                                        (prin1-to-string safe)))
            (window-state-put safe (frame-root-window) 'safe)
            (let ((window-a (get-buffer-window file-buffer-a))
                  (window-b (get-buffer-window file-buffer-b)))
              (should (= (length (gm-test-editor-windows)) 2))
              (should (< (window-pixel-left window-a)
                         (window-pixel-left window-b)))
              (should (= (window-pixel-top window-a)
                         (window-pixel-top window-b))))
            (should (< (abs (- before-ratio
                               (gm-test-window-width-ratio file-buffer-a)))
                       0.06))))
      (when (buffer-live-p file-buffer-a) (kill-buffer file-buffer-a))
      (when (buffer-live-p file-buffer-b) (kill-buffer file-buffer-b))
      (when (buffer-live-p generated-buffer) (kill-buffer generated-buffer))
      (delete-file file-a)
      (delete-file file-b))))

(ert-deftest gm-session-preserves-nested-split-orientations ()
  (let ((files (mapcar (lambda (_) (make-temp-file "gm-session-nested-"))
                       '(a b c)))
        buffers generated)
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (setq buffers (mapcar #'find-file-noselect files)
                generated (get-buffer-create " *gm-session-nested-panel*"))
          (switch-to-buffer (nth 0 buffers))
          (let ((right (split-window-right)))
            (set-window-buffer right (nth 1 buffers))
            (with-selected-window right
              (let ((bottom (split-window-below)))
                (set-window-buffer bottom (nth 2 buffers)))))
          (display-buffer-in-side-window
           generated '((side . left) (slot . 0)))
          (let ((safe (gm/session-sanitize-window-state
                       (window-state-get (frame-root-window) 'writable))))
            (window-state-put safe (frame-root-window) 'safe)
            (let ((a (get-buffer-window (nth 0 buffers)))
                  (b (get-buffer-window (nth 1 buffers)))
                  (c (get-buffer-window (nth 2 buffers))))
              (should (= (length (gm-test-editor-windows)) 3))
              (should (< (window-pixel-left a) (window-pixel-left b)))
              (should (= (window-pixel-left b) (window-pixel-left c)))
              (should (< (window-pixel-top b) (window-pixel-top c))))))
      (mapc (lambda (buffer)
              (when (buffer-live-p buffer) (kill-buffer buffer)))
            buffers)
      (when (buffer-live-p generated) (kill-buffer generated))
      (mapc #'delete-file files))))

(ert-deftest gm-session-drops-killed-leaf-without-losing-survivor ()
  (let ((file-a (make-temp-file "gm-session-killed-a-"))
        (file-b (make-temp-file "gm-session-killed-b-"))
        buffer-a buffer-b)
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (setq buffer-a (find-file-noselect file-a)
                buffer-b (find-file-noselect file-b))
          (switch-to-buffer buffer-a)
          (let ((peer (split-window-right)))
            (set-window-buffer peer buffer-b)
            (select-window peer))
          (let* ((state (window-state-get (frame-root-window) 'writable))
                 (original (copy-tree state)))
            (kill-buffer buffer-b)
            (setq buffer-b nil)
            (let ((safe (gm/session-sanitize-window-state state)))
              (should (equal state original))
              (should (eq (gm/session--window-state-node-type safe) 'leaf))
              (should (equal (gm-test-window-state-buffer-names safe)
                             (list (buffer-name buffer-a))))
              (should (gm/session--window-state-leaf-selected-p
                       (car (gm/session--window-state-leaves safe)))))))
      (when (buffer-live-p buffer-a) (kill-buffer buffer-a))
      (when (buffer-live-p buffer-b) (kill-buffer buffer-b))
      (delete-file file-a)
      (delete-file file-b))))

(ert-deftest gm-session-falls-back-only-when-no-editor-leaf-survives ()
  (let ((generated (get-buffer-create " *gm-session-only-generated*")))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer generated)
          (let ((safe (gm/session-sanitize-window-state
                       (window-state-get (frame-root-window) 'writable))))
            (should (eq (gm/session--window-state-node-type safe) 'leaf))
            (should (equal (gm-test-window-state-buffer-names safe)
                           '("*scratch*")))))
      (when (buffer-live-p generated) (kill-buffer generated)))))

(ert-deftest gm-session-filters-unsafe-leaf-buffer-history ()
  (let ((file (make-temp-file "gm-session-history-"))
        file-buffer generated)
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (setq file-buffer (find-file-noselect file)
                generated (get-buffer-create " *gm-session-history-generated*"))
          (switch-to-buffer file-buffer)
          (let* ((state (window-state-get (frame-root-window) 'writable))
                 (leaf (car (gm/session--window-state-leaves state)))
                 (generated-name (buffer-name generated)))
            (setcdr leaf
                    (append (cdr leaf)
                            `((next-buffers . (,generated-name "*scratch*"))
                              (prev-buffers . ((,generated-name 1 1)
                                               ("*scratch*" 1 1))))))
            (let ((safe (gm/session-sanitize-window-state state)))
              (should-not (string-match-p (regexp-quote generated-name)
                                          (prin1-to-string safe)))
              (should (string-match-p "\\*scratch\\*"
                                      (prin1-to-string safe))))))
      (when (buffer-live-p file-buffer) (kill-buffer file-buffer))
      (when (buffer-live-p generated) (kill-buffer generated))
      (delete-file file))))

(ert-deftest gm-session-tab-filter-preserves-background-split ()
  (let ((file-a (make-temp-file "gm-session-tab-a-"))
        (file-b (make-temp-file "gm-session-tab-b-"))
        buffer-a buffer-b generated)
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (gm-test-with-workspace-tabs
            (setq buffer-a (find-file-noselect file-a)
                  buffer-b (find-file-noselect file-b)
                  generated (get-buffer-create " *gm-session-tab-panel*"))
            (switch-to-buffer buffer-a)
            (let ((peer (split-window-right 27)))
              (set-window-buffer peer buffer-b))
            (display-buffer-in-side-window
             generated '((side . left) (slot . 0)))
            (let ((before-ratio (gm-test-window-width-ratio buffer-a)))
              (tab-bar-new-tab)
              (let* ((parameter
                      (gm/session--filter-tabs
                       (cons 'tabs (tab-bar-tabs)) nil nil t))
                     (background
                      (seq-find
                       (lambda (tab)
                         (when-let ((state (alist-get 'ws tab)))
                           (member (buffer-name buffer-a)
                                   (gm-test-window-state-buffer-names state))))
                       (cdr parameter)))
                     (state (and background (alist-get 'ws background))))
                (should state)
                (should-not (string-match-p "gm-session-tab-panel"
                                            (prin1-to-string state)))
                (window-state-put state (frame-root-window) 'safe)
                (should (= (length (gm-test-editor-windows)) 2))
                (should (< (abs (- before-ratio
                                   (gm-test-window-width-ratio buffer-a)))
                           0.06))))))
      (when (buffer-live-p buffer-a) (kill-buffer buffer-a))
      (when (buffer-live-p buffer-b) (kill-buffer buffer-b))
      (when (buffer-live-p generated) (kill-buffer generated))
      (delete-file file-a)
      (delete-file file-b))))

(ert-deftest gm-session-secondary-instance-cannot-save-the-primary-desktop ()
  (let ((desktop-save-mode t)
        (gm/session-restored-p nil)
        (gm/session-after-restore-hook nil))
    (gm/session--decline-locked-desktop)
    (should-not desktop-save-mode)
    (should gm/session-restored-p)))

(ert-deftest gm-session-focuses-the-last-surviving-file ()
  (let* ((file (make-temp-file "gm-session-last-"))
         (buffer (find-file-noselect file))
         (gm/session-last-file file))
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer "*scratch*")
          (gm/session-focus-last-file)
          (should (eq (current-buffer) buffer)))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-file file))))

(ert-deftest gm-workspace-resolves-nested-repositories-and-worktrees ()
  (let* ((root (make-temp-file "gm-workspace-git-" t))
         (main (gm-test-git-init (expand-file-name "main" root)))
         (nested (gm-test-git-init (expand-file-name "nested" main)))
         (worktree (expand-file-name "worktree" root)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "tracked" main) (insert "tracked\n"))
          (should (zerop (process-file "git" nil nil nil "-C" main "add" "tracked")))
          (should (zerop (process-file "git" nil nil nil "-C" main
                                       "-c" "user.name=Emacs Test"
                                       "-c" "user.email=emacs@example.invalid"
                                       "commit" "--quiet" "-m" "initial")))
          (should (zerop (process-file "git" nil nil nil "-C" main
                                       "worktree" "add" "--quiet" "-b"
                                       "gm-test-worktree" worktree)))
          (should (equal (gm/workspace-git-root (expand-file-name "tracked" main)) main))
          (should (equal (gm/workspace-git-root nested) nested))
          (should (equal (gm/workspace-git-root worktree)
                         (file-name-as-directory (file-truename worktree)))))
      (delete-directory root t))))

(ert-deftest gm-workspace-creates-reuses-and-closes-repository-tabs ()
  (let* ((root (make-temp-file "gm-workspace-tabs-" t))
         (repo-a (gm-test-git-init (expand-file-name "one/shared" root)))
         (repo-b (gm-test-git-init (expand-file-name "two/shared" root)))
         (file-a (expand-file-name "a.txt" repo-a))
         buffer-a)
    (unwind-protect
        (gm-test-with-workspace-tabs
          (gm/workspace-open repo-a)
          (should (equal (gm/workspace-current-root) repo-a))
          (should (= (length (gm/workspace--tabs)) 2))
          (gm/workspace-open repo-a)
          (should (= (length (gm/workspace--tabs)) 2))
          (gm/workspace-open repo-b)
          (should (= (length (gm/workspace--tabs)) 3))
          (let ((names (mapcar (lambda (tab) (alist-get 'name tab))
                               (seq-filter
                                (lambda (tab)
                                  (eq (gm/workspace--tab-kind tab) 'repository))
                                (gm/workspace--tabs)))))
            (should (seq-every-p (lambda (name) (string-match-p "shared (" name)) names)))
          (with-temp-file file-a (insert "a\n"))
          (setq buffer-a (find-file-noselect file-a))
          (gm/workspace-close)
          (should (buffer-live-p buffer-a))
          (should (= (length (gm/workspace--registered-roots)) 1))
          (gm/workspace-global)
          (should-error (gm/workspace-close) :type 'user-error)
          (should (gm/workspace--prevent-global-close
                   (gm/workspace--current-tab) nil)))
      (when (buffer-live-p buffer-a) (kill-buffer buffer-a))
      (delete-directory root t))))

(ert-deftest gm-workspace-routes-only-displayed-files ()
  (let* ((root (make-temp-file "gm-workspace-route-" t))
         (repo (gm-test-git-init (expand-file-name "repo" root)))
         (repo-file (expand-file-name "repo.txt" repo))
         (loose-file (expand-file-name "loose.txt" root))
         repo-buffer loose-buffer)
    (with-temp-file repo-file (insert "repo\n"))
    (with-temp-file loose-file (insert "loose\n"))
    (unwind-protect
        (gm-test-with-workspace-tabs
          (gm/workspace-open repo)
          (gm/workspace-global)
          (setq repo-buffer (find-file-noselect repo-file))
          (let ((gm/workspace-routing-enabled t))
            (set-window-buffer (selected-window) repo-buffer)
            (with-current-buffer repo-buffer (gm/workspace-route-selected-file))
            (should (equal (gm/workspace-current-root) repo))
            (setq loose-buffer (find-file-noselect loose-file))
            (should (equal (gm/workspace-current-root) repo))
            (set-window-buffer (selected-window) loose-buffer)
            (with-current-buffer loose-buffer (gm/workspace-route-selected-file))
            (should-not (gm/workspace-current-root))))
      (when (buffer-live-p repo-buffer) (kill-buffer repo-buffer))
      (when (buffer-live-p loose-buffer) (kill-buffer loose-buffer))
      (delete-directory root t))))

(ert-deftest gm-workspace-can-return-from-global-by-selecting-its-tab ()
  (let* ((root (make-temp-file "gm-workspace-return-" t))
         (repo (gm-test-git-init (expand-file-name "repo" root)))
         (repo-file (expand-file-name "repo.txt" repo))
         repo-buffer)
    (with-temp-file repo-file (insert "repo\n"))
    (unwind-protect
        (gm-test-with-workspace-tabs
          (gm/workspace-open repo)
          (setq repo-buffer (find-file-noselect repo-file))
          (switch-to-buffer repo-buffer)
          ;; A special buffer can become the saved editor for the repository;
          ;; selecting the workspace must still recover its latest file.
          (switch-to-buffer "*scratch*")
          (gm/workspace-global)
          (should-not (gm/workspace-current-root))
          (tab-bar-select-tab (gm/workspace--repository-tab-index repo))
          (should (equal (gm/workspace-current-root) repo))
          (should (eq (current-buffer) repo-buffer)))
      (when (buffer-live-p repo-buffer) (kill-buffer repo-buffer))
      (delete-directory root t))))

(ert-deftest gm-workspace-filters-file-tabs-and-project-root ()
  (let* ((root (make-temp-file "gm-workspace-filter-" t))
         (repo (gm-test-git-init (expand-file-name "repo" root)))
         (repo-file (expand-file-name "repo.txt" repo))
         (loose-file (expand-file-name "loose.txt" root))
         repo-buffer loose-buffer)
    (with-temp-file repo-file (insert "repo\n"))
    (with-temp-file loose-file (insert "loose\n"))
    (unwind-protect
        (gm-test-with-workspace-tabs
          (setq repo-buffer (find-file-noselect repo-file)
                loose-buffer (find-file-noselect loose-file))
          (gm/workspace-open repo)
          (with-current-buffer repo-buffer
            (should (equal (gm/project-root) repo)))
          (let ((tabs (with-current-buffer repo-buffer
                        (gm/workspace-tab-line-buffers))))
            (should (memq repo-buffer tabs))
            (should-not (memq loose-buffer tabs)))
          (should (equal (gm/workspace-explorer-root) repo))
          (let ((header (gm/treemacs-header-line)))
            (should (string-match-p "Global" header))
            (should-not (string-match-p "Parent" header)))
          (should-error (gm/treemacs-root-up) :type 'user-error)
          (gm/workspace-global)
          (should (equal (gm/workspace-explorer-root) (gm/treemacs-home-directory))))
      (when (buffer-live-p repo-buffer) (kill-buffer repo-buffer))
      (when (buffer-live-p loose-buffer) (kill-buffer loose-buffer))
      (delete-directory root t))))

(ert-deftest gm-workspace-metadata-is-printable-in-desktop-tabs ()
  (let* ((root (make-temp-file "gm-workspace-desktop-" t))
         (repo (gm-test-git-init (expand-file-name "repo" root))))
    (unwind-protect
        (gm-test-with-workspace-tabs
          (gm/workspace-open repo)
          (let* ((tabs (gm/workspace--tabs))
                 (filtered (frameset-filter-tabs tabs nil nil t))
                 (saved-root
                  (seq-some (lambda (tab) (alist-get 'gm-workspace-root tab)) filtered)))
            (should (equal saved-root repo))
            (should (string-match-p (regexp-quote repo) (prin1-to-string filtered)))))
      (delete-directory root t))))

(ert-deftest gm-workspace-tools-use-the-tab-root-from-special-buffers ()
  (let* ((root (make-temp-file "gm-workspace-tools-" t))
         (repo (gm-test-git-init (expand-file-name "repo" root)))
         projectile-root magit-root search-root)
    (unwind-protect
        (gm-test-with-workspace-tabs
          (gm/workspace-open repo)
          (with-temp-buffer
            (setq default-directory root)
            (should (equal (gm/project-root) repo))
            (should (equal (gm/codex--canonical-root) repo))
            (cl-letf (((symbol-function 'projectile-find-file-in-directory)
                       (lambda (directory) (setq projectile-root directory)))
                      ((symbol-function 'magit-status-setup-buffer)
                       (lambda (directory) (setq magit-root directory)))
                      ((symbol-function 'deadgrep)
                       (lambda ()
                         (interactive)
                         (setq search-root default-directory)))
                      ((symbol-function 'treemacs-quit) #'ignore))
              (gm/project-find-file)
              (gm/project-status)
              (gm/project-search-panel))
            (should (equal projectile-root repo))
            (should (equal magit-root repo))
            (should (equal search-root repo))))
      (delete-directory root t))))

(ert-deftest gm-line-numbers-match-vscodium-default ()
  (gm/core-initialize)
  (should (eq display-line-numbers-type t)))

(ert-deftest gm-display-panel-rules ()
  (gm/ui-initialize)
  (should (assoc "\\*deadgrep.*\\*" display-buffer-alist))
  (let ((rule (assoc "\\*Codex:.*\\*" display-buffer-alist)))
    (should rule)
    (should (eq (cdr (assq 'side (cdr rule))) 'right)))
  (should (assoc "\\*\\(?:vterm\\|compilation\\|Flycheck errors\\|sbt\\|Gradle\\).*\\*"
                 display-buffer-alist)))

(ert-deftest gm-codex-builds-safe-shell-free-commands ()
  (let* ((gm/codex-executable "/Applications/ChatGPT.app/Contents/Resources/codex")
         (root "/tmp/example project/")
         (write-command (gm/codex--build-command root "workspace-write" 'task))
         (read-command (gm/codex--build-command root "read-only" 'ask))
         (resume-command (gm/codex--build-command root "workspace-write" 'resume "abc"))
         (review-command (gm/codex--build-command root "read-only" 'review)))
    (should (equal (car write-command) gm/codex-executable))
    (should (member root write-command))
    (should (member "workspace-write" write-command))
    (should (member "read-only" read-command))
    (should (member "approval_policy=\"never\"" write-command))
    (should (member "sandbox_workspace_write.network_access=false" write-command))
    (should (member "sandbox_mode=\"workspace-write\"" resume-command))
    (should (member "sandbox_mode=\"read-only\"" review-command))
    (dolist (command (list write-command read-command resume-command review-command))
      (should-not (member "danger-full-access" command))
      (should-not (member "--dangerously-bypass-approvals-and-sandbox" command))
      (should-not (member "--add-dir" command)))))

(ert-deftest gm-codex-context-identifies-file-lines-and-region ()
  (let* ((root (make-temp-file "gm-codex-context-" t))
         (file (expand-file-name "source.scala" root))
         buffer)
    (unwind-protect
        (progn
          (with-temp-file file (insert "one\ntwo\nthree\n"))
          (setq buffer (find-file-noselect file))
          (with-current-buffer buffer
            (goto-char (point-min))
            (forward-line 1)
            (set-mark (line-beginning-position))
            (goto-char (line-end-position))
            (activate-mark)
            (let ((context (gm/codex--context (file-name-as-directory root))))
              (should (string-match-p "File: source.scala" context))
              (should (string-match-p "Selected lines: 2-2" context))
              (should (string-match-p (regexp-quote "Selected text:\ntwo") context)))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest gm-codex-jsonl-parser-handles-chunks-unknown-and-malformed-events ()
  (let* ((root (file-name-as-directory (make-temp-file "gm-codex-parser-" t)))
         (buffer (generate-new-buffer " *gm-codex-parser*"))
         (task (gm/codex--make-task :root root :buffer buffer :policy "read-only"
                                    :partial "" :started-at (float-time) :state "starting")))
    (unwind-protect
        (cl-letf (((symbol-function 'gm/codex--save-sessions) #'ignore))
          (with-current-buffer buffer (gm-codex-mode) (setq-local gm/codex--task task))
          (gm/codex--consume-output
           task "{\"type\":\"thread.started\",\"thread_id\":\"session-1\"}\n{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_")
          (gm/codex--consume-output
           task "message\",\"text\":\"hello\"}}\n{\"type\":\"future.event\"}\nnot-json\n")
          (should (equal (gm/codex-task-session-id task) "session-1"))
          (with-current-buffer buffer
            (should (string-match-p "hello" (buffer-string)))
            (should (string-match-p "future.event" (buffer-string)))
            (should (string-match-p "Malformed Codex event" (buffer-string)))))
      (kill-buffer buffer)
      (delete-directory root t))))

(ert-deftest gm-codex-buttonizes-project-file-references ()
  (let* ((root (file-name-as-directory (make-temp-file "gm-codex-reference-" t)))
         (file (expand-file-name "source.scala" root))
         (buffer (generate-new-buffer " *gm-codex-reference*"))
         (task (gm/codex--make-task :root root :buffer buffer :policy "read-only"
                                    :started-at (float-time))))
    (unwind-protect
        (progn
          (with-temp-file file (insert "one\ntwo\n"))
          (with-current-buffer buffer (gm-codex-mode))
          (gm/codex--insert-agent-message task "Inspect `source.scala:2` next.")
          (with-current-buffer buffer
            (goto-char (point-min))
            (search-forward "source.scala")
            (let ((button (button-at (1- (point)))))
              (should button)
              (should (equal (button-get button 'gm-path) file))
              (should (= (button-get button 'gm-line) 2)))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest gm-codex-enforces-one-writer-per-project ()
  (let* ((root (file-name-as-directory (make-temp-file "gm-codex-lock-" t)))
         (buffer (generate-new-buffer " *gm-codex-lock*"))
         (lock-process (start-process "gm-codex-lock-test" nil "/bin/sleep" "10"))
         (existing (gm/codex--make-task :root root :buffer buffer
                                        :process lock-process
                                        :policy "workspace-write")))
    (unwind-protect
        (let ((gm/codex--writers (make-hash-table :test #'equal))
              (gm/codex-executable "/usr/bin/true"))
          (puthash root existing gm/codex--writers)
          (should-error
           (gm/codex--start root "test" "workspace-write" 'task buffer)
           :type 'user-error))
      (when (process-live-p lock-process) (delete-process lock-process))
      (kill-buffer buffer)
      (delete-directory root t))))

(ert-deftest gm-codex-refreshes-clean-buffers-and-preserves-dirty-buffers ()
  (let* ((root (file-name-as-directory (make-temp-file "gm-codex-refresh-" t)))
         (clean-file (expand-file-name "clean.txt" root))
         (dirty-file (expand-file-name "dirty.txt" root))
         clean-buffer dirty-buffer panel)
    (unwind-protect
        (progn
          (with-temp-file clean-file (insert "old clean\n"))
          (with-temp-file dirty-file (insert "old dirty\n"))
          (setq clean-buffer (find-file-noselect clean-file)
                dirty-buffer (find-file-noselect dirty-file)
                panel (generate-new-buffer " *gm-codex-refresh-panel*"))
          (with-current-buffer panel (gm-codex-mode))
          (with-current-buffer dirty-buffer
            (goto-char (point-max))
            (insert "user edit\n"))
          (with-temp-file clean-file (insert "agent clean\n"))
          (with-temp-file dirty-file (insert "agent dirty\n"))
          (let ((task (gm/codex--make-task :root root :buffer panel
                                           :policy "workspace-write"
                                           :started-at (float-time))))
            (gm/codex--refresh-workspace task))
          (with-current-buffer clean-buffer
            (should (equal (buffer-string) "agent clean\n")))
          (with-current-buffer dirty-buffer
            (should (buffer-modified-p))
            (should (string-match-p "user edit" (buffer-string))))
          (with-current-buffer panel
            (should (string-match-p "Unsaved buffers not reverted" (buffer-string)))
            (should (string-match-p "dirty.txt" (buffer-string)))))
      (dolist (buffer (list clean-buffer dirty-buffer panel))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer)))
      (delete-directory root t))))

(ert-deftest gm-codex-fake-process-streams-and-records-session ()
  (let* ((root (file-name-as-directory (make-temp-file "gm-codex-process-" t)))
         (gm/codex-executable (expand-file-name "test/fake-codex" gm/config-root))
         (gm/codex-state-file (expand-file-name "sessions.el" root))
         (gm/codex--sessions nil)
         (gm/codex--writers (make-hash-table :test #'equal))
         (buffer (generate-new-buffer " *gm-codex-process*"))
         task process)
    (make-directory (expand-file-name ".git" root))
    (unwind-protect
        (progn
          (with-current-buffer buffer (gm-codex-mode))
          (setq task (gm/codex--start root "test prompt" "read-only" 'ask buffer)
                process (gm/codex-task-process task))
          (while (process-live-p process)
            (accept-process-output process 0.1))
          (accept-process-output process 0.1)
          (should (equal (gm/codex-task-state task) "completed"))
          (should (equal (gm/codex-task-session-id task) "test-session"))
          (should (equal (gm/codex--session root) "test-session"))
          (should (= (hash-table-count gm/codex--writers) 0))
          (with-current-buffer buffer
            (should (string-match-p "Fake Codex completed" (buffer-string)))
            (should (string-match-p "git status" (buffer-string)))))
      (when (process-live-p process) (delete-process process))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest gm-codex-follow-up-preserves-panel-history ()
  (let* ((root (file-name-as-directory (make-temp-file "gm-codex-follow-up-" t)))
         (gm/codex-executable (expand-file-name "test/fake-codex" gm/config-root))
         (gm/codex-state-file (expand-file-name "sessions.el" root))
         (gm/codex--sessions nil)
         (buffer (generate-new-buffer " *gm-codex-follow-up*"))
         task process)
    (make-directory (expand-file-name ".git" root))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (gm-codex-mode)
            (let ((inhibit-read-only t)) (insert "Earlier turn\n")))
          (setq task (gm/codex--start root "follow-up prompt" "read-only"
                                      'resume buffer "previous-session")
                process (gm/codex-task-process task))
          (while (process-live-p process)
            (accept-process-output process 0.1))
          (accept-process-output process 0.1)
          (with-current-buffer buffer
            (should (string-match-p "Earlier turn" (buffer-string)))
            (should (string-match-p "Follow-up" (buffer-string)))
            (should (string-match-p "Fake Codex completed" (buffer-string)))))
      (when (process-live-p process) (delete-process process))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest gm-codex-cancel-interrupts-running-process ()
  (let* ((root (file-name-as-directory (make-temp-file "gm-codex-cancel-" t)))
         (buffer (generate-new-buffer " *gm-codex-cancel*"))
         (process (make-process :name "gm-codex-cancel-test"
                                :command '("/bin/sleep" "10")
                                :noquery t :buffer nil
                                :sentinel #'gm/codex--process-sentinel))
         (task (gm/codex--make-task :root root :buffer buffer :process process
                                    :policy "read-only" :partial ""
                                    :started-at (float-time) :state "running")))
    (unwind-protect
        (progn
          (process-put process 'gm-codex-task task)
          (with-current-buffer buffer
            (gm-codex-mode)
            (setq-local gm/codex--task task)
            (gm/codex-cancel))
          (while (process-live-p process)
            (accept-process-output process 0.1))
          (accept-process-output process 0.1)
          (should (equal (gm/codex-task-state task) "cancelled")))
      (when (process-live-p process) (delete-process process))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest gm-codex-health-checks-required-cli-capabilities ()
  (let ((gm/codex-executable (expand-file-name "test/fake-codex" gm/config-root)))
    (pcase-let ((`(,ok . ,detail) (gm/codex-capabilities)))
      (should ok)
      (should (string-match-p "test-double" detail)))))

(ert-run-tests-batch-and-exit)
;;; run-tests.el ends here
