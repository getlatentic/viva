;;;; The observational floor: one look at one thing, per call.
;;;;
;;;; Arm A can change a running image and cannot see into it. READ-DEFINITION
;;;; returns source, INSTALL returns "Installed X.", FIND-DEFINITIONS matches
;;;; names, and BASH is jailed outside the process. So a task whose evidence
;;;; lives in runtime values rather than in source is not expensive for this
;;;; tool set -- it is unreachable. B14 needs the floor to be expensive, not
;;;; absent, or a reusable inspection capability would be measuring a capability
;;;; asymmetry rather than an improvement.
;;;;
;;;; RESTRICTED ON PURPOSE, and this is the whole design. A tool that evaluated
;;;; an arbitrary form would let one call do the work of the reusable capability
;;;; B14 is trying to price -- the agent writes the traversal inline, learns the
;;;; same thing, persists nothing, and the capability under test becomes
;;;; syntactic sugar. Neither failure is acceptable:
;;;;
;;;;   wanted     possible, repetitive, expensive  ->  same information, cheaper
;;;;   forbidden  impossible                       ->  possible
;;;;   forbidden  arbitrary eval already does it   ->  sugar
;;;;
;;;; So: ONE lookup or ONE call of an EXISTING function, ONE step of descent, no
;;;; loops, no higher-order traversal, no mutation, bounded output. Correlating
;;;; several observations is the agent's job, and it is the job a reusable
;;;; capability can later do in one call.
;;;;
;;;; This does NOT settle E5, whose bet is that a single arbitrary-eval tool
;;;; beats a fixed schema. If that bet pays, the improvement target has to become
;;;; something an inline one-shot form cannot cheaply reproduce -- persistent
;;;; indexing, instrumentation across time, accumulated cross-call state.

(in-package #:vivarium.inspect)

(defvar *package-under-inspection* nil
  "Package that unqualified names resolve in. Bound per run, like *BACKEND*.")

(defvar *handles* nil
  "Handle string -> object, for values too large to print. Bound per run so a
forked trial gets its own and handles never leak between attempts.")

(defvar *handle-counter* 0)

(defparameter +print-length+ 20)
(defparameter +print-level+ 3)
(defparameter +output-limit+ 1200
  "Characters. A bound is what stops one inspection from being a whole traversal
by printing a 5,000-element list.")

(defun begin-inspection-session ()
  (setf *handles* (make-hash-table :test #'equal)
        *handle-counter* 0))

;;; Handles
;;;
;;; Descent is one step per call, so a nested structure has to be reachable
;;; across calls without the agent re-deriving the path. A handle names a value
;;; the agent has already seen; it is not a way to reach one it has not.

(defun mint-handle (value)
  (let ((name (format nil "#h~d" (incf *handle-counter*))))
    (setf (gethash name *handles*) value)
    name))

(defun handle-value (name)
  (multiple-value-bind (value present) (gethash name *handles*)
    (if present (values value t) (values nil nil))))

(defun handle-name-p (string)
  (and (stringp string) (> (length string) 2) (string= "#h" string :end2 2)))

;;; Rendering
;;;
;;; Anything that does not print small becomes a handle plus a shape summary, so
;;; the agent can descend deliberately rather than receive a wall of text it did
;;; not ask for.

(defun render (value)
  (let ((printed (let ((*print-length* +print-length+)
                       (*print-level* +print-level+)
                       (*print-circle* t)
                       (*print-readably* nil))
                   (handler-case (prin1-to-string value)
                     (error (condition) (format nil "<unprintable: ~a>" (type-of condition)))))))
    (if (<= (length printed) +output-limit+)
        (format nil "~a~@[~%~a~]" printed (shape value))
        (format nil "~a~%~a~%~a"
                (subseq printed 0 +output-limit+)
                "... truncated"
                (format nil "handle ~a~@[~%~a~]" (mint-handle value) (shape value))))))

(defun shape (value)
  "What can be asked for next. Without this the agent guesses at descent steps."
  (typecase value
    (hash-table (format nil "hash-table, ~d entries~@[, keys include ~{~s~^ ~}~]"
                        (hash-table-count value)
                        (let ((keys '()))
                          (maphash (lambda (k v) (declare (ignore v))
                                     (when (< (length keys) 8) (push k keys)))
                                   value)
                          (nreverse keys))))
    (string nil)
    (list (format nil "list, ~d elements -- descend with step = an index"
                  (ignore-errors (length value))))
    (vector (format nil "vector, ~d elements -- descend with step = an index" (length value)))
    (standard-object
     (format nil "instance of ~a -- descend with step = a slot name~%slots: ~{~a~^ ~}"
             (class-name (class-of value))
             (mapcar #'sb-mop:slot-definition-name
                     (sb-mop:class-slots (class-of value)))))
    (function "function -- inspect what it returns by naming it as target with args")
    (t nil)))

;;; Resolving a target
;;;
;;; Three kinds and no more: a handle already minted, a special variable's
;;; current value, or an existing function called on literal arguments.

(defun resolve-symbol (name)
  (let* ((text (string-upcase (string-trim " " name)))
         (colon (search "::" text))
         (package (if colon
                      (find-package (subseq text 0 colon))
                      (or *package-under-inspection*
                          (error "No package bound for inspection."))))
         (short (if colon (subseq text (+ colon 2)) text)))
    (and package (find-symbol short package))))

(defun read-literal (text)
  "Arguments are literals or handles. *READ-EVAL* is off, and a form that is not
self-evaluating is refused rather than evaluated -- otherwise #.(anything) would
reopen the whole door this file exists to close."
  (if (handle-name-p text)
      (multiple-value-bind (value present) (handle-value text)
        (if present value (error "No such handle: ~a" text)))
      (let ((*read-eval* nil))
        (multiple-value-bind (form position) (read-from-string text nil nil)
          ;; Refuse anything the reader did not consume whole. Without this,
          ;; "1 status" silently reads as 1 and the extra step is dropped -- the
          ;; agent asks for two things, is told nothing, and gets one. A
          ;; primitive whose job is to make each observation cost a request
          ;; cannot quietly accept a request for two.
          (when (< position (length (string-right-trim " " text)))
            (error "~s is more than one thing. Ask for one index, key or slot per call." text))
          (typecase form
            ((or number string character keyword boolean) form)
            (symbol (or (resolve-symbol text)
                        (error "~a is not a literal and does not name a symbol." text)))
            (cons (error "~a is a form. This tool takes literals, not expressions." text))
            (t form))))))

(defun descend (value step)
  "Exactly one step. An index, a hash key, or a slot name."
  (typecase value
    (hash-table
     (let ((key (read-literal step)))
       (multiple-value-bind (found present) (gethash key value)
         (if present found
             (multiple-value-bind (found2 present2) (gethash (string-upcase step) value)
               (if present2 found2 (error "No entry for ~a." step)))))))
    (standard-object
     (let ((slot (resolve-symbol step)))
       (cond ((null slot) (error "No slot named ~a." step))
             ((not (slot-boundp value slot)) :unbound)
             (t (slot-value value slot)))))
    (sequence
     (let ((index (read-literal step)))
       (unless (integerp index) (error "~a is not an index." step))
       (unless (< -1 index (length value)) (error "Index ~d is outside 0..~d." index (1- (length value))))
       (elt value index)))
    (t (error "~a cannot be descended into." (type-of value)))))

(defun observe (target step args)
  (let ((base
          (cond ((handle-name-p target)
                 (multiple-value-bind (value present) (handle-value target)
                   (unless present (error "No such handle: ~a" target))
                   value))
                ((and (stringp target) (find (char (string-left-trim " " target) 0) "(`',"))
                 ;; Say what is actually wrong. "Nothing named (loop ...)" sends
                 ;; the agent hunting for a definition that was never the point.
                 (error "This tool does not evaluate expressions. Name one variable, ~
function or handle, and relate several observations yourself."))
                (t
                 (let ((symbol (or (resolve-symbol target)
                                   (error "Nothing named ~a in this image." target))))
                   (cond
                     (args
                      (unless (fboundp symbol)
                        (error "~a is not a function, so args do not apply." target))
                      (apply symbol (mapcar #'read-literal args)))
                     ((boundp symbol) (symbol-value symbol))
                     ((fboundp symbol) (funcall symbol))
                     (t (error "~a is neither bound nor fbound." target))))))))
    (if step (descend base step) base)))

(tool:define-tool inspect-value (args context)
  :description "Look at ONE value in the running image: a variable's current
value, one step inside something you have already seen, or the result of calling
one existing function. This does not evaluate expressions -- no loops, no mapcar,
no arithmetic. To relate several values, look at each one and compare them
yourself. Large values come back as a handle you can pass as target to descend."
  :parameters (("target" :string "A variable or function name, e.g. \"*EVENTS*\" or \"ORDER-TOTAL\", or a handle like \"#h3\"" :required-p t)
               ("step" :string "One step inside it: a list index, a hash key, or a slot name" :required-p nil)
               ("args" :array "Arguments, when target names a function. Literals or handles only." :required-p nil))
  (handler-case
      (render (observe (gethash "target" args)
                       (gethash "step" args)
                       (coerce (or (gethash "args" args) '()) 'list)))
    (error (condition)
      (tool:make-tool-result :output (princ-to-string condition) :error-p t))))

(defun tool-set () (list inspect-value))
