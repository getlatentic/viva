;;;; Provider keys, read from a file rather than from the shell that started us.
;;;;
;;;; The launcher sources `~/.viva/.env` before it hands over, which works for
;;;; every run that goes through a checkout. A standalone build has no launcher
;;;; and no checkout: it is one executable somebody put on their PATH, and
;;;; until it reads the file itself it starts with no key and no way to be told
;;;; where one is.
;;;;
;;;; ONLY WHAT IS NOT ALREADY SET. The launcher, when there is one, has already
;;;; done this -- and a caller who wrote `DEEPSEEK_API_KEY=... viva do ...`
;;;; means that key for that run. A file that overwrote either would be taking
;;;; a decision away from whoever made it more deliberately.

(in-package #:viva.cli)

(defun credential-line (line)
  "NAME and VALUE from one line of a `.env`, or NIL for a line carrying neither.

Reads what `.` reads in the shell: `NAME=value`, an optional `export`, and
either quote around the value. Anything else is skipped rather than signalled,
because a key file is edited by hand and one odd line should not stop a run
that has every key it needs."
  (let* ((trimmed (string-trim '(#\Space #\Tab #\Return) line))
         (body (if (a:starts-with-subseq "export " trimmed)
                   (string-left-trim " " (subseq trimmed 7))
                   trimmed)))
    (unless (or (zerop (length body)) (char= #\# (char body 0)))
      (a:when-let ((break (position #\= body)))
        (let ((name (string-right-trim " " (subseq body 0 break)))
              (value (string-trim " " (subseq body (1+ break)))))
          (when (plusp (length name))
            (cons name (unquoted value))))))))

(defun unquoted (value)
  (if (and (>= (length value) 2)
           (member (char value 0) '(#\" #\'))
           (char= (char value 0) (char value (1- (length value)))))
      (subseq value 1 (1- (length value)))
      value))

(defun load-credentials (&optional (path (env:home-path ".env")))
  "Put the names in PATH into this process's environment, keeping what is there.

Returns the names it set, which is what a test can assert on -- the values are
keys and do not belong in a failure message."
  (when (probe-file path)
    (with-open-file (in path :external-format :utf-8 :if-does-not-exist nil)
      (when in
        (loop for line = (read-line in nil nil)
              while line
              for pair = (credential-line line)
              when (and pair (null (sb-posix:getenv (car pair))))
                collect (car pair)
                and do (sb-posix:setenv (car pair) (cdr pair) 1))))))

(defun load-every-credential ()
  "The machine's keys, then a checkout's own when this is running from one.

Neither overwrites a name that is already set, so the machine's file wins over
a checkout's. The launcher resolves a tie the other way, and the difference
cannot be reached: a run that went through the launcher arrives here with every
name already set, and a run that did not has no checkout to read."
  (load-credentials)
  (a:when-let ((root (sb-posix:getenv "VIVA_ROOT")))
    (load-credentials (env:join-path root ".env"))))
