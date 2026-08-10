;;; session-smoke.el --- Cross-process desktop restoration smoke test -*- lexical-binding: t; -*-

(setq gm/config-root
      (file-name-directory (directory-file-name
                            (file-name-directory (or load-file-name buffer-file-name)))))
(setq load-prefer-newer t)
(add-to-list 'load-path (expand-file-name "lisp" gm/config-root))
(setenv "GM_EMACS_SKIP_PACKAGES" "1")

(require 'gm-core)
(require 'gm-session)
(require 'gm-project)

(defun gm-session-smoke--fail (format-string &rest arguments)
  "Fail the smoke test with FORMAT-STRING and ARGUMENTS."
  (error "Session smoke: %s" (apply #'format format-string arguments)))

(defun gm-session-smoke--assert (condition format-string &rest arguments)
  "Require CONDITION, reporting FORMAT-STRING and ARGUMENTS on failure."
  (unless condition
    (apply #'gm-session-smoke--fail format-string arguments)))

(defun gm-session-smoke--write-file (file contents)
  "Create FILE containing CONTENTS."
  (make-directory (file-name-directory file) t)
  (with-temp-file file (insert contents)))

(defun gm-session-smoke--git-init (directory)
  "Create a quiet Git repository in DIRECTORY and return its canonical root."
  (make-directory directory t)
  (unless (zerop (process-file "git" nil nil nil "init" "--quiet" directory))
    (gm-session-smoke--fail "git init failed for %s" directory))
  (file-name-as-directory (file-truename directory)))

(defun gm-session-smoke--configure (desktop-directory)
  "Configure workspaces and Desktop for DESKTOP-DIRECTORY."
  (setq gm/session-directory desktop-directory)
  (gm/project-initialize)
  (gm/session-initialize))

(defun gm-session-smoke--save (root)
  "Create and persist the smoke-test desktop under ROOT."
  (let* ((desktop-directory (file-name-as-directory (expand-file-name "desktop" root)))
         (repo-a (gm-session-smoke--git-init (expand-file-name "one/repository" root)))
         (repo-b (gm-session-smoke--git-init (expand-file-name "two/repository" root)))
         (loose-file (expand-file-name "loose.txt" root))
         (repo-a-file (expand-file-name "alpha.txt" repo-a))
         (repo-a-peer (expand-file-name "delta.txt" repo-a))
         (repo-b-file (expand-file-name "bravo.txt" repo-b))
         (repo-b-peer (expand-file-name "charlie.txt" repo-b)))
    (gm-session-smoke--write-file loose-file "loose global file\n")
    (gm-session-smoke--write-file repo-a-file "alpha workspace file\n")
    (gm-session-smoke--write-file repo-a-peer "delta background split file\n")
    (gm-session-smoke--write-file repo-b-file "bravo workspace file\n")
    (gm-session-smoke--write-file repo-b-peer "charlie split file\n")
    (set-frame-parameter nil 'tabs nil)
    (gm-session-smoke--configure desktop-directory)
    (find-file loose-file)
    (goto-char 7)
    (gm/workspace-open repo-a)
    (find-file repo-a-file)
    (goto-char 8)
    ;; Build the GUI-shaped failure case before leaving this tab.  The side
    ;; window and the editor split are serialized only in this background tab's
    ;; `ws', so live-frame pruning cannot hide a tab sanitizer regression.
    (display-buffer-in-side-window
     (get-buffer-create " *gm-session-background-panel*")
     '((side . left) (slot . 0) (window-width . 0.15)))
    (let ((peer-window (split-window-right 25)))
      (set-window-buffer peer-window (find-file-noselect repo-a-peer))
      (select-window peer-window)
      (goto-char 11))
    (gm/workspace-open repo-b)
    (find-file repo-b-file)
    (goto-char 9)
    (let ((peer-window (split-window-right)))
      (set-window-buffer peer-window (find-file-noselect repo-b-peer))
      (select-window peer-window)
      (goto-char 10))
    (display-buffer-in-side-window
     (get-buffer-create " *gm-session-live-panel*")
     '((side . left) (slot . 0) (window-width . 0.15)))
    (setq gm/session-last-file repo-b-peer)
    (gm-session-smoke--assert (= (length (gm/workspace--registered-roots)) 2)
                              "expected two registered repositories before save")
    (gm-session-smoke--assert
     (= (length (seq-remove
                 (lambda (window) (window-parameter window 'window-side))
                 (window-list)))
        2)
     "expected two editor windows before save")
    (make-directory desktop-directory t)
    (desktop-save desktop-directory nil nil desktop-native-file-version)
    ;; Leave a dead owner's lock behind to exercise PID-aware stale lock recovery.
    (with-temp-file (desktop-full-lock-name desktop-directory)
      (prin1 99999999 (current-buffer)))))

(defun gm-session-smoke--restore (root)
  "Restore and validate the smoke-test desktop under ROOT."
  (let* ((desktop-directory (file-name-as-directory (expand-file-name "desktop" root)))
         (repo-a (file-name-as-directory
                  (file-truename (expand-file-name "one/repository" root))))
         (repo-b (file-name-as-directory
                  (file-truename (expand-file-name "two/repository" root))))
         (loose-file (expand-file-name "loose.txt" root))
         (repo-a-file (expand-file-name "alpha.txt" repo-a))
         (repo-a-peer (expand-file-name "delta.txt" repo-a))
         (repo-b-file (expand-file-name "bravo.txt" repo-b))
         (repo-b-peer (expand-file-name "charlie.txt" repo-b)))
    (set-frame-parameter nil 'tabs nil)
    (gm-session-smoke--configure desktop-directory)
    ;; `desktop-read' is intentionally a no-op in batch mode; dynamically use its
    ;; normal restoration path while retaining a headless, deterministic test.
    (setq gm/session-restoring-p t)
    (let ((noninteractive nil))
      (gm-session-smoke--assert (desktop-read desktop-directory)
                                "desktop-read did not load the saved desktop"))
    (gm-session-smoke--assert gm/session-restored-p
                              "the restore completion hook did not run")
    (gm-session-smoke--assert (= (length (gm/workspace--registered-roots)) 2)
                              "expected two restored repository tabs")
    (gm-session-smoke--assert
     (equal (sort (copy-sequence (gm/workspace--registered-roots)) #'string<)
            (sort (list repo-a repo-b) #'string<))
     "restored repository metadata differs from the saved roots")
    (gm-session-smoke--assert (equal (gm/workspace-current-root) repo-b)
                              "the selected workspace was not restored")
    (dolist (file (list loose-file repo-a-file repo-a-peer
                        repo-b-file repo-b-peer))
      (gm-session-smoke--assert (get-file-buffer file)
                                "file buffer was not restored: %s" file))
    (gm-session-smoke--assert (equal buffer-file-name repo-b-peer)
                              "last-focused file was not selected")
    (gm-session-smoke--assert (= (point) 10)
                              "last-focused cursor position was not restored")
    (gm-session-smoke--assert (= (length (window-list)) 2)
                              "the selected workspace split was not restored")
    (gm-session-smoke--assert
     (not (seq-some (lambda (window) (window-parameter window 'window-side))
                    (window-list)))
     "the selected workspace restored a generated side window")
    ;; The first repository was a background tab at save time.  Its split must
    ;; survive surgical removal of the serialized side window.
    (gm/workspace--select-tab (gm/workspace--repository-tab-index repo-a))
    (let* ((alpha-buffer (get-file-buffer repo-a-file))
           (delta-buffer (get-file-buffer repo-a-peer))
           (alpha-window (get-buffer-window alpha-buffer))
           (delta-window (get-buffer-window delta-buffer))
           (editor-windows
            (seq-remove (lambda (window) (window-parameter window 'window-side))
                        (window-list)))
           (alpha-ratio
            (/ (float (window-total-width alpha-window))
               (apply #'+ (mapcar #'window-total-width editor-windows)))))
      (gm-session-smoke--assert (= (length editor-windows) 2)
                                "the background workspace split was lost")
      (gm-session-smoke--assert (and alpha-window delta-window)
                                "background workspace files are not both displayed")
      (gm-session-smoke--assert
       (< (window-pixel-left alpha-window) (window-pixel-left delta-window))
       "background workspace split orientation changed")
      (gm-session-smoke--assert
       (< (abs (- alpha-ratio (/ 25.0 68.0))) 0.08)
       "background workspace split ratio changed: %.3f" alpha-ratio)
      (gm-session-smoke--assert (= (window-point alpha-window) 8)
                                "alpha cursor position was not restored")
      (gm-session-smoke--assert (= (window-point delta-window) 11)
                                "delta cursor position was not restored")
      (gm-session-smoke--assert
       (not (seq-some (lambda (window) (window-parameter window 'window-side))
                      (window-list)))
       "background workspace restored its generated side window"))))

(let ((root (getenv "GM_SESSION_SMOKE_ROOT"))
      (phase (getenv "GM_SESSION_SMOKE_PHASE")))
  (unless (and root phase)
    (gm-session-smoke--fail "GM_SESSION_SMOKE_ROOT and GM_SESSION_SMOKE_PHASE are required"))
  (pcase phase
    ("save" (gm-session-smoke--save root))
    ("restore" (gm-session-smoke--restore root))
    (_ (gm-session-smoke--fail "unknown phase %s" phase))))

;;; session-smoke.el ends here
