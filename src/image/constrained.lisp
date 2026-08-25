;;;; Experiment B's restricted action surface.
;;;;
;;;; The B arms are supposed to differ by exactly one capability -- whether the
;;;; agent can RUN what it just wrote. Twice that contract turned out to be
;;;; false, and both times the loophole was found by adversarial review rather
;;;; than by a passing reference solution:
;;;;
;;;;   1 INSTALL IS AN EXECUTION CHANNEL. A top-level (defparameter *x* (mapcar
;;;;     ...)) runs its initializer at install time, so the whole computation can
;;;;     be smuggled into a definition. A legal CONTROL solve of F1 did exactly
;;;;     this and scored 5/5.
;;;;   2 INSPECT_VALUE IS AN EXECUTION CHANNEL. Its function-call path applies an
;;;;     fbound symbol, so install a DEFUN and inspect it by name and it runs.
;;;;
;;;; And freezing symbol NAMES at setup does not close 2, because an agent can
;;;; redefine an old name:
;;;;
;;;;     (defun rate-for (...) <arbitrary work>)   then inspect RATE-FOR
;;;;
;;;; So the rule is IDENTITY, not membership -- and stronger still, a WHITELIST,
;;;; because provenance is not purity. A pre-existing RECOMPUTE-ALL would mutate
;;;; the world as effectively as any new helper.
;;;;
;;;;   callable  =  declared observation-safe by the task
;;;;             AND fdefinition is the identical object captured at setup
;;;;
;;;; This is not a general Lisp sandbox and does not try to be. It makes one
;;;; contract true: THIS SURFACE MAY ESTABLISH A FUNCTION DEFINITION BUT MAY NOT
;;;; EXECUTE IT, AND MAY NOT USE TOP-LEVEL EVALUATION AS A COVERT ACTION CHANNEL.

(in-package #:viva.inspect)

(defvar *callable* nil
  "Symbol -> the function object captured at setup, or NIL for unrestricted.

NIL keeps every task outside Experiment B working exactly as before. Bound to a
table, INSPECT_VALUE may call only these, and only while they are still the same
function.")

(defun capture-callables (package names)
  "Snapshot the observation-safe API. Called during setup, before the agent runs."
  (let ((table (make-hash-table)))
    (dolist (name names table)
      (let ((symbol (find-symbol (string-upcase (string name)) package)))
        (when (and symbol (fboundp symbol))
          (setf (gethash symbol table) (fdefinition symbol)))))))

(defun callable-check (symbol)
  "Signal unless SYMBOL may be invoked as an observation."
  (when *callable*
    (multiple-value-bind (original present) (gethash symbol *callable*)
      (cond ((not present)
             (error "~a is not an observation-safe function. This tool reads state ~
and calls the task's own read-only API; it does not run code you installed."
                    symbol))
            ((not (eq original (and (fboundp symbol) (fdefinition symbol))))
             ;; The name survived; the function did not.
             (error "~a has been redefined since this task started, so it is no ~
longer an observation." symbol))))))

;;; The constrained install
;;;
;;; DEFUN only. Everything else is either an execution channel or a way to get
;;; one, and each refusal below corresponds to a route that was actually tried
;;; or is one step from a route that was.

(defparameter +forbidden-operators+
  '(defparameter defvar defconstant progn eval-when setf setq
    locally macrolet symbol-macrolet let let* eval funcall apply)
  "Top-level operators that execute, or that trivially wrap something that does.")

(defun read-one-form (text)
  "Read exactly one form with *READ-EVAL* off, refusing anything left over.

Off because #.(anything) is read-time execution and would defeat every check
below before they run. Leftover text refused because two forms in one payload is
the oldest way to smuggle a second, unexamined action."
  (let ((*read-eval* nil))
    (multiple-value-bind (form position) (read-from-string text nil nil)
      (let ((rest (string-trim '(#\Space #\Tab #\Newline) (subseq text position))))
        (unless (zerop (length rest))
          (error "Exactly one definition per call. Found more after the first form.")))
      form)))

(defun check-definition (form)
  (unless (consp form)
    (error "Not a definition."))
  (let ((operator (first form)))
    (when (member operator +forbidden-operators+ :test #'string-equal)
      (error "~a is not allowed here. This tool establishes a FUNCTION ~
DEFINITION; it does not evaluate top-level forms, and an initializer would run ~
at install time." operator))
    (unless (string-equal operator 'defun)
      (error "Only DEFUN is accepted. Got ~a." operator)))
  form)

(tool:define-tool install-definition (args context)
  :description "Define a function in the running image. This DEFINES it only --
the body does not run until something calls it. One DEFUN per call; other
top-level forms are not accepted."
  :parameters (("source" :string "Exactly one DEFUN form" :required-p t)
               ("note" :string "One line saying what this is for" :required-p nil))
  (handler-case
      (progn
        (check-definition (read-one-form (gethash "source" args)))
        (viva.image-tools::report-installation
         (image:install-definition (viva.image-tools::backend)
                                   (gethash "source" args)
                                   :note (gethash "note" args))))
    (error (condition)
      (tool:make-tool-result :output (princ-to-string condition) :error-p t))))
