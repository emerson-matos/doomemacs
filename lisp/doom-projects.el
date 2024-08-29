;;; doom-projects.el --- defaults for project management in Doom -*- lexical-binding: t; -*-
;;; Commentary:
;;; Code:

(defvar doom-projectile-cache-limit 10000
  "If any project cache surpasses this many files it is purged when quitting
Emacs.")

(defvar doom-projectile-cache-blacklist '("~" "/tmp" "/")
  "Directories that should never be cached.")

(defvar doom-projectile-cache-purge-non-projects nil
  "If non-nil, non-projects are purged from the cache on `kill-emacs-hook'.")

(define-obsolete-variable-alias 'doom-projectile-fd-binary 'doom-fd-executable "3.0.0")
(defvar doom-fd-executable (cl-find-if #'executable-find (list "fdfind" "fd"))
  "The filename of the fd executable.

On some distros it's fdfind (ubuntu, debian, and derivatives). On most it's fd.
Is nil if no executable is found in your PATH during startup.")

(defvar doom-ripgrep-executable (executable-find "rg")
  "The filename of the Ripgrep executable.

Is nil if no executable is found in your PATH during startup.")


;;
;;; Packages

(use-package! project
  :defer t
  :init
  (setq project-list-file (file-name-concat doom-profile-state-dir "projects"))
  :config
  ;; Not valid vc backends, but I use it to inform (global) file index
  ;; exclusions below and elsewhere.
  (add-to-list 'project-vc-backend-markers-alist '(Jujutsu . ".jj"))
  (add-to-list 'project-vc-backend-markers-alist '(Sapling . ".sl"))
  (add-to-list 'project-vc-extra-root-markers ".jj")

  ;; TODO: Advice or add command for project-wide `find-sibling-file'.
  )


;; DEPRECATED: Will be replaced with project.el
(use-package! projectile
  :commands (projectile-project-root
             projectile-project-name
             projectile-project-p
             projectile-locate-dominating-file
             projectile-relevant-known-projects)
  :init
  (setq projectile-cache-file (concat doom-cache-dir "projectile.cache")
        ;; Auto-discovery is slow to do by default. Better to update the list
        ;; when you need to (`projectile-discover-projects-in-search-path').
        projectile-auto-discover nil
        projectile-enable-caching (not noninteractive)
        projectile-globally-ignored-files '(".DS_Store" "TAGS")
        projectile-globally-ignored-file-suffixes '(".elc" ".pyc" ".o")
        projectile-kill-buffers-filter 'kill-only-files
        projectile-known-projects-file (concat doom-cache-dir "projectile.projects")
        projectile-ignored-projects '("~/")
        projectile-ignored-project-function #'doom-project-ignored-p
        projectile-fd-executable doom-fd-executable)

  (global-set-key [remap evil-jump-to-tag] #'projectile-find-tag)
  (global-set-key [remap find-tag]         #'projectile-find-tag)

  :config
  ;; HACK: Auto-discovery and cleanup on `projectile-mode' is slow and
  ;;   premature. Let's try to defer it until it's needed.
  (add-transient-hook! 'projectile-relevant-known-projects
    (projectile--cleanup-known-projects)
    (when projectile-auto-discover
      (projectile-discover-projects-in-search-path)))

  ;; Projectile runs four functions to determine the root (in this order):
  ;;
  ;; + `projectile-root-local' -> checks the `projectile-project-root' variable
  ;;    for an explicit path.
  ;; + `projectile-root-bottom-up' -> searches from / to your current directory
  ;;   for the paths listed in `projectile-project-root-files-bottom-up'. This
  ;;   includes .git and .project
  ;; + `projectile-root-top-down' -> searches from the current directory down to
  ;;   / the paths listed in `projectile-root-files', like package.json,
  ;;   setup.py, or Cargo.toml
  ;; + `projectile-root-top-down-recurring' -> searches from the current
  ;;   directory down to / for a directory that has one of
  ;;   `projectile-project-root-files-top-down-recurring' but doesn't have a
  ;;   parent directory with the same file.
  ;;
  ;; In the interest of performance, we reduce the number of project root marker
  ;; files/directories projectile searches for when resolving the project root.
  ;;
  ;; These will be filled by other modules. We build this list manually so
  ;; projectile doesn't perform so many file checks every time it resolves a
  ;; project's root -- particularly when a file has no project.
  (setq projectile-project-root-files '()
        projectile-project-root-files-top-down-recurring '("Makefile"))

  ;; Adds a more editor/plugin-agnostic project marker.
  (add-to-list 'projectile-project-root-files-bottom-up ".project")

  (push (abbreviate-file-name doom-local-dir) projectile-globally-ignored-directories)

  ;; Per-project compilation buffers
  (setq compilation-buffer-name-function #'projectile-compilation-buffer-name
        compilation-save-buffers-predicate #'projectile-current-project-buffer-p)

  ;; Support the more generic .project files as an alternative to .projectile
  (defadvice! doom--projectile-dirconfig-file-a ()
    :override #'projectile-dirconfig-file
    (let ((proot (projectile-project-root)))
      (cond ((file-exists-p! (or projectile-dirconfig-file ".project") proot))
            ((expand-file-name ".project" proot)))))

  ;; Disable commands that won't work, as is, and that Doom already provides a
  ;; better alternative for.
  (put 'projectile-ag 'disabled "Use +default/search-project instead")
  (put 'projectile-ripgrep 'disabled "Use +default/search-project instead")
  (put 'projectile-grep 'disabled "Use +default/search-project instead")

  ;; Treat current directory in dired as a "file in a project" and track it
  (add-hook 'dired-before-readin-hook #'projectile-track-known-projects-find-file-hook)

  ;; Accidentally indexing big directories like $HOME or / will massively bloat
  ;; projectile's cache (into the hundreds of MBs). This purges those entries
  ;; when exiting Emacs to prevent slowdowns/freezing when cache files are
  ;; loaded or written to.
  (add-hook! 'kill-emacs-hook
    (defun doom-cleanup-project-cache-h ()
      "Purge projectile cache entries that:

a) have too many files (see `doom-projectile-cache-limit'),
b) represent blacklisted directories that are too big, change too often or are
   private. (see `doom-projectile-cache-blacklist'),
c) are not valid projectile projects."
      (when (and (bound-and-true-p projectile-projects-cache)
                 projectile-enable-caching)
        (setq projectile-known-projects
              (cl-remove-if #'projectile-ignored-project-p
                            projectile-known-projects))
        (projectile-cleanup-known-projects)
        (cl-loop with blacklist = (mapcar #'file-truename doom-projectile-cache-blacklist)
                 for proot in (hash-table-keys projectile-projects-cache)
                 if (or (not (stringp proot))
                        (string-empty-p proot)
                        (>= (length (gethash proot projectile-projects-cache))
                            doom-projectile-cache-limit)
                        (member (substring proot 0 -1) blacklist)
                        (and doom-projectile-cache-purge-non-projects
                             (not (doom-project-p proot)))
                        (projectile-ignored-project-p proot))
                 do (doom-log "Removed %S from projectile cache" proot)
                 and do (remhash proot projectile-projects-cache)
                 and do (remhash proot projectile-projects-cache-time)
                 and do (remhash proot projectile-project-type-cache))
        (projectile-serialize-cache))))

  ;; HACK: Some MSYS utilities auto expanded the `/' path separator, so we need
  ;;   to prevent it.
  (when doom--system-windows-p
    (setenv "MSYS_NO_PATHCONV" "1") ; Fix path in Git Bash
    (setenv "MSYS2_ARG_CONV_EXCL" "--path-separator")) ; Fix path in MSYS2

  ;; HACK: Don't rely on VCS-specific commands to generate our file lists.
  ;;   That's 7 commands to maintain, versus the more generic, reliable, and
  ;;   performant `fd' or `ripgrep'.
  (defadvice! doom--only-use-generic-command-a (fn vcs)
    "Only use `projectile-generic-command' for indexing project files.
And if it's a function, evaluate it."
    :around #'projectile-get-ext-command
    (if (and (functionp projectile-generic-command)
             (not (file-remote-p default-directory)))
        (funcall projectile-generic-command vcs)
      (let ((projectile-git-submodule-command
             (or projectile-git-submodule-command
                 (get 'projectile-git-submodule-command 'initial-value))))
        (funcall fn vcs))))

  ;; HACK: `projectile-generic-command' doesn't typically support a function,
  ;;   but my `doom--only-use-generic-command-a' advice allows this. I do it
  ;;   this way to make it easier for folks to undo the change (if not set to a
  ;;   function, projectile will revert to default behavior).
  (put 'projectile-git-submodule-command 'initial-value projectile-git-submodule-command)
  (setq projectile-git-submodule-command nil
        ;; Include and follow symlinks in file listings.
        projectile-git-fd-args (concat "-L -tl " projectile-git-fd-args)
        projectile-indexing-method 'hybrid
        projectile-generic-command
        (lambda (_)
          ;; If fd or ripgrep exists, use it to produce file listings for
          ;; projectile commands. fd is a rust program that is significantly
          ;; faster than git ls-files, find, or the various VCS commands
          ;; projectile is configured to use. Plus, it respects .gitignore.
          (cond
           ((when-let*
                ((doom-fd-executable)
                 (projectile-git-use-fd)
                 ;; REVIEW Temporary fix for #6618. Improve me later.
                 (version (with-memoization (get 'doom-fd-executable 'version)
                            (cadr (split-string (cdr (doom-call-process doom-fd-executable "--version"))
                                                " " t))))
                 ((ignore-errors (version-to-list version))))
              (string-join
               (delq
                nil (list doom-fd-executable "."
                          (if (version< version "8.3.0")
                              (replace-regexp-in-string "--strip-cwd-prefix" "" projectile-git-fd-args t t)
                            projectile-git-fd-args)
                          (when project-vc-backend-markers-alist
                            (mapconcat (fn! (format "-E %s" (shell-quote-argument (cdr %))))
                                       project-vc-backend-markers-alist
                                       " "))
                          (if doom--system-windows-p " --path-separator=/" "")))
               " ")))
           ;; Otherwise, resort to ripgrep, which is also faster than find
           (doom-ripgrep-executable
            (string-join
             (delq
              nil (list doom-ripgrep-executable
                        "-0 --files --follow --color=never --hidden"
                        (when project-vc-backend-markers-alist
                          (mapconcat (fn! (format "-g!%s" (shell-quote-argument (cdr %))))
                                     project-vc-backend-markers-alist
                                     " "))
                        (if doom--system-windows-p " --path-separator=/")))
             " "))
           ((not doom--system-windows-p) "find . -type f | cut -c3- | tr '\\n' '\\0'")
           ("find . -type f -print0"))))

  (defadvice! doom--projectile-default-generic-command-a (fn &rest args)
    "If projectile can't tell what kind of project you're in, it issues an error
when using many of projectile's command, e.g. `projectile-compile-command',
`projectile-run-project', `projectile-test-project', and
`projectile-configure-project', for instance.

This suppresses the error so these commands will still run, but prompt you for
the command instead."
    :around #'projectile-default-generic-command
    (ignore-errors (apply fn args)))

  ;; HACK: Projectile cleans up the known projects list at startup. If this list
  ;;   contains tramp paths, the `file-remote-p' calls will pull in tramp via
  ;;   its `file-name-handler-alist' entry, which is expensive. Since Doom
  ;;   already cleans up the project list on kill-emacs-hook, it's simplest to
  ;;   inhibit this cleanup process at startup (see bbatsov/projectile#1649).
  (letf! ((#'projectile--cleanup-known-projects #'ignore))
    (projectile-mode +1)
    ;; HACK: See bbatsov/projectile@3c92d28c056c
    (remove-hook 'buffer-list-update-hook #'projectile-track-known-projects-find-file-hook)
    (add-hook 'doom-switch-buffer-hook #'projectile-track-known-projects-find-file-hook t)))


;;
;;; Project-based minor modes

(defvar doom-project-hook nil
  "Hook run when a project is enabled. The name of the project's mode and its
state are passed in.")

(cl-defmacro def-project-mode! (name &key
                                     modes
                                     files
                                     when
                                     match
                                     add-hooks
                                     on-load
                                     on-enter
                                     on-exit)
  "Define a project minor mode named NAME and where/how it is activated.

Project modes allow you to configure 'sub-modes' for major-modes that are
specific to a folder, project structure, framework or whatever arbitrary context
you define. These project modes can have their own settings, keymaps, hooks,
snippets, etc.

This creates NAME-hook and NAME-map as well.

PLIST may contain any of these properties, which are all checked to see if NAME
should be activated. If they are *all* true, NAME is activated.

  :modes MODES -- if buffers are derived from MODES (one or a list of symbols).

  :files FILES -- if project contains FILES; takes a string or a form comprised
    of nested (and ...) and/or (or ...) forms. Each path is relative to the
    project root, however, if prefixed with a '.' or '..', it is relative to the
    current buffer.

  :match REGEXP -- if file name matches REGEXP

  :when PREDICATE -- if PREDICATE returns true (can be a form or the symbol of a
    function)

  :add-hooks HOOKS -- HOOKS is a list of hooks to add this mode's hook.

  :on-load FORM -- FORM to run the first time this project mode is enabled.

  :on-enter FORM -- FORM is run each time the mode is activated.

  :on-exit FORM -- FORM is run each time the mode is disabled.

Relevant: `doom-project-hook'."
  (declare (indent 1))
  (let ((init-var (intern (format "%s-init" name))))
    (macroexp-progn
     (append
      (when on-load
        `((defvar ,init-var nil)))
      `((define-minor-mode ,name
          "A project minor mode generated by `def-project-mode!'."
          :init-value nil
          :lighter ""
          :keymap (make-sparse-keymap)
          (if (not ,name)
              ,on-exit
            (run-hook-with-args 'doom-project-hook ',name ,name)
            ,(when on-load
               `(unless ,init-var
                  ,on-load
                  (setq ,init-var t)))
            ,on-enter))
        (dolist (hook ,add-hooks)
          (add-hook ',(intern (format "%s-hook" name)) hook)))
      (cond ((or files modes when)
             (cl-check-type files (or null list string))
             (let ((fn
                    `(lambda ()
                       (and (not (bound-and-true-p ,name))
                            (and buffer-file-name (not (file-remote-p buffer-file-name nil t)))
                            ,(or (null match)
                                 `(if buffer-file-name (string-match-p ,match buffer-file-name)))
                            ,(or (null files)
                                 ;; Wrap this in `eval' to prevent eager expansion
                                 ;; of `project-file-exists-p!' from pulling in
                                 ;; autoloaded files prematurely.
                                 `(eval
                                   '(project-file-exists-p!
                                     ,(if (stringp (car files)) (cons 'and files) files))))
                            ,(or when t)
                            (,name 1)))))
               (if modes
                   `((dolist (mode ,modes)
                       (let ((hook-name
                              (intern (format "doom--enable-%s%s-h" ',name
                                              (if (eq mode t) "" (format "-in-%s" mode))))))
                         (fset hook-name #',fn)
                         (if (eq mode t)
                             (add-to-list 'auto-minor-mode-magic-alist (cons hook-name #',name))
                           (add-hook (intern (format "%s-hook" mode)) hook-name)))))
                 `((add-hook 'change-major-mode-after-body-hook #',fn)))))
            (match
             `((add-to-list 'auto-minor-mode-alist (cons ,match #',name)))))))))

(provide 'doom-projects)
;;; doom-projects.el ends here
