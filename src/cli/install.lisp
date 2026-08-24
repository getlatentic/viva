;;;; Getting `viva` onto PATH, so the documented commands are the real ones.
;;;;
;;;; Every example in the README says `viva do ...`; the real invocation was
;;;; `./bin/viva` from the repository root, so anyone following the front
;;;; page was one step from `command not found` -- and the organism is meant to
;;;; be used in YOUR projects, which means being a command rather than a path.
;;;;
;;;; A SYMLINK, not a copy. The launcher resolves the repository from its own
;;;; location, so a copy would be a second launcher pointing at nothing and a
;;;; `git pull` would silently leave you running last week's. A link keeps one
;;;; installation and one truth about where it lives.

(in-package #:vivarium.cli)

(defparameter +install-candidates+
  '("~/.local/bin" "~/bin" "/usr/local/bin")
  "Where to install when nobody said. Tried in order; the first that exists and
is writable wins, and ~/.local/bin is created if none of them do -- it is the
one a package manager will not fight over.")

(defun expand-home (path)
  (if (a:starts-with-subseq "~/" path)
      (env:join-path (uiop:native-namestring (user-homedir-pathname)) (subseq path 2))
      path))

(defun path-directories ()
  (let ((path (or (env "PATH") "")))
    (remove "" (uiop:split-string path :separator '(#\:)) :test #'string=)))

(defun on-path-p (directory)
  (let ((wanted (string-right-trim "/" directory)))
    (some (lambda (each) (string= wanted (string-right-trim "/" each)))
          (path-directories))))

(defun writable-directory-p (directory)
  (and (probe-file (uiop:ensure-directory-pathname directory))
       (zerop (nth-value 2 (uiop:run-program
                            (list "test" "-w" (string-right-trim "/" directory))
                            :ignore-error-status t)))))

(defun install-directory (asked)
  "Where the link should go. Returns (values DIRECTORY REASON-IT-WAS-CHOSEN)."
  (if asked
      (values (expand-home asked) "you asked for it")
      (let ((found (find-if (lambda (candidate)
                              (let ((directory (expand-home candidate)))
                                (and (writable-directory-p directory)
                                     (on-path-p directory))))
                            +install-candidates+)))
        (if found
            (values (expand-home found) "it exists, is writable, and is on your PATH")
            (values (expand-home "~/.local/bin") "nothing suitable was on your PATH")))))

(defun launcher-path ()
  (namestring (merge-pathnames "bin/viva" (repository-root))))

(defun ours-p (link)
  "Is LINK one this repository put there, pointing at any name its launcher
has been called?

A link made before the launcher was renamed points at a path that no longer
exists, so PROBE-FILE says nothing is installed while the link is still in the
way. Treating it as a stranger's leaves an upgrade with a dangling command and
an installer refusing to fix it, which is a worse answer than replacing a link
this repository wrote itself."
  (let ((directory (env:parent-path (launcher-path))))
    (and link
         (string= directory (env:parent-path link))
         (member (env:base-name link) '("viva" "vivarium") :test #'string=)
         t)))

(defun describe-existing (target)
  "What is already at TARGET: NIL, :OURS, or a description of somebody else's."
  (let ((link (ignore-errors (sb-posix:readlink target))))
    (cond ((ours-p link) :ours)
          ((null (probe-file target))
           (unless link :none))
          (link (format nil "a link to ~a" link))
          (t "a file"))))

(defun relink (target launcher)
  "Point TARGET at LAUNCHER, replacing a link this repository already owns.

Returns true when TARGET now points at LAUNCHER. A link left over from an
earlier name is stale rather than installed, and reporting `already installed`
over a dangling one is how an upgrade ends with a command that does not run."
  (let ((link (ignore-errors (sb-posix:readlink target))))
    (cond ((and link (string= link launcher)) t)
          (t (ignore-errors (sb-posix:unlink target))
             (ignore-errors (sb-posix:symlink launcher target) t)))))

(defun command-install (parsed)
  "Link bin/viva into a directory on PATH.

Refuses to replace anything it did not put there. Overwriting a stranger's
binary because it happens to share a name is not a thing an installer gets to
decide, and `already installed` and `something else is called viva` are
different answers that must not look alike."
  (let ((launcher (launcher-path)))
    (multiple-value-bind (directory why) (install-directory (flag parsed "prefix"))
      (handler-case (ensure-directories-exist (uiop:ensure-directory-pathname directory))
        (error (condition)
          (format *error-output* "~&cannot use ~a: ~a~%" directory condition)
          (return-from command-install 1)))
      ;; BOTH NAMES. `viva` is the command. `vivarium` is what the code still
      ;; calls itself and what an earlier install put on PATH, so it is linked
      ;; too and anything anybody wrote against it goes on working. The
      ;; launcher resolves symlinks to find its root, so the second link costs
      ;; nothing and behaves identically.
      ;;
      ;; The old name is not allowed to fail the install. Somebody may have a
      ;; `vivarium` of their own, and refusing to install the tool at all
      ;; because a compatibility alias is taken would be absurd.
      (let ((target (env:join-path directory "viva")))
        (let ((existing (describe-existing target)))
          (case existing
            (:ours
             (if (relink target launcher)
                 (format t "~&already installed: ~a -> ~a~%" target launcher)
                 (progn (format *error-output* "~&could not point ~a at ~a~%" target launcher)
                        (return-from command-install 1))))
            (:none
             (handler-case (sb-posix:symlink launcher target)
               (error (condition)
                 (format *error-output* "~&could not link ~a: ~a~%" target condition)
                 (return-from command-install 1)))
             (format t "~&installed ~a -> ~a~%  (~a)~%" target launcher why))
            (t
             (format *error-output* "~&~a already exists and is ~a, not this repository's launcher.~%~
Move it, or choose somewhere else with --prefix DIR.~%" target existing)
             (return-from command-install 1))))
        (let* ((alias (env:join-path directory "vivarium"))
               (existing (describe-existing alias)))
          (case existing
            (:ours (if (relink alias launcher)
                       (format t "  and ~a~%" alias)
                       (format t "  (could not point ~a at the launcher)~%" alias)))
            (:none (if (ignore-errors (sb-posix:symlink launcher alias) t)
                       (format t "  and ~a~%" alias)
                       (format t "  (could not link ~a; ~a still works)~%" alias target)))
            (t (format t "  (~a is already ~a, so it was left alone)~%" alias existing))))
        ;; The point of installing is being able to type the name, so a
        ;; directory that is not on PATH is a failed install wearing a success
        ;; message. Say the line that fixes it.
        (unless (on-path-p directory)
          (format t "~%~a is not on your PATH. Add it:~%~%  ~
export PATH=\"~a:$PATH\"~%~%and put that line in your shell's startup file.~%"
                  directory directory))
        0))))
