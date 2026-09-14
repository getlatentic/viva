;;;; The full-screen client.
;;;;
;;;; One connection and one thread. A reader thread would be the obvious
;;;; shape and it is wrong here: `daemon:request` writes a request and then
;;;; reads until it finds the response, so a second reader on the same socket
;;;; steals replies from it. Polling both sources in one loop cannot race with
;;;; itself.
;;;;
;;;; This adds nothing to the protocol. Everything on screen comes from
;;;; `session.list`, `session.attach` and the event stream those already
;;;; produce -- which is the test of whether the daemon's interface was
;;;; actually general or merely enough for one client.

(in-package #:viva.cli)

(defun beside-me (name &optional (self (or (first sb-ext:*posix-argv*) ""))
                                 (runtime sb-ext:*runtime-pathname*))
  "NAME in the directory this executable is in, or NIL.

A standalone build is one file somebody copied onto their PATH, and the client
CI builds beside it travels the same way. Looking next to ourselves is what
makes `viva` and `viva-tui` in one directory a working install rather than two
files that have to be told about each other.

THROUGH THE SYMLINK, because installing makes one. Typing the name leaves argv0
a bare `viva`, which TRUENAME resolves against the working directory and so not
at all; the runtime path is then the link rather than what it points at, and the
directory looked in is the one on PATH, where only the link lives. A standalone
binary quietly fell back to the Lisp client for exactly this reason."
  (a:when-let ((here (env:parent-path
                      (or (ignore-errors (namestring (truename self)))
                          (ignore-errors (namestring (truename runtime)))
                          (namestring runtime)))))
    (let ((candidate (env:join-path here name)))
      (when (probe-file candidate) candidate))))

(defun on-path (name)
  (a:when-let ((path (sb-posix:getenv "PATH")))
    (loop for directory in (uiop:split-string path :separator ":")
          for candidate = (and (plusp (length directory))
                               (env:join-path directory name))
          when (and candidate (probe-file candidate)) return candidate)))

(defun rust-client ()
  "Where the full-screen client is, or NIL.

Named first, then beside this executable, then on PATH, then under a checkout.
The checkout is LAST on purpose: it is the only one of the four that requires
viva to have been built rather than installed, and putting it first is how the
binary ended up unable to find a client that was sitting next to it."
  (or (a:when-let ((named (sb-posix:getenv "VIVA_TUI")))
        (when (probe-file named) named))
      (beside-me "viva-tui")
      (on-path "viva-tui")
      (a:when-let ((root (sb-posix:getenv "VIVA_ROOT")))
        (loop for build in '("release" "debug")
              for candidate = (env:join-path root "tui" "target" build "viva-tui")
              when (probe-file candidate) return candidate))))

(defun command-tui (parsed)
  "The full-screen client.

The client is given THIS PROCESS'S descriptors, so it draws on the real
terminal rather than into a pipe. SB-POSIX has no exec, so the image stays
alive waiting on it -- idle, and the price of handing the tty over from a
language whose runtime cannot replace itself. The launcher execs, so this cost
falls only on a standalone build.

NO SECOND CLIENT TO FALL BACK ON, deliberately. There was one, in Lisp, and
what it bought was that `viva tui` never failed -- at the cost of quietly
handing over a smaller, untested program under the name of the real one. The
honest answer when the client is missing is the line client, which is tested,
and a sentence saying how to get the other."
  (a:if-let ((client (rust-client)))
    (progn
      (sb-posix:setenv "VIVA_BIN" (or (first sb-ext:*posix-argv*) "viva") 1)
      (let ((process (sb-ext:run-program client (args-positional parsed)
                                         :input t :output t :error t
                                         :wait t :search nil)))
        (sb-ext:process-exit-code process)))
    (progn
      (format *error-output* "~&The full-screen client is not built here.~%~%~
Build it:   sh tui/install.sh~%~
Or work on the line:   viva attach~%")
      1)))
