;;; gm-session.el --- Persistent editor sessions -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'desktop)
(require 'frameset)
(require 'gm-core)
(require 'seq)
(require 'tab-bar)

(defconst gm/session-directory
  (expand-file-name "desktop/" gm/var-directory)
  "Ignored directory containing the workstation desktop session.")

(defvar gm/session-last-file nil
  "Absolute name of the most recently focused local file.")

(defvar gm/session-restored-p nil
  "Non-nil after desktop restoration has completed or been skipped.")

(defvar gm/session-restoring-p nil
  "Non-nil while Desktop is reconstructing buffers and frame state.")

(defvar gm/session-after-restore-hook nil
  "Hook run after desktop state is restored or a new session is initialized.")

(defconst gm/session-process-minor-modes
  '(dap-mode
    dap-ui-mode
    eglot-managed-mode
    flycheck-mode
    lsp-completion-mode
    lsp-diagnostics-mode
    lsp-headerline-breadcrumb-mode
    lsp-lens-mode
    lsp-managed-mode
    lsp-mode
    lsp-modeline-code-actions-mode
    lsp-modeline-diagnostics-mode
    lsp-modeline-workspace-status-mode
    lsp-treemacs-sync-mode
    lsp-ui-doc-mode
    lsp-ui-mode
    lsp-ui-sideline-mode
    minimap-mode)
  "Process-backed or generated minor modes Desktop must not reactivate.")

(defun gm/session--local-file-p (filename)
  "Return non-nil when FILENAME is a restorable local file name."
  (and (stringp filename)
       (file-name-absolute-p filename)
       (not (file-remote-p filename))))

(defun gm/session-save-buffer-p (filename _buffer-name _mode &rest _)
  "Allow Desktop to save only buffers visiting a local FILENAME."
  (gm/session--local-file-p filename))

(defun gm/session-track-focused-file ()
  "Remember the local file displayed in the selected editor window."
  (let ((window (selected-window)))
    (when (and (not gm/session-restoring-p)
               (window-live-p window)
               (not (window-minibuffer-p window))
               (not (window-parameter window 'window-side))
               (eq (current-buffer) (window-buffer window))
               (gm/session--local-file-p buffer-file-name))
      (setq gm/session-last-file (expand-file-name buffer-file-name)))))

(defun gm/session--editor-window ()
  "Return a live non-side editor window in the selected frame."
  (or (and (not (window-minibuffer-p (selected-window)))
           (not (window-parameter (selected-window) 'window-side))
           (selected-window))
      (seq-find (lambda (window)
                  (and (not (window-minibuffer-p window))
                       (not (window-parameter window 'window-side))))
                (window-list))))

(defun gm/session-focus-last-file ()
  "Focus `gm/session-last-file' when it still exists locally."
  (when (and (gm/session--local-file-p gm/session-last-file)
             (file-readable-p gm/session-last-file))
    (let ((buffer (find-file-noselect gm/session-last-file))
          (window (gm/session--editor-window)))
      (when (and (buffer-live-p buffer) (window-live-p window))
        (select-window window)
        (switch-to-buffer buffer)))))

(defun gm/session--finish-restore ()
  "Finish session restoration and notify dependent modules."
  (setq gm/session-restored-p t)
  (run-hooks 'gm/session-after-restore-hook)
  (gm/session-focus-last-file)
  (setq gm/session-restoring-p nil))

(defun gm/session--ignore-restored-minor-mode (_buffer-locals)
  "Ignore a process-backed minor mode found in an older desktop file."
  nil)

(defun gm/session--exclude-process-minor-modes ()
  "Prevent Desktop from saving or restoring process-backed minor modes."
  (dolist (mode gm/session-process-minor-modes)
    (setf (alist-get mode desktop-minor-mode-table)
          nil
          (alist-get mode desktop-minor-mode-handlers)
          #'gm/session--ignore-restored-minor-mode)))

(defun gm/session--window-state-node-type (value)
  "Return VALUE's window-state node type, or nil.
Top-level states carry constraints before their type; nested nodes do not."
  (cond
   ((and (consp value) (memq (car value) '(leaf hc vc))) (car value))
   ((and (consp value) (consp (cdr value))
         (memq (cadr value) '(leaf hc vc)))
    (cadr value))))

(defun gm/session--window-state-node-p (value)
  "Return non-nil when VALUE is a window-state tree node."
  (gm/session--window-state-node-type value))

(defun gm/session--window-state-node-body (state)
  "Return STATE elements following its node type."
  (if (memq (car state) '(leaf hc vc)) (cdr state) (cddr state)))

(defun gm/session--restorable-window-buffer-p (name)
  "Return non-nil when window buffer NAME is safe session state."
  (or (equal name "*scratch*")
      (when-let ((buffer (and (stringp name) (get-buffer name))))
        (with-current-buffer buffer
          (gm/session--local-file-p buffer-file-name)))))

(defun gm/session--side-window-state-p (state)
  "Return non-nil when leaf window STATE represents a side window."
  (when-let ((parameters (assq 'parameters
                               (gm/session--window-state-node-body state))))
    (assq 'window-side (cdr parameters))))

(defconst gm/session--window-geometry-properties
  '(pixel-width pixel-height total-width total-height normal-width normal-height)
  "Window-state properties that describe a node's allocation.")

(defun gm/session--window-state-top-level-p (state)
  "Return non-nil when STATE includes top-level window constraints."
  (and (consp state)
       (not (memq (car state) '(leaf hc vc)))
       (memq (cadr state) '(leaf hc vc))))

(defun gm/session--window-state-node-metadata (state)
  "Return a copy of STATE metadata, excluding child window nodes."
  (copy-tree
   (seq-remove #'gm/session--window-state-node-p
               (gm/session--window-state-node-body state))))

(defun gm/session--window-state-node-children (state)
  "Return STATE's child window nodes in display order."
  (seq-filter #'gm/session--window-state-node-p
              (gm/session--window-state-node-body state)))

(defun gm/session--window-state-build-node (template type metadata children)
  "Build a TYPE node like TEMPLATE from METADATA and CHILDREN."
  (append (if (gm/session--window-state-top-level-p template)
              (list (copy-tree (car template)) type)
            (list type))
          metadata
          children))

(defun gm/session--window-state-metadata-set (metadata property value)
  "Return METADATA with PROPERTY set to VALUE."
  (let ((copy (copy-tree metadata)))
    (if-let ((cell (assq property copy)))
        (setcdr cell value)
      (setq copy (append copy (list (cons property value)))))
    copy))

(defun gm/session--window-state-property (state property)
  "Return PROPERTY from STATE's node metadata."
  (cdr (assq property (gm/session--window-state-node-body state))))

(defun gm/session--window-state-allocation (state)
  "Return STATE's geometry allocation as an alist."
  (mapcar (lambda (property)
            (cons property (gm/session--window-state-property state property)))
          gm/session--window-geometry-properties))

(defun gm/session--window-state-set-allocation (state allocation)
  "Return a copy of STATE using ALLOCATION geometry."
  (let ((metadata (gm/session--window-state-node-metadata state)))
    (dolist (entry allocation)
      (when (numberp (cdr entry))
        (setq metadata
              (gm/session--window-state-metadata-set
               metadata (car entry) (cdr entry)))))
    (gm/session--window-state-build-node
     state
     (gm/session--window-state-node-type state)
     metadata
     (copy-tree (gm/session--window-state-node-children state)))))

(defun gm/session--window-state-set-last (state last-p)
  "Return a copy of STATE whose sibling terminator reflects LAST-P."
  (let ((metadata
         (seq-remove (lambda (entry) (eq (car-safe entry) 'last))
                     (gm/session--window-state-node-metadata state))))
    (when last-p
      (setq metadata (cons '(last . t) metadata)))
    (gm/session--window-state-build-node
     state
     (gm/session--window-state-node-type state)
     metadata
     (copy-tree (gm/session--window-state-node-children state)))))

(defun gm/session--window-state-normalized-shares (children property)
  "Return CHILDREN's positive PROPERTY weights normalized to one."
  (let* ((weights
          (mapcar (lambda (child)
                    (let ((weight (gm/session--window-state-property
                                   child property)))
                      (if (and (numberp weight) (> weight 0))
                          (float weight)
                        1.0)))
                  children))
         (total (apply #'+ weights)))
    (mapcar (lambda (weight) (/ weight total)) weights)))

(defun gm/session--window-state-integer-shares (total shares)
  "Distribute integer TOTAL according to SHARES.
The final share absorbs rounding differences."
  (if (not (numberp total))
      (make-list (length shares) nil)
    (let ((remaining total)
          result)
      (cl-loop for share in shares
               for index from 0
               for final = (= index (1- (length shares)))
               for size = (if final
                              remaining
                            (max 0 (min remaining (round (* total share)))))
               do (push size result)
               do (setq remaining (- remaining size)))
      (nreverse result))))

(defun gm/session--window-state-child-allocations (state children)
  "Return rebased geometry allocations for STATE's surviving CHILDREN."
  (let* ((horizontal (eq (gm/session--window-state-node-type state) 'hc))
         (normal-property (if horizontal 'normal-width 'normal-height))
         (shares (gm/session--window-state-normalized-shares
                  children normal-property))
         (pixel-total (gm/session--window-state-property
                       state (if horizontal 'pixel-width 'pixel-height)))
         (character-total (gm/session--window-state-property
                           state (if horizontal 'total-width 'total-height)))
         (pixel-shares (gm/session--window-state-integer-shares
                        pixel-total shares))
         (character-shares (gm/session--window-state-integer-shares
                            character-total shares)))
    (cl-loop for share in shares
             for pixel-size in pixel-shares
             for character-size in character-shares
             collect
             `((normal-width . ,(if horizontal share 1.0))
               (normal-height . ,(if horizontal 1.0 share))
               (pixel-width . ,(if horizontal
                                   pixel-size
                                 (gm/session--window-state-property
                                  state 'pixel-width)))
               (pixel-height . ,(if horizontal
                                    (gm/session--window-state-property
                                     state 'pixel-height)
                                  pixel-size))
               (total-width . ,(if horizontal
                                   character-size
                                 (gm/session--window-state-property
                                  state 'total-width)))
               (total-height . ,(if horizontal
                                    (gm/session--window-state-property
                                     state 'total-height)
                                  character-size))))))

(defun gm/session--window-state-resize-node (state allocation)
  "Resize STATE and its descendants to fit ALLOCATION."
  (let* ((resized (gm/session--window-state-set-allocation state allocation))
         (type (gm/session--window-state-node-type resized))
         (children (gm/session--window-state-node-children resized)))
    (if (not (memq type '(hc vc)))
        resized
      (let* ((allocations
              (gm/session--window-state-child-allocations resized children))
             (last-index (1- (length children)))
             (resized-children
              (cl-loop for child in children
                       for child-allocation in allocations
                       for index from 0
                       collect
                       (gm/session--window-state-set-last
                        (gm/session--window-state-resize-node
                         child child-allocation)
                        (= index last-index)))))
        (gm/session--window-state-build-node
         resized type
         (gm/session--window-state-node-metadata resized)
         resized-children)))))

(defun gm/session--sanitize-window-history (metadata)
  "Remove unsafe buffer history entries from leaf METADATA."
  (delq
   nil
   (mapcar
    (lambda (entry)
      (pcase (car-safe entry)
        ('next-buffers
         (when-let ((buffers
                     (seq-filter #'gm/session--restorable-window-buffer-p
                                 (cdr entry))))
           (cons 'next-buffers buffers)))
        ('prev-buffers
         (when-let ((buffers
                     (seq-filter
                      (lambda (buffer-state)
                        (gm/session--restorable-window-buffer-p
                         (car-safe buffer-state)))
                      (cdr entry))))
           (cons 'prev-buffers (copy-tree buffers))))
        (_ (copy-tree entry))))
    metadata)))

(defun gm/session--sanitize-window-state-node (state)
  "Return a surgically sanitized copy of window node STATE, or nil."
  (pcase (gm/session--window-state-node-type state)
    ('leaf
     (let* ((metadata (gm/session--window-state-node-metadata state))
            (name (cadr (assq 'buffer metadata))))
       (when (and (not (gm/session--side-window-state-p state))
                  (gm/session--restorable-window-buffer-p name))
         (gm/session--window-state-build-node
          state 'leaf (gm/session--sanitize-window-history metadata) nil))))
    ((and type (or 'hc 'vc))
     (let* ((metadata (gm/session--window-state-node-metadata state))
            (children
             (delq nil
                   (mapcar #'gm/session--sanitize-window-state-node
                           (gm/session--window-state-node-children state)))))
       (pcase (length children)
         (0 nil)
         (1
          (let* ((parent-last (cdr (assq 'last metadata)))
                 (promoted
                  (gm/session--window-state-resize-node
                   (car children)
                   (gm/session--window-state-allocation state))))
            (setq promoted
                  (gm/session--window-state-set-last promoted parent-last))
            (if (gm/session--window-state-top-level-p state)
                (cons (copy-tree (car state)) promoted)
              promoted)))
         (_
          (gm/session--window-state-resize-node
           (gm/session--window-state-build-node state type metadata children)
           (gm/session--window-state-allocation state))))))))

(defun gm/session--window-state-leaves (state)
  "Return every leaf in STATE in display order."
  (if (eq (gm/session--window-state-node-type state) 'leaf)
      (list state)
    (mapcan #'gm/session--window-state-leaves
            (gm/session--window-state-node-children state))))

(defun gm/session--window-state-leaf-selected-p (leaf)
  "Return non-nil when LEAF carries the selected-window marker."
  (when-let ((buffer-entry
              (assq 'buffer (gm/session--window-state-node-body leaf))))
    (cdr (assq 'selected (cddr buffer-entry)))))

(defun gm/session--window-state-set-leaf-selected (leaf selected-p)
  "Set LEAF's selected-window marker according to SELECTED-P."
  (when-let ((buffer-entry
              (assq 'buffer (gm/session--window-state-node-body leaf))))
    (if-let ((selected (assq 'selected (cddr buffer-entry))))
        (setcdr selected selected-p)
      (setcdr (cdr buffer-entry)
              (cons (cons 'selected selected-p) (cddr buffer-entry)))))
  leaf)

(defun gm/session--repair-window-state-selection (state)
  "Ensure exactly one surviving leaf in STATE is marked selected."
  (let* ((leaves (gm/session--window-state-leaves state))
         (selected (or (seq-find #'gm/session--window-state-leaf-selected-p leaves)
                       (car leaves))))
    (dolist (leaf leaves)
      (gm/session--window-state-set-leaf-selected leaf (eq leaf selected)))
    state))

(defun gm/session--safe-window-state-node-p (state)
  "Return non-nil when STATE contains only local files and no side windows."
  (pcase (gm/session--window-state-node-type state)
    ('leaf
     (let ((name (cadr (assq 'buffer
                             (gm/session--window-state-node-body state)))))
       (and (not (gm/session--side-window-state-p state))
            (gm/session--restorable-window-buffer-p name))))
    ((or 'hc 'vc)
     (let ((children
            (seq-filter #'gm/session--window-state-node-p
                        (gm/session--window-state-node-body state))))
       (and children
            (seq-every-p #'gm/session--safe-window-state-node-p children))))))

(defun gm/session--fallback-window-state ()
  "Return a portable one-window `*scratch*' state."
  (save-window-excursion
    (delete-other-windows)
    (switch-to-buffer (get-buffer-create "*scratch*"))
    (window-state-get (frame-root-window) 'writable)))

(defun gm/session-sanitize-window-state (state)
  "Return a restorable local-file-only version of window STATE.
Unsafe leaves are removed without collapsing surviving editor splits."
  (let ((sanitized
         (and (gm/session--window-state-node-p state)
              (gm/session--sanitize-window-state-node state))))
    (if sanitized
        (gm/session--repair-window-state-selection sanitized)
      (gm/session--fallback-window-state))))

(defun gm/session--filter-tabs (current filtered parameters saving)
  "Filter tab CURRENT like Desktop, then sanitize saved window states.
FILTERED, PARAMETERS, and SAVING are passed to `frameset-filter-tabs'."
  (let* ((parameter (frameset-filter-tabs current filtered parameters saving))
         (tabs (cdr parameter)))
    (cons
     (car parameter)
     (mapcar
      (lambda (tab)
        (let ((copy (copy-tree tab)))
          (when-let ((state (alist-get 'ws copy)))
            (setf (alist-get 'ws copy) (gm/session-sanitize-window-state state)))
          copy))
      tabs))))

(defun gm/session--prune-live-generated-windows ()
  "Remove generated and side windows from the temporarily saved layout."
  (dolist (window (window-list nil 'nomini))
    (when (and (window-live-p window)
               (window-parameter window 'window-side))
      (ignore-errors (delete-window window))))
  (dolist (window (window-list nil 'nomini))
    (let ((buffer (window-buffer window)))
      (unless (with-current-buffer buffer
                (or (equal (buffer-name) "*scratch*")
                    (gm/session--local-file-p buffer-file-name)))
        (if (> (length (window-list nil 'nomini)) 1)
            (ignore-errors (delete-window window))
          (set-window-buffer window (get-buffer-create "*scratch*")))))))

(defun gm/session--save-safe-frameset (function &rest arguments)
  "Call Desktop frameset save FUNCTION without generated windows."
  (save-window-excursion
    (gm/session--prune-live-generated-windows)
    (apply function arguments)))

(defun gm/session--restore-safe-frameset (function &rest arguments)
  "Sanitize legacy Desktop frame state before calling restore FUNCTION."
  (when desktop-saved-frameset
    (dolist (frame-state (frameset-states desktop-saved-frameset))
      (setcdr frame-state
              (gm/session-sanitize-window-state (cdr frame-state)))))
  (apply function arguments))

(defun gm/session--install-frameset-safety ()
  "Install file-only filters around Desktop frame and tab state."
  (setf (alist-get 'tabs frameset-filter-alist) #'gm/session--filter-tabs)
  (unless (advice-member-p #'gm/session--save-safe-frameset
                           #'desktop-save-frameset)
    (advice-add 'desktop-save-frameset :around #'gm/session--save-safe-frameset))
  (unless (advice-member-p #'gm/session--restore-safe-frameset
                           #'desktop-restore-frameset)
    (advice-add 'desktop-restore-frameset :around
                #'gm/session--restore-safe-frameset)))

(defun gm/session--initialize-new-desktop ()
  "Create and lock the first desktop before initializing a new session."
  (condition-case error-data
      (desktop-save gm/session-directory nil nil desktop-native-file-version)
    (file-error
     (desktop-save-mode -1)
     (display-warning
      'gm-session
      (format "Cannot create the desktop session: %s"
              (error-message-string error-data))
      :error)))
  (gm/session--finish-restore))

(defun gm/session--decline-locked-desktop ()
  "Keep a secondary Emacs instance from overwriting the primary desktop."
  (desktop-save-mode -1)
  (message "Desktop belongs to a running Emacs; session loading and saving are disabled")
  (gm/session--finish-restore))

;;;###autoload
(defun gm/session-save-now ()
  "Save the current desktop session immediately."
  (interactive)
  (unless desktop-save-mode
    (user-error "Desktop session saving is disabled in this Emacs instance"))
  (make-directory gm/session-directory t)
  (desktop-save gm/session-directory nil nil desktop-native-file-version)
  (message "Session saved to %s" gm/session-directory))

(defun gm/session-initialize ()
  "Configure safe persistent desktop restoration for interactive Emacs."
  (make-directory gm/session-directory t)
  (setq gm/session-restoring-p (not noninteractive)
        gm/session-restored-p nil)
  (setq desktop-path (list gm/session-directory)
        desktop-dirname gm/session-directory
        desktop-base-file-name "gm-desktop.el"
        desktop-base-lock-name "gm-desktop.lock"
        desktop-save t
        desktop-auto-save-timeout 60
        desktop-load-locked-desktop 'check-pid
        desktop-missing-file-warning nil
        desktop-restore-eager t
        desktop-restore-frames t
        desktop-restore-in-current-display t
        desktop-restore-forces-onscreen 'all
        desktop-restore-reuses-frames t
        desktop-buffers-not-to-save-function #'gm/session-save-buffer-p)
  (gm/session--exclude-process-minor-modes)
  (gm/session--install-frameset-safety)
  (add-to-list 'desktop-globals-to-save 'gm/session-last-file)
  (add-hook 'buffer-list-update-hook #'gm/session-track-focused-file)
  (add-hook 'desktop-after-read-hook #'gm/session--finish-restore)
  (add-hook 'desktop-no-desktop-file-hook #'gm/session--initialize-new-desktop)
  (add-hook 'desktop-not-loaded-hook #'gm/session--decline-locked-desktop)
  (unless noninteractive
    (desktop-save-mode 1)
    (when (member "--no-desktop" command-line-args)
      (gm/session--finish-restore))))

(provide 'gm-session)
;;; gm-session.el ends here
