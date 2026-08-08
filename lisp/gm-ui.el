;;; gm-ui.el --- Cursor-like visual presentation and window rules -*- lexical-binding: t; -*-

(require 'gm-core)
(require 'tab-line)

(defun gm/ui-apply-font (&optional frame)
  "Apply the configured font to FRAME when it is available."
  (when (display-graphic-p (or frame (selected-frame)))
    (with-selected-frame (or frame (selected-frame))
      (cond
       ((find-font (font-spec :family "Menlo"))
        (set-face-attribute 'default nil :family "Menlo" :height 120))
       ((find-font (font-spec :family "Monaco"))
        (set-face-attribute 'default nil :family "Monaco" :height 120))))))

(defun gm/ui-tab-name (buffer &optional _buffers)
  "Return a compact tab label for BUFFER."
  (with-current-buffer buffer
    (format " %s%s "
            (buffer-name)
            (if (buffer-modified-p) " ●" ""))))

(defun gm/ui-initialize ()
  "Activate the theme, tabs, and stable IDE panel placement."
  (load-theme 'gm-cursor-dark t)
  (gm/ui-apply-font)
  (add-hook 'after-make-frame-functions #'gm/ui-apply-font)

  (setq frame-title-format '(:eval (format "%s — Emacs" (buffer-name)))
        tab-line-new-button-show nil
        tab-line-close-button-show nil
        tab-line-tab-name-function #'gm/ui-tab-name
        window-divider-default-right-width 1
        window-divider-default-bottom-width 1)
  (global-tab-line-mode 1)
  (global-hl-line-mode 1)
  (window-divider-mode 1)

  (dolist (mode '(vterm-mode compilation-mode flycheck-error-list-mode
                  help-mode messages-buffer-mode))
    (add-hook mode (lambda () (setq-local mode-line-format mode-line-format))))

  (add-to-list
   'display-buffer-alist
   '("\\*\\(?:vterm\\|compilation\\|Flycheck errors\\|sbt\\|Gradle\\).*\\*"
     (display-buffer-reuse-window display-buffer-in-side-window)
     (side . bottom) (slot . 0) (window-height . 0.28)
     (window-parameters . ((no-delete-other-windows . t)))))
  (add-to-list
   'display-buffer-alist
   '("\\*deadgrep.*\\*"
     (display-buffer-reuse-window display-buffer-in-side-window)
     (side . left) (slot . 1) (window-width . 0.28)
     (window-parameters . ((no-delete-other-windows . t)))))
  (add-to-list
   'display-buffer-alist
   '("\\*Codex:.*\\*"
     (display-buffer-reuse-window display-buffer-in-side-window)
     (side . right) (slot . 0) (window-width . 0.32)
     (window-parameters . ((no-delete-other-windows . t))))))

(provide 'gm-ui)
;;; gm-ui.el ends here
