;;;; Promoted capability, kept where the next process can find it.
;;;;
;;;; COMPILE KEEPS NOTHING OF ITS ARGUMENT. A promoted capability was a
;;;; function object in a hash table and no more: unreadable by a person,
;;;; unwritable to disk, and gone with the image. The organism could change
;;;; what it ran and could not carry one change across a restart -- which made
;;;; "self-improving" true only for as long as nobody stopped the daemon.
;;;;
;;;; SO THE SOURCE IS THE DURABLE ARTEFACT, and this is where it lives:
;;;;
;;;;   <root>/4.lisp             promoted, recompiled at every daemon start
;;;;   <root>/retracted/4.lisp   reverted, kept readable, never recompiled
;;;;
;;;; FLAT, AND NAMED BY VERSION ID. A component name comes from the model, so
;;;; a name in a path is a path the model chooses: `../../../.ssh/config` is a
;;;; capability name. Version ids are integers this process mints, the file
;;;; carries its own component name inside, and no sanitising rule has to be
;;;; got right.
;;;;
;;;; CANDIDATES ARE NOT KEPT. A candidate is task-local by proven law and dies
;;;; with its task; writing one down would durably record a decision the
;;;; organism never made. Promotion is the moment the organism says this is
;;;; what I am now, and that is the moment worth a file.

(in-package #:viva.actor)

(defvar *capability-root*
  (let ((given (sb-posix:getenv "VIVA_CAPABILITIES")))
    (if (and given (plusp (length given)))
        (namestring (uiop:ensure-directory-pathname given))
        (concatenate 'string (env:capabilities-directory) "/")))
  "Where promoted capability source lives. Moves with the evolution ledger --
they are two halves of one account, and a run whose ledger says promoted while
its store says nothing is a run that cannot be read back.")

(defun capability-path (id &key retracted)
  (merge-pathnames (format nil "~:[~;retracted/~]~d.lisp" retracted id)
                   *capability-root*))

;;; Printing and reading, in one syntax
;;;
;;; A source form is symbols, and a symbol read in one package and printed in
;;; another is a different symbol. Both directions bind the same package, so
;;; anything not accessible there prints with its prefix and reads back
;;; identical. Reading never evaluates: the deliberate step is COMPILE, and it
;;; happens once, in the caller, inside a handler.

(defmacro with-capability-syntax (&body body)
  `(with-standard-io-syntax
     (let ((*package* (find-package '#:viva.capabilities))
           (*read-eval* nil)
           (*print-readably* nil)
           (*print-pretty* t)
           (*print-right-margin* 78))
       ,@body)))

(defun write-capability (id component source)
  "Write the promoted SOURCE for version ID. Returns the path, or NIL.

Written aside and renamed, because RENAME is the atomic step. A daemon killed
mid-write would otherwise leave a truncated form that the next start cannot
read, and the failure would look like a capability that never existed."
  (handler-case
      (let* ((path (capability-path id))
             (staging (make-pathname :type "writing" :defaults path)))
        (ensure-directories-exist path)
        (with-open-file (out staging :direction :output
                                     :if-exists :supersede
                                     :external-format :utf-8)
          (with-capability-syntax
            (format out ";;; viva capability ~d -- ~a~%" id component)
            (format out ";;; Promoted. Recompiled at every daemon start.~%~%")
            (prin1 (list :capability :version id :component component
                         :source source)
                   out)
            (terpri out)))
        (rename-file staging path)
        path)
    (error (condition)
      (format *error-output* "~&viva capability: version ~d not written: ~a~%"
              id condition)
      nil)))

(defun retract-capability (id)
  "Move version ID out of what a restart restores, keeping it readable.

NOT A DELETE. A reversion is the organism judging its own work, and the
judgment is worth more with the work still beside it. Reversion drops the
version from the lineage for good, so nothing here has to bring one back."
  (let ((path (capability-path id))
        (aside (capability-path id :retracted t)))
    (when (probe-file path)
      (handler-case (progn (ensure-directories-exist aside)
                           (rename-file path aside)
                           aside)
        (error (condition)
          (format *error-output* "~&viva capability: version ~d not retracted: ~a~%"
                  id condition)
          nil)))))

(defun read-capability (path)
  "One stored capability as (ID COMPONENT SOURCE), or NIL if it will not read."
  (handler-case
      (let ((form (with-capability-syntax
                    (with-open-file (in path :external-format :utf-8)
                      (read in)))))
        (when (and (consp form) (eq :capability (first form)))
          (let ((id (getf (rest form) :version))
                (component (getf (rest form) :component))
                (source (getf (rest form) :source)))
            (when (and (integerp id) (stringp component) source)
              (list id component source)))))
    (error (condition)
      (format *error-output* "~&viva capability: ~a unreadable: ~a~%" path condition)
      nil)))

(defun stored-capabilities (&optional (root *capability-root*))
  "Every promoted capability on disk, oldest identity first.

Ascending by id is the promotion order, so replaying in this order rebuilds
each component's lineage exactly as the runs that promoted them left it. One
unreadable file is reported and skipped: a single bad form must not cost the
organism every other thing it learned."
  (let ((found '()))
    (dolist (path (ignore-errors (directory (merge-pathnames "*.lisp" root))))
      (a:when-let ((entry (read-capability path)))
        (push entry found)))
    (sort found #'< :key #'first)))
