;;;; `vivarium learned` -- what has this project's agent accumulated?
;;;;
;;;; The germline is files, which is the whole architecture, and a person
;;;; should still not have to `cat .vivarium/MEMORY.md` and walk
;;;; `.vivarium/tools/*/tool.json` to see what a project's agent knows.
;;;;
;;;; Reads only. No model request, no daemon, no session -- so it works on a
;;;; project whose agent has never been started, and on one that is mid-turn.

(in-package #:vivarium.cli)

(defun scope-mark (item)
  (if (eq :machine (germline:item-scope item)) "~" " "))

(defun show-items (label items &key detail)
  (format t "~&~%~a~@[  (~d)~]~%" label (and (rest items) (length items)))
  (if (null items)
      (format t "  none~%")
      (dolist (item items)
        (if detail
            (format t "  ~a ~a~24t~a~%" (scope-mark item) (germline:item-name item)
                    (one-line (germline:item-detail item) 50))
            (format t "  ~a ~a~%" (scope-mark item) (germline:item-name item))))))

(defun command-learned (parsed)
  "What this directory's agent has retained: notes, skills, tools."
  (let* ((cwd (namestring (truename (or (first (args-positional parsed))
                                        (flag parsed "cwd") "."))))
         (view (germline:inspect-directory cwd)))
    (format t "~&~a~%" (germline:view-cwd view))
    (show-items "notes" (germline:view-notes view))
    (show-items "skills" (germline:view-skills view) :detail t)
    (show-items "tools" (germline:view-tools view) :detail t)
    ;; "There is a tool here" and "the agent can call it" are different
    ;; questions, so a refused tool is shown as refused rather than folded into
    ;; `none` -- an empty germline and an unreachable one are opposite
    ;; situations. And the trust note appears only when something is actually
    ;; being refused: warning about tools that do not exist is noise on every
    ;; directory a person points this at.
    (a:when-let ((refused (germline:view-refused view)))
      (format t "~&~%refused  (~d)~%" (length refused))
      (dolist (item refused)
        (format t "  ~a ~a~24tpresent, but will not run~%"
                (scope-mark item) (germline:item-name item)))
      (unless (germline:view-trusted-p view)
        (format t "~&~%This project is not trusted, so the tools above will not run.~%~
Enable them with:  vivarium trust ~a~%" cwd)))
    (dolist (warning (germline:view-warnings view))
      ;; The registry's refusal is already said above, in fewer words.
      (unless (search "is not a trusted project" warning)
        (format t "~&! ~a~%" warning)))
    (when (some (lambda (item) (eq :machine (germline:item-scope item)))
                (append (germline:view-notes view) (germline:view-skills view)
                        (germline:view-tools view)))
      (format t "~&~%~~ marks what comes from ~~/.vivarium and travels to every project.~%"))
    0))
