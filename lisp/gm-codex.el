;;; gm-codex.el --- Native Codex tasks for project workspaces -*- lexical-binding: t; -*-

(require 'button)
(require 'cl-lib)
(require 'gm-core)
(require 'json)
(require 'seq)
(require 'subr-x)

(declare-function diff-hl-update "diff-hl")
(declare-function magit-refresh-all "magit-mode")
(declare-function magit-status "magit-status")
(declare-function treemacs-refresh "treemacs-interface")
(declare-function vterm "vterm")
(declare-function vterm-send-return "vterm")
(declare-function vterm-send-string "vterm")

(defgroup gm-codex nil
  "Project-scoped Codex agent integration."
  :group 'gm)

(defcustom gm/codex-executable "codex"
  "Codex CLI executable used by native tasks."
  :type 'string
  :group 'gm-codex)

(defcustom gm/codex-context-maximum 12000
  "Maximum number of selected characters included in a prompt."
  :type 'integer
  :group 'gm-codex)

(defconst gm/codex-state-file
  (expand-file-name "codex-sessions.el" gm/var-directory)
  "Ignored machine-local file containing project session identifiers.")

(cl-defstruct (gm/codex-task (:constructor gm/codex--make-task))
  root buffer process stderr-buffer policy session-id partial changed-files
  started-at state kind prompt)

(defvar gm/codex--sessions nil
  "Alist mapping canonical project roots to Codex session identifiers.")

(defvar gm/codex--writers (make-hash-table :test #'equal)
  "Canonical project roots with an active workspace-writing task.")

(defvar gm/codex--task-counter 0)
(defvar gm/codex-prompt-history nil)
(defvar-local gm/codex--task nil)

(defvar-keymap gm/codex-command-map
  :doc "Codex agent commands."
  "a" #'gm/codex-task
  "q" #'gm/codex-ask
  "r" #'gm/codex-review
  "f" #'gm/codex-follow-up
  "c" #'gm/codex-cancel
  "d" #'gm/codex-open-diff
  "t" #'gm/codex-terminal)

(defvar-keymap gm-codex-mode-map
  :parent special-mode-map
  "q" #'quit-window
  "k" #'gm/codex-cancel
  "f" #'gm/codex-follow-up
  "d" #'gm/codex-open-diff
  "v" #'gm/codex-visit-changed-file
  "t" #'gm/codex-terminal)

(define-derived-mode gm-codex-mode special-mode "Codex"
  "Major mode for a native Codex task panel."
  (setq-local truncate-lines nil
              header-line-format '(:eval (gm/codex--header-line))))

(define-button-type 'gm-codex-file
  'follow-link t
  'help-echo "Visit changed file"
  'action (lambda (button)
            (find-file (button-get button 'gm-path))
            (when-let ((line (button-get button 'gm-line)))
              (goto-char (point-min))
              (forward-line (1- line)))))

(defun gm/codex--canonical-root (&optional directory)
  "Return the canonical Git root containing DIRECTORY.
Signal a user error when DIRECTORY is not in a Git worktree."
  (let* ((default-directory (or directory default-directory))
         (root (or (locate-dominating-file default-directory ".git")
                   (when-let* ((project (project-current nil)))
                     (project-root project)))))
    (unless (and root (file-exists-p (expand-file-name ".git" root)))
      (user-error "Codex tasks require a Git repository"))
    (file-name-as-directory (file-truename root))))

(defun gm/codex--project-name (root)
  "Return a display name for project ROOT."
  (file-name-nondirectory (directory-file-name root)))

(defun gm/codex--session (root)
  "Return the saved Codex session identifier for ROOT."
  (alist-get root gm/codex--sessions nil nil #'equal))

(defun gm/codex--remember-session (root session-id)
  "Remember SESSION-ID for canonical project ROOT."
  (when (and (stringp session-id) (not (string-empty-p session-id)))
    (setf (alist-get root gm/codex--sessions nil nil #'equal) session-id)
    (gm/codex--save-sessions)))

(defun gm/codex--load-sessions ()
  "Load ignored project session metadata without evaluating it."
  (setq gm/codex--sessions nil)
  (when (file-readable-p gm/codex-state-file)
    (condition-case nil
        (with-temp-buffer
          (insert-file-contents gm/codex-state-file)
          (let ((value (read (current-buffer))))
            (when (listp value)
              (setq gm/codex--sessions value))))
      (error (setq gm/codex--sessions nil)))))

(defun gm/codex--save-sessions ()
  "Persist project session metadata under `gm/var-directory'."
  (make-directory (file-name-directory gm/codex-state-file) t)
  (with-temp-file gm/codex-state-file
    (let ((print-length nil)
          (print-level nil))
      (prin1 gm/codex--sessions (current-buffer))
      (insert "\n"))))

(defun gm/codex--panel-buffer (root)
  "Return the primary Codex panel buffer for ROOT, creating it if needed."
  (let ((buffer (get-buffer-create
                 (gm/codex--panel-name root))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'gm-codex-mode)
        (gm-codex-mode)))
    buffer))

(defun gm/codex--new-auxiliary-buffer (root suffix)
  "Create a Codex buffer for ROOT using SUFFIX and a unique counter."
  (let ((buffer (get-buffer-create
                 (format "%s:%s-%d*"
                         (string-remove-suffix "*" (gm/codex--panel-name root)) suffix
                         (cl-incf gm/codex--task-counter)))))
    (with-current-buffer buffer (gm-codex-mode))
    buffer))

(defun gm/codex--display (buffer)
  "Display BUFFER using the configured right-side panel rule."
  (pop-to-buffer buffer))

(defun gm/codex--panel-name (root)
  "Return a collision-resistant primary panel name for ROOT."
  (format "*Codex:%s@%s*"
          (gm/codex--project-name root)
          (substring (secure-hash 'sha1 root) 0 7)))

(defun gm/codex--current-task (&optional require-task)
  "Return the relevant panel task.
When REQUIRE-TASK is non-nil, signal a user error if none exists."
  (let* ((local (and (derived-mode-p 'gm-codex-mode) gm/codex--task))
         (root (unless local (ignore-errors (gm/codex--canonical-root))))
         (panel (and root (get-buffer (gm/codex--panel-name root))))
         (task (or local
                   (and panel (buffer-local-value 'gm/codex--task panel)))))
    (when (and require-task (not task))
      (user-error "No Codex task is associated with this project"))
    task))

(defun gm/codex--header-line ()
  "Build the dynamic header line for the current Codex task."
  (if-let ((task gm/codex--task))
      (let* ((elapsed (max 0 (- (float-time) (gm/codex-task-started-at task))))
             (session (or (gm/codex-task-session-id task) "pending")))
        (format " Codex  %s  %s  %s  %.0fs  session %s "
                (gm/codex--project-name (gm/codex-task-root task))
                (gm/codex-task-policy task)
                (gm/codex-task-state task)
                elapsed session))
    " Codex  idle "))

(defun gm/codex--insert (task text &optional face)
  "Append TEXT with optional FACE to TASK's panel buffer."
  (when (buffer-live-p (gm/codex-task-buffer task))
    (with-current-buffer (gm/codex-task-buffer task)
      (let ((inhibit-read-only t)
            (at-end (= (point) (point-max))))
        (goto-char (point-max))
        (insert (if face (propertize text 'face face) text))
        (when at-end (goto-char (point-max)))))))

(defun gm/codex--event-value (object key)
  "Return KEY from JSON alist OBJECT, accepting symbol or string keys."
  (or (alist-get key object)
      (alist-get (symbol-name key) object nil nil #'equal)))

(defun gm/codex--resolve-file-reference (root token)
  "Resolve a backticked TOKEN to a file under ROOT and optional line number."
  (let ((path-token token)
        line)
    (when (string-match "\\`\\(.+\\):\\([0-9]+\\)\\(?::[0-9]+\\)?\\'" token)
      (setq path-token (match-string 1 token)
            line (string-to-number (match-string 2 token))))
    (let ((path (if (file-name-absolute-p path-token)
                    (expand-file-name path-token)
                  (expand-file-name (string-remove-prefix "./" path-token) root))))
      (when (and (file-regular-p path)
                 (file-in-directory-p (file-truename path) root))
        (cons path line)))))

(defun gm/codex--insert-agent-message (task text)
  "Append agent TEXT to TASK and buttonize valid backticked project files."
  (when (buffer-live-p (gm/codex-task-buffer task))
    (with-current-buffer (gm/codex-task-buffer task)
      (let ((inhibit-read-only t)
            (start (point-max)))
        (goto-char (point-max))
        (insert "\n" (propertize text 'face 'font-lock-doc-face) "\n")
        (save-excursion
          (goto-char start)
          (while (re-search-forward "`\\([^`\n]+\\)`" nil t)
            (let* ((beginning (match-beginning 1))
                   (end (match-end 1))
                   (token (match-string-no-properties 1))
                   (reference
                    (gm/codex--resolve-file-reference
                     (gm/codex-task-root task) token)))
              (when reference
                (make-text-button beginning end
                                  :type 'gm-codex-file
                                  'gm-path (car reference)
                                  'gm-line (cdr reference))))))))))

(defun gm/codex--render-item (task item completed)
  "Render Codex ITEM for TASK; COMPLETED is non-nil for final events."
  (let* ((type (gm/codex--event-value item 'type))
         (status (gm/codex--event-value item 'status))
         (text (or (gm/codex--event-value item 'text)
                   (gm/codex--event-value item 'message)))
         (command (gm/codex--event-value item 'command))
         (output (gm/codex--event-value item 'aggregated_output))
         (exit-code (gm/codex--event-value item 'exit_code)))
    (pcase type
      ("agent_message"
       (when (and completed (stringp text))
         (gm/codex--insert-agent-message task text)))
      ("reasoning"
       (when (and completed (stringp text))
         (gm/codex--insert task (concat "\nReasoning: " text "\n") 'shadow)))
      ("command_execution"
       (if completed
           (progn
             (gm/codex--insert task
                               (format "\nCommand finished%s%s\n"
                                       (if (numberp exit-code)
                                           (format " (exit %d)" exit-code) "")
                                       (if status (format " [%s]" status) ""))
                               (if (and (numberp exit-code) (not (zerop exit-code)))
                                   'error 'success))
             (when (and (stringp output) (not (string-empty-p output)))
               (gm/codex--insert task (concat output (unless (string-suffix-p "\n" output) "\n")))))
         (gm/codex--insert task (format "\n$ %s\n" (or command "command")) 'font-lock-keyword-face)))
      ("file_change"
       (gm/codex--insert task
                         (format "\n%s file changes\n" (if completed "Applied" "Applying"))
                         (if completed 'success 'warning)))
      ((or "mcp_tool_call" "collab_tool_call")
       (gm/codex--insert task
                         (format "\n%s%s\n" (if completed "Finished " "Started ") type)
                         'font-lock-function-name-face))
      (_
       (when completed
         (gm/codex--insert task (format "\nCompleted %s\n" (or type "item")) 'shadow))))))

(defun gm/codex--render-event (task event)
  "Render one parsed Codex JSON EVENT for TASK."
  (let ((type (gm/codex--event-value event 'type)))
    (pcase type
      ("thread.started"
       (let ((session (or (gm/codex--event-value event 'thread_id)
                          (gm/codex--event-value event 'threadId))))
         (setf (gm/codex-task-session-id task) session)
         (gm/codex--remember-session (gm/codex-task-root task) session)
         (gm/codex--insert task (format "Session %s\n" session) 'shadow)))
      ("turn.started"
       (setf (gm/codex-task-state task) "running")
       (gm/codex--insert task "Agent turn started\n" 'success))
      ("item.started"
       (gm/codex--render-item task (gm/codex--event-value event 'item) nil))
      ("item.completed"
       (gm/codex--render-item task (gm/codex--event-value event 'item) t))
      ("turn.completed"
       (setf (gm/codex-task-state task) "completed")
       (gm/codex--insert task "\nAgent turn completed\n" 'success))
      ((or "turn.failed" "error")
       (let* ((error-object (gm/codex--event-value event 'error))
              (message (or (and (listp error-object)
                                (gm/codex--event-value error-object 'message))
                           (gm/codex--event-value event 'message)
                           "Codex reported an error")))
         (setf (gm/codex-task-state task) "failed")
         (gm/codex--insert task (format "\nError: %s\n" message) 'error)))
      (_
       (gm/codex--insert task (format "[%s]\n" (or type "unknown event")) 'shadow)))))

(defun gm/codex--consume-output (task chunk)
  "Parse complete JSONL records from CHUNK for TASK."
  (let* ((text (concat (or (gm/codex-task-partial task) "") chunk))
         (lines (split-string text "\n"))
         (complete (butlast lines))
         (partial (car (last lines))))
    (setf (gm/codex-task-partial task) partial)
    (dolist (line complete)
      (unless (string-empty-p line)
        (condition-case error-data
            (gm/codex--render-event
             task (json-parse-string line :object-type 'alist :array-type 'list
                                     :null-object nil :false-object nil))
          (error
           (gm/codex--insert task
                             (format "Malformed Codex event: %s\n" (error-message-string error-data))
                             'warning)))))))

(defun gm/codex--process-filter (process chunk)
  "Consume JSONL CHUNK emitted by Codex PROCESS."
  (when-let ((task (process-get process 'gm-codex-task)))
    (gm/codex--consume-output task chunk)))

(defun gm/codex--git-changed-files (root)
  "Return current changed and untracked paths under Git ROOT."
  (let ((default-directory root))
    (condition-case nil
        (delete-dups
         (mapcar
          (lambda (line)
            (let ((path (substring line (min 3 (length line)))))
              (if (string-match " -> \\(.+\\)\\'" path)
                  (match-string 1 path)
                path)))
          (process-lines "git" "status" "--porcelain=v1" "--untracked-files=all")))
      (error nil))))

(defun gm/codex--insert-changed-files (task)
  "Append clickable workspace changes for TASK."
  (let ((files (gm/codex--git-changed-files (gm/codex-task-root task))))
    (setf (gm/codex-task-changed-files task) files)
    (when files
      (gm/codex--insert task "\nWorkspace changes\n" 'font-lock-keyword-face)
      (with-current-buffer (gm/codex-task-buffer task)
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (dolist (file files)
            (insert "  ")
            (insert-text-button
             file :type 'gm-codex-file
             'gm-path (expand-file-name file (gm/codex-task-root task)))
            (insert "\n")))))))

(defun gm/codex--refresh-workspace (task)
  "Refresh clean visiting buffers after TASK and report conflicts."
  (let ((root (gm/codex-task-root task))
        conflicts)
    (dolist (buffer (buffer-list))
      (when-let ((file (buffer-local-value 'buffer-file-name buffer)))
        (when (file-in-directory-p (file-truename file) root)
          (with-current-buffer buffer
            (unless (verify-visited-file-modtime buffer)
              (if (buffer-modified-p)
                  (push (file-relative-name file root) conflicts)
                (condition-case nil
                    (revert-buffer t t)
                  (error (push (file-relative-name file root) conflicts)))))
            (when (fboundp 'diff-hl-update)
              (ignore-errors (diff-hl-update)))))))
    (when (fboundp 'treemacs-refresh)
      (ignore-errors (treemacs-refresh)))
    (when (fboundp 'magit-refresh-all)
      (ignore-errors (magit-refresh-all)))
    (when conflicts
      (gm/codex--insert task "\nUnsaved buffers not reverted\n" 'warning)
      (dolist (file (nreverse conflicts))
        (gm/codex--insert task (format "  %s\n" file) 'warning)))))

(defun gm/codex--stderr-text (task)
  "Return captured stderr text for TASK."
  (when (buffer-live-p (gm/codex-task-stderr-buffer task))
    (with-current-buffer (gm/codex-task-stderr-buffer task)
      (string-trim (buffer-string)))))

(defun gm/codex--process-sentinel (process event)
  "Finalize Codex PROCESS after EVENT."
  (when-let ((task (process-get process 'gm-codex-task)))
    (when (and (gm/codex-task-partial task)
               (not (string-empty-p (gm/codex-task-partial task))))
      (gm/codex--consume-output task "\n"))
    (let ((state (gm/codex-task-state task)))
      (cond
       ((equal state "cancelling")
        (setf (gm/codex-task-state task) "cancelled"))
       ((not (member state '("completed" "failed" "cancelled")))
        (setf (gm/codex-task-state task)
              (if (zerop (process-exit-status process)) "completed" "failed")))))
    (when (not (zerop (process-exit-status process)))
      (when-let ((stderr (gm/codex--stderr-text task)))
        (unless (string-empty-p stderr)
          (gm/codex--insert task (format "\nCodex stderr\n%s\n" stderr) 'error))))
    (gm/codex--insert task (format "\nProcess %s" (string-trim event))
                      (pcase (gm/codex-task-state task)
                        ("completed" 'success)
                        ("cancelled" 'warning)
                        (_ 'error)))
    (when (equal (gm/codex-task-policy task) "workspace-write")
      (when (eq (gethash (gm/codex-task-root task) gm/codex--writers) task)
        (remhash (gm/codex-task-root task) gm/codex--writers))
      (gm/codex--refresh-workspace task))
    (gm/codex--insert-changed-files task)
    (when (buffer-live-p (gm/codex-task-stderr-buffer task))
      (kill-buffer (gm/codex-task-stderr-buffer task)))
    (force-mode-line-update t)))

(defun gm/codex--build-command (root policy kind &optional session-id)
  "Build a shell-free Codex command for ROOT, POLICY, KIND, and SESSION-ID."
  (let ((common (list "-c" "approval_policy=\"never\""
                      "-c" "sandbox_workspace_write.network_access=false")))
    (pcase kind
      ('resume
       (append (list gm/codex-executable "exec" "resume" "--json") common
               (list "-c" (format "sandbox_mode=\"%s\"" policy)
                     session-id "-")))
      ('review
       (append (list gm/codex-executable "exec" "review" "--json" "--uncommitted")
               common (list "-c" "sandbox_mode=\"read-only\"" "-")))
      (_
       (append (list gm/codex-executable "exec" "--json" "--color" "never"
                     "--cd" root "--sandbox" policy)
               common (list "-"))))))

(defun gm/codex--modified-project-buffers (root)
  "Return modified file-visiting buffers underneath ROOT."
  (seq-filter
   (lambda (buffer)
     (with-current-buffer buffer
       (and buffer-file-name
            (buffer-modified-p)
            (file-in-directory-p (file-truename buffer-file-name) root))))
   (buffer-list)))

(defun gm/codex--save-project-buffers (root)
  "Offer to save modified project buffers underneath ROOT."
  (when (gm/codex--modified-project-buffers root)
    (save-some-buffers
     nil (lambda ()
           (and buffer-file-name
                (file-in-directory-p (file-truename buffer-file-name) root))))
    (when (gm/codex--modified-project-buffers root)
      (user-error "Save or revert modified project buffers before starting a writing task"))))

(defun gm/codex--active-writer (root)
  "Return ROOT's live writer task, removing a stale lock when necessary."
  (when-let ((task (gethash root gm/codex--writers)))
    (if (process-live-p (gm/codex-task-process task))
        task
      (remhash root gm/codex--writers)
      nil)))

(defun gm/codex--context (root)
  "Describe current editor context relative to project ROOT."
  (let* ((file buffer-file-name)
         (inside (and file (file-in-directory-p (file-truename file) root)))
         (line (line-number-at-pos))
         (region (use-region-p))
         (start (and region (region-beginning)))
         (end (and region (region-end)))
         (selection (and region (buffer-substring-no-properties start end))))
    (string-join
     (delq nil
           (list "Editor context:"
                 (format "Project: %s" root)
                 (when inside (format "File: %s" (file-relative-name file root)))
                 (when inside (format "Point: line %d" line))
                 (when region
                   (format "Selected lines: %d-%d"
                           (line-number-at-pos start) (line-number-at-pos end)))
                 (when selection
                   (let ((truncated (> (length selection) gm/codex-context-maximum)))
                     (format "Selected text%s:\n%s"
                             (if truncated " (truncated)" "")
                             (substring selection 0 (min (length selection)
                                                         gm/codex-context-maximum)))))))
     "\n")))

(defun gm/codex--prompt (label root)
  "Read a task using LABEL and append editor context for ROOT."
  (let ((request (string-trim
                  (read-string label nil 'gm/codex-prompt-history))))
    (when (string-empty-p request)
      (user-error "Codex task cannot be empty"))
    (format "User task:\n%s\n\n%s" request (gm/codex--context root))))

(defun gm/codex--start (root prompt policy kind buffer &optional session-id)
  "Start Codex for ROOT with PROMPT, POLICY, KIND, BUFFER, and SESSION-ID."
  (unless (executable-find gm/codex-executable)
    (user-error "Codex CLI is not available on PATH"))
  (when (and (equal policy "workspace-write") (gm/codex--active-writer root))
    (user-error "A workspace-writing Codex task is already active for %s"
                (gm/codex--project-name root)))
  (when (equal policy "workspace-write")
    (gm/codex--save-project-buffers root))
  (let* ((stderr (generate-new-buffer
                  (format " *Codex stderr:%s*" (gm/codex--project-name root))))
         (task (gm/codex--make-task
                :root root :buffer buffer :stderr-buffer stderr :policy policy
                :session-id session-id :partial "" :changed-files nil
                :started-at (float-time) :state "starting" :kind kind :prompt prompt))
         (command (gm/codex--build-command root policy kind session-id))
         process)
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (if (eq kind 'resume)
            (progn
              (goto-char (point-max))
              (insert (format "\n\n--- Follow-up ---\n\n%s\n\n" prompt)))
          (erase-buffer)
          (insert (format "Codex task\nProject: %s\nPolicy: %s\n\n%s\n\n"
                          root policy prompt))))
      (setq-local default-directory root
                  gm/codex--task task))
    (condition-case error-data
        (setq process
              (make-process
               :name (format "gm-codex-%d" (cl-incf gm/codex--task-counter))
               :command command :coding 'utf-8-unix :connection-type 'pipe
               :noquery t :buffer nil :stderr stderr
               :filter #'gm/codex--process-filter
               :sentinel #'gm/codex--process-sentinel))
      (error
       (kill-buffer stderr)
       (with-current-buffer buffer (setq-local gm/codex--task nil))
       (signal (car error-data) (cdr error-data))))
    (setf (gm/codex-task-process task) process)
    (process-put process 'gm-codex-task task)
    (when (equal policy "workspace-write")
      (puthash root task gm/codex--writers))
    (condition-case error-data
        (progn
          (process-send-string process (concat prompt "\n"))
          (process-send-eof process))
      (error
       (when (process-live-p process) (delete-process process))
       (when (eq (gethash root gm/codex--writers) task)
         (remhash root gm/codex--writers))
       (setf (gm/codex-task-state task) "failed")
       (gm/codex--insert task
                         (format "Failed to send prompt: %s\n"
                                 (error-message-string error-data))
                         'error)
       (signal (car error-data) (cdr error-data))))
    (gm/codex--display buffer)
    task))

;;;###autoload
(defun gm/codex-task ()
  "Start a Codex task that may edit the active Git workspace."
  (interactive)
  (let* ((root (gm/codex--canonical-root))
         (prompt (gm/codex--prompt "Codex task: " root)))
    (gm/codex--start root prompt "workspace-write" 'task
                     (gm/codex--panel-buffer root))))

;;;###autoload
(defun gm/codex-ask ()
  "Ask Codex a read-only question about the active Git workspace."
  (interactive)
  (let* ((root (gm/codex--canonical-root))
         (prompt (gm/codex--prompt "Ask Codex (read-only): " root)))
    (gm/codex--start root prompt "read-only" 'ask
                     (gm/codex--new-auxiliary-buffer root "ask"))))

;;;###autoload
(defun gm/codex-review ()
  "Run a read-only Codex review of uncommitted project changes."
  (interactive)
  (let* ((root (gm/codex--canonical-root))
         (instructions (read-string "Review instructions (optional): " nil
                                    'gm/codex-prompt-history))
         (prompt (if (string-empty-p (string-trim instructions))
                     "Review all staged, unstaged, and untracked changes."
                   instructions)))
    (gm/codex--start root prompt "read-only" 'review
                     (gm/codex--new-auxiliary-buffer root "review"))))

;;;###autoload
(defun gm/codex-follow-up ()
  "Continue the Codex session associated with the current project panel."
  (interactive)
  (let* ((task (gm/codex--current-task t))
         (root (gm/codex-task-root task))
         (session (or (gm/codex-task-session-id task) (gm/codex--session root))))
    (unless session
      (user-error "This Codex task has not reported a session identifier yet"))
    (when (process-live-p (gm/codex-task-process task))
      (user-error "Wait for the current Codex turn to finish"))
    (let ((prompt (gm/codex--prompt "Codex follow-up: " root)))
      (gm/codex--start root prompt (gm/codex-task-policy task) 'resume
                       (gm/codex-task-buffer task) session))))

;;;###autoload
(defun gm/codex-cancel ()
  "Interrupt the relevant running Codex task."
  (interactive)
  (let* ((task (gm/codex--current-task t))
         (process (gm/codex-task-process task)))
    (unless (process-live-p process)
      (user-error "The Codex task is not running"))
    (setf (gm/codex-task-state task) "cancelling")
    (interrupt-process process)
    (gm/codex--insert task "\nCancellation requested\n" 'warning)))

;;;###autoload
(defun gm/codex-visit-changed-file ()
  "Visit one changed file reported by the relevant Codex task."
  (interactive)
  (let* ((task (gm/codex--current-task t))
         (files (gm/codex-task-changed-files task)))
    (unless files (user-error "No workspace changes have been reported"))
    (find-file (expand-file-name
                (completing-read "Changed file: " files nil t)
                (gm/codex-task-root task)))))

;;;###autoload
(defun gm/codex-open-diff ()
  "Open Magit status, or VC directory, for the relevant Codex project."
  (interactive)
  (let* ((task (gm/codex--current-task))
         (root (if task (gm/codex-task-root task) (gm/codex--canonical-root))))
    (if (fboundp 'magit-status)
        (magit-status root)
      (vc-dir root))))

;;;###autoload
(defun gm/codex-terminal ()
  "Open or resume interactive Codex in a project-scoped vterm."
  (interactive)
  (unless (executable-find gm/codex-executable)
    (user-error "Codex CLI is not available on PATH"))
  (unless (fboundp 'vterm)
    (user-error "vterm is not installed"))
  (let* ((task (gm/codex--current-task))
         (root (if task (gm/codex-task-root task) (gm/codex--canonical-root)))
         (session (or (and task (gm/codex-task-session-id task))
                      (gm/codex--session root)))
         (name (format "*vterm:codex:%s*" (gm/codex--project-name root)))
         (arguments (append
                     (list gm/codex-executable)
                     (when session (list "resume"))
                     (list "--cd" root "--sandbox" "workspace-write"
                           "--ask-for-approval" "on-request")
                     (when session (list session))))
         (command (mapconcat #'shell-quote-argument arguments " "))
         (existing (get-buffer name)))
    (if (and existing (process-live-p (get-buffer-process existing)))
        (pop-to-buffer existing)
      (let ((default-directory root))
        (vterm name)
        (vterm-send-string command)
        (vterm-send-return)))))

;;;###autoload
(defun gm/codex ()
  "Focus the project Codex panel, starting a task when none exists."
  (interactive)
  (let* ((root (gm/codex--canonical-root))
         (buffer (gm/codex--panel-buffer root)))
    (if (buffer-local-value 'gm/codex--task buffer)
        (gm/codex--display buffer)
      (call-interactively #'gm/codex-task))))

;;;###autoload
(defun gm/codex-toggle ()
  "Toggle the active project's primary Codex panel."
  (interactive)
  (let* ((root (gm/codex--canonical-root))
         (buffer (get-buffer (gm/codex--panel-name root)))
         (window (and buffer (get-buffer-window buffer t))))
    (if window
        (delete-window window)
      (gm/codex))))

(defun gm/codex-capabilities ()
  "Return (OK . DETAIL) for the installed Codex native-task interface."
  (if-let ((executable (executable-find gm/codex-executable)))
      (with-temp-buffer
        (let ((version-status (process-file executable nil t nil "--version"))
              version help-status help)
          (setq version (or (car (last (split-string (buffer-string) "\n" t)))
                            "unknown version"))
          (erase-buffer)
          (setq help-status (process-file executable nil t nil "exec" "--help")
                help (buffer-string))
          (cons (and (zerop version-status) (zerop help-status)
                     (string-match-p "--json" help)
                     (string-match-p "--sandbox" help)
                     (string-match-p "resume" help)
                     (string-match-p "review" help)
                     t)
                version)))
    (cons nil "Codex CLI is not available")))

(defun gm/codex-initialize ()
  "Load Codex state and install native agent keybindings."
  (gm/codex--load-sessions)
  (global-set-key (kbd "C-c a") gm/codex-command-map)
  (global-set-key (kbd "s-i") #'gm/codex-task)
  (global-set-key (kbd "s-I") #'gm/codex-toggle))

(provide 'gm-codex)
;;; gm-codex.el ends here
