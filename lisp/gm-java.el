;;; gm-java.el --- Multi-JDK registry and selection -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'gm-core)

(defconst gm/java-registry-file
  (or (getenv "GM_JAVA_REGISTRY_FILE")
      (expand-file-name "var/java-runtimes.properties"
                        (or (bound-and-true-p gm/config-root)
                            user-emacs-directory)))
  "Ignored machine-local Java runtime registry.")

(defconst gm/java-role-keys
  '("EMACS_JDK" "JDTLS_JDK" "METALS_JDK" "GROOVY_LS_JDK")
  "Logical Java roles accepted in the runtime registry.")

(defvar gm/java--registry-cache 'uninitialized
  "Parsed Java registry, nil after failure, or `uninitialized'.")

(defvar gm/java--registry-modtime nil
  "Modification time associated with `gm/java--registry-cache'.")

(defvar gm/java--registry-warning-issued-p nil
  "Non-nil after warning once about an unavailable Java registry.")

(defvar gm/java-project-versions (make-hash-table :test #'equal)
  "Session-local Java version overrides keyed by project root.")

(defun gm/metals-server-command ()
  "Return the managed Metals wrapper as a single executable path."
  (expand-file-name "bin/metals-java17"
                    (or (bound-and-true-p gm/config-root) user-emacs-directory)))

(defun gm/java--registry-key-p (key)
  "Return non-nil when KEY is supported by the Java registry."
  (or (equal key "REGISTRY_VERSION")
      (string-match-p "\\`JDK[0-9]+\\'" key)
      (member key gm/java-role-keys)))

(defun gm/java--parse-registry (file)
  "Parse and validate Java runtime registry FILE without evaluating it."
  (unless (file-readable-p file)
    (error "Java runtime registry is missing: %s; run bin/discover-java-runtimes"
           file))
  (let ((registry (make-hash-table :test #'equal))
        (line-number 0))
    (dolist (line (with-temp-buffer
                    (insert-file-contents-literally file)
                    (split-string (buffer-string) "\n")))
      (setq line-number (1+ line-number))
      (unless (or (string-empty-p line) (string-prefix-p "#" line))
        (unless (string-match "\\`\\([A-Z][A-Z0-9_]*\\)=\\(.*\\)\\'" line)
          (error "Invalid Java registry line %d: %s" line-number line))
        (let ((key (match-string 1 line))
              (value (match-string 2 line)))
          (unless (gm/java--registry-key-p key)
            (error "Unknown Java registry key on line %d: %s" line-number key))
          (unless (eq (gethash key registry 'gm/java--missing)
                      'gm/java--missing)
            (error "Duplicate Java registry key: %s" key))
          (puthash key value registry))))
    (unless (equal (gethash "REGISTRY_VERSION" registry) "1")
      (error "Unsupported or missing Java registry version in %s" file))
    (maphash
     (lambda (key value)
       (cond
        ((string-match-p "\\`JDK[0-9]+\\'" key)
         (unless (and (file-name-absolute-p value)
                      (file-executable-p (expand-file-name "bin/java" value)))
           (error "Java registry path is not an executable JDK home: %s=%s"
                  key value)))
        ((member key gm/java-role-keys)
         (unless (string-match-p "\\`JDK[0-9]+\\'" value)
           (error "Java role %s has invalid target: %s" key value)))))
     registry)
    (dolist (role gm/java-role-keys)
      (let ((target (gethash role registry)))
        (unless target
          (error "Java registry role is missing: %s" role))
        (unless (gethash target registry)
          (error "Java role %s references missing %s" role target))))
    registry))

(defun gm/java--registry-file-modtime ()
  "Return the current registry modification time, or nil."
  (when-let ((attributes (file-attributes gm/java-registry-file)))
    (file-attribute-modification-time attributes)))

(defun gm/java--registry ()
  "Return the current parsed Java registry, or nil after warning once."
  (let ((modtime (gm/java--registry-file-modtime)))
    (when (or (eq gm/java--registry-cache 'uninitialized)
              (not (equal modtime gm/java--registry-modtime)))
      (setq gm/java--registry-modtime modtime)
      (condition-case error-data
          (setq gm/java--registry-cache
                (gm/java--parse-registry gm/java-registry-file)
                gm/java--registry-warning-issued-p nil)
        (error
         (setq gm/java--registry-cache nil)
         (unless gm/java--registry-warning-issued-p
           (setq gm/java--registry-warning-issued-p t)
           (display-warning
            'gm-java
            (format "%s; Java language services remain disabled"
                    (error-message-string error-data))
            :warning)))))
    gm/java--registry-cache))

(defun gm/java--registry-value (key)
  "Return Java registry value for KEY, or nil."
  (when-let ((registry (gm/java--registry)))
    (gethash key registry)))

(defun gm/java-role-key (role)
  "Return the JDK key referenced by Java ROLE."
  (gm/java--registry-value
   (if (symbolp role) (symbol-name role) role)))

(defun gm/java-role-home (role)
  "Return the JDK home referenced by Java ROLE."
  (when-let ((jdk-key (gm/java-role-key role)))
    (gm/java--registry-value jdk-key)))

(defun gm/java-versions ()
  "Return discovered Java major versions in ascending order."
  (let (versions)
    (when-let ((registry (gm/java--registry)))
      (maphash
       (lambda (key _value)
         (when (string-match "\\`JDK\\([0-9]+\\)\\'" key)
           (push (string-to-number (match-string 1 key)) versions)))
       registry))
    (sort versions #'<)))

(defun gm/java-home (version)
  "Return the registered Java home for major VERSION, or nil.
This lookup never starts a JVM."
  (gm/java--registry-value (format "JDK%s" version)))

(defun gm/java--probe-home (home version)
  "Return live validation details for Java HOME and major VERSION."
  (let ((java (and home (expand-file-name "bin/java" home))))
    (cond
     ((not (and java (file-executable-p java)))
      (list :ok nil :status nil :detail "missing executable"))
     (t
      (condition-case error-data
          (with-temp-buffer
            (let* ((status (call-process java nil (list t t) nil
                                         "-XshowSettings:properties" "-version"))
                   (output (buffer-string))
                   (matches
                    (and (zerop status)
                         (string-match-p
                          (format
                           "\\(?:java\\.version[[:space:]]*=[[:space:]]*\\|\\(?:java\\|openjdk\\) version \\\"\\)%s\\(?:[.\\\"]\\)"
                           version)
                          output)))
                   (version-line
                    (or (seq-find
                         (lambda (line)
                           (string-match-p
                            "\\(?:java\\.version[[:space:]]*=\\|version \\\"\\)"
                            line))
                         (split-string output "\n" t "[[:space:]]+"))
                        "no version output")))
              (list :ok matches
                    :status status
                    :detail (cond
                             ((not (zerop status))
                              (format "failed (exit %s): %s"
                                      status (string-trim version-line)))
                             (matches (string-trim version-line))
                             (t (format "version mismatch: expected %s; %s"
                                        version (string-trim version-line)))))))
        (error
         (list :ok nil :status nil
               :detail (format "failed: %s"
                               (error-message-string error-data)))))))))

(defun gm/java--home-matches-p (home version)
  "Return non-nil when HOME successfully reports Java VERSION."
  (plist-get (gm/java--probe-home home version) :ok))

(defun gm/java-version-output (version)
  "Return live Java version details for VERSION, or a missing marker."
  (plist-get (gm/java--probe-home (gm/java-home version) version) :detail))

(defun gm/java--apply-environment-home (home &optional local)
  "Set Java HOME in the current environment.
When LOCAL is non-nil, make the environment buffer-local."
  (when local
    (setq-local process-environment (copy-sequence process-environment))
    (setq-local exec-path (copy-sequence exec-path)))
  (setenv "JAVA_HOME" home)
  (setq exec-path (cons (expand-file-name "bin" home)
                        (delete (expand-file-name "bin" home) exec-path)))
  home)

(defun gm/java--set-environment (version &optional local)
  "Set Java VERSION in the current environment.
When LOCAL is non-nil, make the environment buffer-local."
  (gm/java--apply-environment-home
   (or (gm/java-home version)
       (user-error "OpenJDK %s is not registered; run bin/discover-java-runtimes"
                   version))
   local))

(defun gm/java-default-version ()
  "Return the Java major selected by `EMACS_JDK', defaulting to 21."
  (if-let ((key (gm/java-role-key "EMACS_JDK")))
      (string-to-number (string-remove-prefix "JDK" key))
    21))

(defun gm/java-project-version ()
  "Return the selected Java version for the current project."
  (or (gethash (file-truename (gm/project-root)) gm/java-project-versions)
      (gm/java-default-version)))

(defun gm/java-apply-project-version ()
  "Apply this project's Java selection to the current buffer."
  (when (derived-mode-p 'java-mode 'java-ts-mode 'groovy-mode)
    (let ((version (gm/java-project-version)))
      (when (gm/java-home version)
        (gm/java--set-environment version t)))))

(defun gm/java-use-version (version)
  "Use Java VERSION for the current project and restart its LSP workspace."
  (interactive
   (let* ((versions (gm/java-versions))
          (default (number-to-string (gm/java-default-version))))
     (unless versions
       (user-error "No Java runtimes are registered; run bin/discover-java-runtimes"))
     (list (string-to-number
            (completing-read "Java version: "
                             (mapcar #'number-to-string versions)
                             nil t nil nil default)))))
  (unless (memq version (gm/java-versions))
    (user-error "Java %s is not registered" version))
  (gm/java--set-environment version t)
  (puthash (file-truename (gm/project-root)) version gm/java-project-versions)
  (when (and (bound-and-true-p lsp-mode) (fboundp 'lsp-workspace-restart))
    (lsp-workspace-restart))
  (message "Project %s now uses Java %s" (gm/project-root) version))

(defun gm/java-status ()
  "Display registered Java homes, live versions, and intended roles."
  (interactive)
  (with-help-window "*gm-java-status*"
    (princ (format "GNU Emacs Java runtime registry\n\nRegistry: %s\n\n"
                   gm/java-registry-file))
    (dolist (version (gm/java-versions))
      (let* ((key (format "JDK%s" version))
             (home (gm/java-home version))
             (probe (gm/java--probe-home home version))
             (roles (seq-filter
                     (lambda (role) (equal (gm/java-role-key role) key))
                     gm/java-role-keys)))
        (princ (format "Java %s\n  roles: %s\n  home: %s\n  runtime: %s%s\n\n"
                       version
                       (if roles (string-join roles ", ") "none")
                       home
                       (plist-get probe :detail)
                       (if (plist-get probe :ok) "" " (INVALID)")))))
    (princ (format "Current project: %s\nSelected version: %s\nGlobal JAVA_HOME: %s\n"
                   (gm/project-root) (gm/java-project-version)
                   (or (getenv "JAVA_HOME") "unset")))))

(defun gm/java-lsp-runtimes ()
  "Build `lsp-java-configuration-runtimes' from the runtime registry."
  (let ((default-key (gm/java-role-key "JDTLS_JDK")))
    (mapcar
     (lambda (version)
       (let ((key (format "JDK%s" version)))
         `(:name ,(format "JavaSE-%s" version)
           :path ,(gm/java-home version)
           ,@(when (equal key default-key) '(:default t)))))
     (gm/java-versions))))

(defun gm/java--export-runtime-aliases ()
  "Export every discovered JDK key for child processes such as Gradle."
  (dolist (version (gm/java-versions))
    (let ((key (format "JDK%s" version)))
      (setenv key (gm/java-home version)))))

(defun gm/java-initialize ()
  "Load the registry, select the Emacs Java role, and install hooks."
  (gm/java--export-runtime-aliases)
  (when-let ((home (gm/java-role-home "EMACS_JDK")))
    (gm/java--apply-environment-home home))
  (add-hook 'java-mode-hook #'gm/java-apply-project-version)
  (add-hook 'java-ts-mode-hook #'gm/java-apply-project-version)
  (add-hook 'groovy-mode-hook #'gm/java-apply-project-version))

(provide 'gm-java)
;;; gm-java.el ends here
