;;; init.el --- VSCodium-style GNU Emacs configuration -*- lexical-binding: t; -*-

(defconst gm/config-root
  (file-name-directory (or load-file-name buffer-file-name user-emacs-directory)))

(add-to-list 'load-path (expand-file-name "lisp" gm/config-root))
(add-to-list 'custom-theme-load-path (expand-file-name "themes" gm/config-root))

(require 'gm-core)
(require 'gm-java)
(require 'gm-hocon-mode)
(require 'gm-packages)
(require 'gm-ui)
(require 'gm-project)
(require 'gm-languages)
(require 'gm-tools)

(gm/core-initialize)
(gm/java-initialize)
(gm/packages-initialize)
(gm/ui-initialize)
(gm/project-initialize)
(gm/languages-initialize)
(gm/tools-initialize)

(provide 'init)
;;; init.el ends here
