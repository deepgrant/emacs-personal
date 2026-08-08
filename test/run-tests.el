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
(require 'gm-codex)
(require 'gm-packages)
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
  (should (eq (key-binding (kbd "s-i")) #'gm/codex-task))
  (should (eq (key-binding (kbd "s-I")) #'gm/codex-toggle))
  (should (keymapp (key-binding (kbd "C-c a")))))

(ert-deftest gm-explorer-home-and-navigation-controls ()
  (should (equal (gm/treemacs-home-directory)
                 (directory-file-name (file-truename (expand-file-name "~/")))))
  (let ((header (gm/treemacs-header-line)))
    (should (string-match-p "Parent" header))
    (should (string-match-p "Home" header))
    (should (get-text-property 1 'local-map header))))

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
