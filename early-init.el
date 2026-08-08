;;; early-init.el --- Early startup for gm Emacs -*- lexical-binding: t; -*-

(setq package-enable-at-startup nil
      frame-inhibit-implied-resize t
      inhibit-startup-screen t
      load-prefer-newer t
      native-comp-async-report-warnings-errors 'silent)

(when (fboundp 'tool-bar-mode) (tool-bar-mode -1))
(when (fboundp 'scroll-bar-mode) (scroll-bar-mode -1))
(when (fboundp 'menu-bar-mode) (menu-bar-mode -1))

(setq default-frame-alist
      '((font . "Menlo-12")
        (background-color . "#181818")
        (foreground-color . "#F0F0F0")
        (internal-border-width . 1)))

;;; early-init.el ends here
