;;; gm-hocon-mode.el --- Lightweight HOCON editing mode -*- lexical-binding: t; -*-

(require 'prog-mode)
(require 'cl-lib)

(defvar gm-hocon-mode-syntax-table
  (let ((table (make-syntax-table)))
    (modify-syntax-entry ?# "< b" table)
    (modify-syntax-entry ?/ ". 124b" table)
    (modify-syntax-entry ?* ". 23" table)
    (modify-syntax-entry ?\n "> b" table)
    (modify-syntax-entry ?\" "\"" table)
    (modify-syntax-entry ?_ "w" table)
    (modify-syntax-entry ?- "w" table)
    table)
  "Syntax table for `gm-hocon-mode'.")

(defconst gm-hocon-font-lock-keywords
  `((,(regexp-opt '("include" "required" "file" "url" "classpath") 'symbols)
     . font-lock-keyword-face)
    (,(regexp-opt '("true" "false" "null") 'symbols) . font-lock-constant-face)
    ("${?[^}\n]+}?" . font-lock-variable-name-face)
    ("^[[:space:]]*\\([[:alnum:]_.-]+\\)[[:space:]]*[:=]?" 1 font-lock-property-name-face)
    ("\\_<[0-9]+\\(?:\\.[0-9]+\\)?\\(?:ms\\|s\\|m\\|h\\|d\\|k\\|M\\|G\\)?\\_>"
     . font-lock-number-face))
  "Font-lock rules for HOCON.")

(defun gm-hocon--depth-at-line ()
  "Return brace/bracket depth at the beginning of the current line."
  (save-excursion
    (beginning-of-line)
    (let ((limit (point)) (depth 0))
      (goto-char (point-min))
      (while (re-search-forward "[][{}]" limit t)
        (unless (nth 8 (save-excursion (syntax-ppss (match-beginning 0))))
          (setq depth (+ depth (if (member (match-string 0) '("{" "[")) 1 -1)))))
      (max 0 depth))))

(defun gm-hocon-indent-line ()
  "Indent the current HOCON line by structural nesting depth."
  (interactive)
  (let* ((offset (- (point) (line-beginning-position)))
         (closing (save-excursion
                    (back-to-indentation)
                    (looking-at-p "[]}]")))
         (depth (gm-hocon--depth-at-line))
         (indent (* 2 (max 0 (- depth (if closing 1 0))))))
    (indent-line-to indent)
    (when (> offset 0) (move-to-column (+ indent offset)))))

;;;###autoload
(define-derived-mode gm-hocon-mode prog-mode "HOCON"
  "Major mode for the Human-Optimized Config Object Notation."
  :syntax-table gm-hocon-mode-syntax-table
  (setq-local font-lock-defaults '(gm-hocon-font-lock-keywords))
  (setq-local indent-line-function #'gm-hocon-indent-line)
  (setq-local comment-start "# ")
  (setq-local comment-end "")
  (setq-local comment-start-skip "\\(?:#+\\|//+\\)\\s-*"))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.hocon\\'" . gm-hocon-mode))
;;;###autoload
(add-to-list 'auto-mode-alist '("/\\(?:application\\|reference\\)\\.conf\\'" . gm-hocon-mode))

(provide 'gm-hocon-mode)
;;; gm-hocon-mode.el ends here
