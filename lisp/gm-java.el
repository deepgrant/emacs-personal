;;; gm-java.el --- Multi-JDK discovery and selection -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'gm-core)

(defcustom gm/java-home-candidates
  '((17 . ("/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"))
    (18 . ("~/.local/share/jdks/jdk-18.0.2.jdk/Contents/Home"
           "~/.local/share/jdks/openjdk-18.0.2/Contents/Home"
           "/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home"))
    (21 . ("/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home")))
  "Candidate Java homes keyed by major version."
  :type '(alist :key-type integer :value-type (repeat directory))
  :group 'gm)

(defvar gm/java-project-versions (make-hash-table :test #'equal)
  "Session-local Java version overrides keyed by project root.")

(defun gm/metals-server-command ()
  "Return the managed Metals wrapper as a single executable path."
  (expand-file-name "bin/metals-java17"
                    (or (bound-and-true-p gm/config-root) user-emacs-directory)))

(defun gm/java--home-matches-p (home version)
  "Return non-nil when HOME contains an executable Java VERSION."
  (let ((java (expand-file-name "bin/java" home)))
    (and (file-executable-p java)
         (with-temp-buffer
           (eq 0 (call-process java nil (list t t) nil
                               "-XshowSettings:properties" "-version"))
           (goto-char (point-min))
           (re-search-forward
            (format "\\(?:java\\|openjdk\\) version \"%s\\(?:[.\"]\\)" version)
            nil t)))))

(defun gm/java-home (version)
  "Return an existing Java home for major VERSION, or nil."
  (seq-find (lambda (home) (gm/java--home-matches-p home version))
            (mapcar #'expand-file-name (alist-get version gm/java-home-candidates))))

(defun gm/java-version-output (version)
  "Return the first version line for VERSION, or a missing marker."
  (if-let ((home (gm/java-home version)))
      (string-trim
       (with-temp-buffer
         (let ((status (call-process (expand-file-name "bin/java" home)
                                     nil (list t t) nil "-version")))
           (if (zerop status)
               (buffer-substring-no-properties (point-min) (line-end-position))
             (format "failed (exit %s)" status)))))
    "missing"))

(defun gm/java--set-environment (version &optional local)
  "Set Java VERSION in the current environment.
When LOCAL is non-nil, make the environment buffer-local."
  (let ((home (or (gm/java-home version)
                  (user-error "OpenJDK %s is not installed" version))))
    (when local
      (setq-local process-environment (copy-sequence process-environment))
      (setq-local exec-path (copy-sequence exec-path)))
    (setenv "JAVA_HOME" home)
    (setq exec-path (cons (expand-file-name "bin" home)
                          (delete (expand-file-name "bin" home) exec-path)))
    home))

(defun gm/java-project-version ()
  "Return the selected Java version for the current project."
  (or (gethash (file-truename (gm/project-root)) gm/java-project-versions) 21))

(defun gm/java-apply-project-version ()
  "Apply this project's Java selection to the current buffer."
  (when (derived-mode-p 'java-mode 'java-ts-mode 'groovy-mode)
    (gm/java--set-environment (gm/java-project-version) t)))

(defun gm/java-use-version (version)
  "Use Java VERSION for the current project and restart its LSP workspace."
  (interactive
   (list (string-to-number
          (completing-read "Java version: " '("17" "18" "21") nil t nil nil "21"))))
  (unless (memq version '(17 18 21))
    (user-error "Supported Java versions are 17, 18, and 21"))
  (gm/java--set-environment version t)
  (puthash (file-truename (gm/project-root)) version gm/java-project-versions)
  (when (and (bound-and-true-p lsp-mode) (fboundp 'lsp-workspace-restart))
    (lsp-workspace-restart))
  (message "Project %s now uses Java %s" (gm/project-root) version))

(defun gm/java-status ()
  "Display configured Java homes and their intended roles."
  (interactive)
  (with-help-window "*gm-java-status*"
    (princ "GNU Emacs Java runtime matrix\n\n")
    (dolist (entry '((17 . "Metals and Java 17 projects")
                     (18 . "Legacy Java 18 projects only")
                     (21 . "Default Emacs/JDT LS/Groovy runtime")))
      (let* ((version (car entry))
             (home (gm/java-home version)))
        (princ (format "Java %s\n  role: %s\n  home: %s\n  runtime: %s\n\n"
                       version (cdr entry) (or home "MISSING")
                       (gm/java-version-output version)))))
    (princ (format "Current project: %s\nSelected version: %s\nGlobal JAVA_HOME: %s\n"
                   (gm/project-root) (gm/java-project-version)
                   (or (getenv "JAVA_HOME") "unset")))))

(defun gm/java-lsp-runtimes ()
  "Build `lsp-java-configuration-runtimes' for installed JDKs."
  (delq nil
        (mapcar (lambda (version)
                  (when-let ((home (gm/java-home version)))
                    `(:name ,(format "JavaSE-%s" version)
                      :path ,home
                      ,@(when (= version 21) '(:default t)))))
                '(17 18 21))))

(defun gm/java-initialize ()
  "Select Java 21 globally and install project hooks."
  (when (gm/java-home 21)
    (gm/java--set-environment 21))
  (add-hook 'java-mode-hook #'gm/java-apply-project-version)
  (add-hook 'java-ts-mode-hook #'gm/java-apply-project-version)
  (add-hook 'groovy-mode-hook #'gm/java-apply-project-version))

(provide 'gm-java)
;;; gm-java.el ends here
