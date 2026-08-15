;;;; What went wrong, and what can coherently be done about it.
;;;;
;;;; Two different questions, answered at two different levels. The place where
;;;; something fails knows what happened and what continuations make sense; it
;;;; does not know whether retrying is affordable, whether this provider has
;;;; been flaky all morning, or whether a person is waiting. So a boundary
;;;; offers restarts and something further out chooses between them.
;;;;
;;;; The alternative -- catching the error where it happens and returning a
;;;; failure -- makes that choice at the only point in the program with the
;;;; least information about it, and throws away the stack that could have
;;;; continued. A long-lived organism wants the opposite: signal, let policy
;;;; decide, resume.
;;;;
;;;; This is deliberately three conditions and five restarts rather than a
;;;; hierarchy. The shapes have not repeated yet, and a taxonomy invented before
;;;; the second real case is a seam with nothing behind it.

(in-package #:vivarium.fault)

(define-condition vivarium-condition (condition) ()
  (:documentation "Something the organism may be able to recover from.

Policy binds this, not ERROR: an ordinary bug should reach the containment
boundary and end the turn, not be silently retried into a loop.

Deliberately not an ERROR itself. Whether a fault is one is a statement about
what happens if nobody handles it, and the two here differ: an unreachable
model ends the turn, an unusable tool becomes the tool's result and the run
carries on. Making them both errors put TOOL-UNUSABLE in reach of every outer
HANDLER-CASE for ERROR -- the test suite's included -- which turned a signal
whose point is that execution continues into a failure."))

(define-condition model-unavailable (vivarium-condition error)
  ((model :initarg :model :initform nil :reader faulted-model)
   (attempt :initarg :attempt :initform 1 :reader fault-attempt)
   (cause :initarg :cause :initform nil :reader fault-cause))
  (:report (lambda (condition stream)
             (format stream "The model ~a could not be reached (attempt ~d): ~a"
                     (faulted-model condition) (fault-attempt condition)
                     (fault-cause condition)))))

;;; Not an ERROR: the default is to carry on with the failure as the result.
(define-condition tool-unusable (vivarium-condition)
  ((tool :initarg :tool :initform nil :reader faulted-tool)
   (cause :initarg :cause :initform nil :reader fault-cause))
  (:report (lambda (condition stream)
             (format stream "The tool ~a signalled: ~a"
                     (faulted-tool condition) (fault-cause condition)))))

;;; Choosing a restart
;;;
;;; Named functions rather than FIND-RESTART at every call site, so a policy
;;; reads as a decision -- (retry condition) -- and so a restart that is not
;;; established is a quiet decline rather than a second error raised while
;;; handling the first.

(defmacro define-choice (name lambda-list &body forwarded)
  `(defun ,name (,@lambda-list &optional condition)
     (a:when-let ((restart (find-restart ',name condition)))
       (invoke-restart restart ,@forwarded))))

(define-choice retry ())
(define-choice use-model (name) name)
(define-choice use-result (text) text)
(define-choice abort-turn ())
