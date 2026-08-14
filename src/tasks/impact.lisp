;;;; Family E: the repair depends on knowing what the change already touched.
;;;;
;;;; Every episode in this family shares ONE information operation -- start from
;;;; a definition and enumerate the live things that depend on it and the values
;;;; they already produced -- while the repair itself differs each time. That is
;;;; what makes a reusable capability possible without making it an answer key.
;;;;
;;;; E24 IS THE REPRESENTATIVE REPAIR, written for B14.1's three gates rather
;;;; than for the sequence. It is E3-shaped on purpose: THE SOURCE READS
;;;; CORRECTLY. An agent that only reads definitions sees a consistent, sensible
;;;; pipeline and has no way to discover that anything is wrong, because the
;;;; defect is entirely in values computed by a version that no longer exists.
;;;; So it is the sharpest test that INSPECT_VALUE is load-bearing rather than
;;;; decorative.
;;;;
;;;; THE FOUR CONSTRAINTS FROM THE PRE-REGISTRATION, and each is a design rule
;;;; here rather than a hope:
;;;;
;;;;   SOLVABLE WITHOUT THE ORACLE   every fact needed is reachable one
;;;;                                 inspect_value call at a time
;;;;   EXPENSIVE                     the facts are spread across four different
;;;;                                 live locations, so they cannot be had in
;;;;                                 one look
;;;;   NOT MANDATORY                 nothing here requires a capability that
;;;;                                 does not exist; it requires patience
;;;;   NO ANSWER KEY                 a tool that enumerates dependents does not
;;;;                                 know which ones are stale, and cannot fix
;;;;                                 any of them

(in-package #:vivarium.tasks)

;;; E24 -- a cache holding values from a formula that has already been replaced
;;;
;;; SHIPPING-COST was corrected at some point. *QUOTES* holds 400 quotes, each
;;; carrying a cost computed when it was created -- some before the correction,
;;; some after. Reading SHIPPING-COST shows the CURRENT, CORRECT formula. The
;;; stale quotes are only visible by comparing a stored cost against what the
;;; live function returns for the same inputs, one quote at a time.
;;;
;;; The repair is not "fix SHIPPING-COST" -- it is already right. It is to
;;; recompute exactly the affected quotes and leave the rest alone, which is why
;;; knowing WHICH ones is the whole job.

;;; THE FIRST VERSION OF THIS TASK WAS SOLVED BY A BLANKET RECOMPUTE, verified
;;; before spending anything on it: recomputing every stored cost from the live
;;; function took the scoring case from 0.0 to 1.0. That is a task with no
;;; impact-discovery bottleneck at all -- the agent never has to learn WHICH
;;; quotes are stale, so it would have failed Gate 2 for a reason belonging to
;;; the design rather than to the world.
;;;
;;; The fix is a third population. *NEGOTIATED* holds agreed prices that
;;; deliberately disagree with the formula and must survive untouched. Now two
;;; different sets of quotes disagree with SHIPPING-COST for two opposite
;;; reasons, telling them apart requires a SECOND live location, and a blanket
;;; recompute destroys the negotiated ones.

(deftask :e24 (:family :e-impact :split :train :package "VIVARIUM.TASK.E24")
  "Some quotes in *QUOTES* report a shipping cost that disagrees with what
SHIPPING-COST computes for them today. Not all of those are wrong.

*QUOTES* holds 400 quotes. Each is a plist with :ID, :WEIGHT, :ZONE and :COST,
where :COST was stored when the quote was made. QUOTE-TOTAL sums them.

Correct the ones that are stale, and leave everything else exactly as it is."
  (lambda (backend package)
    (declare (ignore package))
    (service:install-all
     backend
     (list
      "(defparameter *negotiated*
  (let ((table (make-hash-table)))
    (dotimes (i 400 table)
      (when (zerop (mod i 17))
        (setf (gethash i table) 99)))))"
      ;; :REMOTE quotes that are not negotiated carry a cost from the superseded
      ;; formula. Negotiated quotes carry their agreed price, in both zones.
      ;; Nothing in the source says either thing.
      "(defparameter *quotes*
  (let ((out '()))
    (dotimes (i 400 (nreverse out))
      (let* ((weight (+ 1 (mod i 9)))
             (zone (if (zerop (mod i 4)) :remote :standard))
             (agreed (gethash i *negotiated*))
             ;; The superseded formula charged the surcharge once per kilo. The
             ;; current one charges it once per shipment.
             (cost (or agreed
                       (if (eq zone :remote)
                           (+ (* weight 3) (* weight 12))
                           (* weight 3)))))
        (push (list :id i :weight weight :zone zone :cost cost) out)))))"
      "(defun zone-surcharge (zone) (if (eq zone :remote) 12 0))"
      "(defun shipping-cost (weight zone)
  (+ (* weight 3) (zone-surcharge zone)))"
      "(defun quote-cost (quote) (getf quote :cost))"
      "(defun quote-total () (reduce #'+ *quotes* :key #'quote-cost :initial-value 0))")))
  (lambda (package backend)
    (declare (ignore backend))
    (flet ((try (name &rest arguments)
             (ignore-errors (apply #'service:call-in package name arguments))))
      (let* ((quotes (service:value-in package '#:*quotes*))
             (negotiated (service:value-in package '#:*negotiated*))
             (agreed (lambda (q) (gethash (getf q :id) negotiated)))
             (correct (lambda (q)
                        (or (funcall agreed q)
                            (+ (* (getf q :weight) 3)
                               (if (eq (getf q :zone) :remote) 12 0)))))
             (expected (reduce #'+ quotes :key correct :initial-value 0))
             (current (lambda (id)
                        (a:when-let ((q (find id (service:value-in package '#:*quotes*)
                                              :key (lambda (x) (getf x :id)))))
                          (getf q :cost)))))
        (list
         (cons "stale-quotes-recomputed"
               ;; Every quote that is NOT negotiated must now agree with
               ;; SHIPPING-COST for its own weight and zone.
               (lambda ()
                 (score (every (lambda (q)
                                 (or (funcall agreed q)
                                     (eql (funcall current (getf q :id)) (funcall correct q))))
                               quotes))))
         (cons "negotiated-quotes-preserved"
               ;; The case a blanket recompute fails. These disagree with the
               ;; formula on purpose, and the only way to know that is to have
               ;; looked at *NEGOTIATED*.
               (lambda ()
                 (score (every (lambda (q)
                                 (or (not (funcall agreed q))
                                     (eql (funcall current (getf q :id)) (funcall agreed q))))
                               quotes))))
         (cons "fresh-quotes-untouched"
               (lambda ()
                 (score (every (lambda (before)
                                 (or (eq (getf before :zone) :remote)
                                     (funcall agreed before)
                                     (eql (funcall current (getf before :id))
                                          (getf before :cost))))
                               quotes))))
         (cons "total-correct"
               (lambda () (score (eql expected (try '#:quote-total)))))
         (cons "formula-untouched"
               ;; SHIPPING-COST was already correct. An agent that "fixes" it to
               ;; match the stale data has inverted the task.
               (lambda ()
                 (score (and (eql 27 (try '#:shipping-cost 5 :remote))
                             (eql 15 (try '#:shipping-cost 5 :standard))
                             (eql 12 (try '#:zone-surcharge :remote))
                             (eql 0 (try '#:zone-surcharge :standard))))))
         (cons "quotes-intact"
               (lambda ()
                 (let ((now (service:value-in package '#:*quotes*)))
                   (score (and (eql 400 (length now))
                               (every (lambda (q) (getf q :weight)) now)))))))))))
