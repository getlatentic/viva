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

(in-package #:viva.cli)

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

(defun launcher-shaped-p (path)
  "Does PATH look like a checkout's launcher: <something>/bin/<our name>?"
  (and (string= (env:base-name (launcher-path)) (env:base-name path))
       (string= "bin" (env:base-name (env:parent-path path)))))

(defun ours-p (link)
  "Is LINK one this repository put there, or one left over from a checkout
that has since moved or gone?

Two ways to be ours, and neither matches on the launcher's past names.

It points into THIS checkout's bin. That covers a link made before the
launcher file was renamed: it points at a path that no longer exists, so
PROBE-FILE reports nothing installed while the link is still in the way.

Or it DANGLES and is shaped like a launcher. Renaming or moving a checkout
leaves exactly this, pointing into a directory that is not ours because it is
not anybody's any more. A live link belonging to somebody else is still
refused -- only a link that resolves to nothing can be taken over, and a
dangling link nothing can run is not a thing worth protecting."
  (and link
       (or (string= (env:parent-path (launcher-path)) (env:parent-path link))
           (and (null (probe-file link)) (launcher-shaped-p link)))
       t))

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
        ;; The point of installing is being able to type the name, so a
        ;; directory that is not on PATH is a failed install wearing a success
        ;; message. Say the line that fixes it.
        (unless (on-path-p directory)
          (format t "~%~a is not on your PATH. Add it:~%~%  ~
export PATH=\"~a:$PATH\"~%~%and put that line in your shell's startup file.~%"
                  directory directory))
        0))))
