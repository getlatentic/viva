;;;; Family B: acquiring a capability mid-run.
;;;;
;;;; The one asymmetry that is a property of the harness rather than of the
;;;; task. Scored entirely from the image even so: a case checks that the
;;;; function exists, that a tool schema can be DERIVED from it, and that it
;;;; computes rather than remembers. Nothing here reads the agent's account of
;;;; what it did.
;;;;
;;;; KNOWN GAP, and it should not be overstated in the meantime. These cases see
;;;; a package and a backend, not the agent, so they check that a tool schema
;;;; COULD be read off the installed function -- not that the agent registered it
;;;; and called it. That is the property the family is named for, and reaching it
;;;; needs the agent object in scope, which is S6. Until then this family
;;;; measures writing a derivable function, which is real but weaker.
;;;;
;;;; Calibration found the first version of T9 unsolvable for both models, and it
;;;; was the task's fault twice over: the prompt never said what to NAME the
;;;; function the cases check, and it asked the agent to "call it" with a tool
;;;; set that has no way to call anything. Both models wrote a correct function
;;;; under a name of their own choosing and scored zero.

(in-package #:viva.tasks)

(defun derivable-p (package name)
  "Can a tool schema be read off the live function? This is the property that
makes an installed DEFUN a tool without a schema being authored, so it is the
thing worth scoring rather than whether some registry was touched."
  (let ((symbol (find-symbol (string name) package)))
    (and symbol (fboundp symbol)
         (ignore-errors (derive:derive-tool symbol)))))

;;; T9

(deftask :t9 (:family :b-capability :split :train :package "VIVA.TASK.T9")
  "Price the shipment described in *SHIPMENT*: a weight in kilograms and a
destination zone.

There is no function in this image that does it. Write one, called
SHIPPING-COST, taking a weight and a zone, and install it. Give it a docstring.

The rule: two units per kilogram, plus five for zone :B, plus nothing for zone
:A. Round to a whole number.

Check your work by reading the definition back, not by starting a new Lisp --
a fresh process has never heard of anything in this image."
  (lambda (backend package)
    (declare (ignore package))
    (service:install-all
     backend
     (list "(defparameter *shipment* (list :weight 7 :zone :b))"
           "(defparameter *quoted* nil)")))
  (lambda (package backend)
    (declare (ignore backend))
    (list (cons "function-exists"
                (lambda () (score (derivable-p package '#:shipping-cost))))
          (cons "schema-derivable"
                (lambda ()
                  (let ((tool (derivable-p package '#:shipping-cost)))
                    (score (and tool (plusp (length (viva.tool:tool-parameters tool))))))))
          (cons "answer-correct"
                (lambda ()
                  (let ((symbol (find-symbol "SHIPPING-COST" package)))
                    (score (and symbol (fboundp symbol)
                                (eql 19 (ignore-errors
                                         (funcall symbol 7 :b)))))))))))

;;; T10

(deftask :t10 (:family :b-capability :split :held-out :package "VIVA.TASK.T10")
  "How many events in *EVENTS* have a quantity of exactly nine?

*EVENTS* is far too large to read. Write a function COUNT-AT-QUANTITY that takes
a quantity and returns the count, give it a docstring, and install it.

It must compute the answer from *EVENTS* every time it is called, not return a
number you worked out once."
  (lambda (backend package)
    (service:install-all backend service:+event-substrate+)
    (service:build-events package))
  (lambda (package backend)
    (declare (ignore backend))
    (let* ((events (service:value-in package '#:*events*))
           (expected (loop for event across events
                           count (eql 9 (service:call-in package '#:event-qty event)))))
      (list (cons "function-exists"
                  (lambda () (score (derivable-p package '#:count-at-quantity))))
            (cons "count-correct"
                  (lambda ()
                    (score (eql expected
                                (ignore-errors
                                 (service:call-in package '#:count-at-quantity 9))))))
            (cons "computes-not-remembers"
                  ;; Append one more matching event and the answer must move. A
                  ;; function that returns a constant it was told passes the
                  ;; case above and fails this one.
                  (lambda ()
                    (let ((live (service:value-in package '#:*events*)))
                      (vector-push-extend
                       (service:call-in package '#:make-event :id -1 :kind :sale :qty 9 :price 1)
                       live)
                      (unwind-protect
                           (score (eql (1+ expected)
                                       (ignore-errors
                                        (service:call-in package '#:count-at-quantity 9))))
                        (decf (fill-pointer live))))))))))
