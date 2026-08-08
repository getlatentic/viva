;;;; The archive, and choosing what to breed from next.
;;;;
;;;; Two selection strategies, kept side by side because comparing them IS
;;;; experiment E2. Greedy keeps the best aggregate scorer. Pareto keeps every
;;;; candidate that wins on at least one case, even when its total is worse.
;;;;
;;;; GEPA's finding is the reason the second exists: always breeding from the
;;;; best aggregate scorer sticks in a local optimum, because once a dominant
;;;; strategy appears nothing else survives long enough to overtake it. The
;;;; frontier keeps candidates that are good at different things alive.
;;;;
;;;; Nothing here asks an agent whether its change worked. Results come from
;;;; TRIAL, which scores the image. A run earlier in this project produced a
;;;; fabricated REPL transcript as evidence of a fix -- the fix was real, the
;;;; evidence invented -- so self-reported success is not an input.

(in-package #:vivarium.arena)

(defclass archive ()
  ((results :initform '() :accessor archive-results)
   (counter :initform 0 :accessor %counter)))

(defun make-archive () (make-instance 'archive))

(defun admit (archive result)
  "Record RESULT. Crashed and timed-out trials are kept: knowing a direction is
dead is worth as much as knowing it is good, and dropping them would let the
same candidate be proposed forever."
  (push result (archive-results archive))
  (incf (%counter archive))
  result)

(defun scored (archive)
  (remove :ok (archive-results archive) :key #'trial:result-status :test-not #'eq))

(defun case-names (results)
  (remove-duplicates (loop for result in results
                           append (mapcar #'car (trial:result-scores result)))
                     :test #'equal))

(defun score-on (result case-name)
  "A candidate that failed a case scores negative infinity on it, so a candidate
that merely fails less does not win the case by default."
  (let ((entry (assoc case-name (trial:result-scores result) :test #'equal)))
    (or (and entry (cdr entry)) most-negative-double-float)))

;;; Greedy: one winner, by total

(defun best-by-total (archive)
  (let ((results (scored archive)))
    (when results
      (first (sort (copy-list results) #'> :key #'trial:result-total)))))

;;; Pareto: a frontier, by per-case wins

(defun winners-on (results case-name)
  "Every result tying for the best score on CASE-NAME. Ties all stay -- breaking
them arbitrarily would discard exactly the diversity the frontier is for."
  (let ((best (reduce #'max results :key (lambda (r) (score-on r case-name)))))
    (remove best results :key (lambda (r) (score-on r case-name)) :test-not #'=)))

(defun dominated-p (result others)
  "RESULT is dominated when some other result is at least as good on every case
and strictly better on one."
  (let ((cases (case-names (cons result others))))
    (some (lambda (other)
            (and (not (eq other result))
                 (every (lambda (c) (>= (score-on other c) (score-on result c))) cases)
                 (some (lambda (c) (> (score-on other c) (score-on result c))) cases)))
          others)))

(defun score-vector (result cases)
  (mapcar (lambda (case-name) (score-on result case-name)) cases))

(defun distinct-by-scores (results cases)
  "One representative per distinct score vector. Candidates the search cannot
tell apart should not each get a turn at being bred from."
  (remove-duplicates results :key (lambda (r) (score-vector r cases)) :test #'equal
                             :from-end t))

(defun frontier (archive)
  "The non-dominated set: every candidate that nothing else beats.

Not 'best on at least one case'. That definition looks equivalent and is not,
because it keeps every member of a tie. Measured on a landscape whose scores
floor at zero, it returned 81 candidates out of 81 trials -- the frontier
swallowed the archive and selection became random sampling. A candidate tied
everywhere carries no information the search can act on."
  (let* ((results (scored archive))
         (cases (case-names results))
         (distinct (distinct-by-scores results cases)))
    (remove-if (lambda (result) (dominated-p result distinct)) distinct)))


;;; Sampling

(defgeneric select-parent (strategy archive)
  (:documentation "Choose the candidate to derive the next trial from."))

(defmethod select-parent ((strategy (eql :greedy)) archive)
  (a:when-let ((best (best-by-total archive)))
    (trial:result-candidate best)))

(defmethod select-parent ((strategy (eql :pareto)) archive)
  "Round-robin over the frontier rather than random choice: the whole point is
that every distinct strength gets bred from, and sampling can starve one for a
long time by chance."
  (a:when-let ((front (frontier archive)))
    (trial:result-candidate (nth (mod (%counter archive) (length front)) front))))

;;; Crossover
;;;
;;; The claim under test: because a candidate is a set of ledger entries, joining
;;; two of them is a per-definition operation. Either a target appears in one
;;; parent, in which case it is taken, or in both, in which case the two sources
;;; are compared whole. There is no line-level merge and nothing to resolve
;;; inside a definition -- which is the one structural advantage an image-based
;;; search has over the file-and-git systems in this family.

(defun definition-table (candidate)
  (let ((table (make-hash-table :test #'equal)))
    (loop for (target . source) in (trial:candidate-definitions candidate)
          do (setf (gethash target table) source))
    table))

(defun conflicts-between (a b)
  "Targets both candidates define differently. Identical sources are not a
conflict: two lineages arriving at the same definition agree."
  (let ((left (definition-table a))
        (right (definition-table b))
        (found '()))
    (maphash (lambda (target source)
               (multiple-value-bind (other present) (gethash target right)
                 (when (and present (string/= source other))
                   (push target found))))
             left)
    (nreverse found)))

(defun merge-candidates (a b &key id (on-conflict :refuse))
  "Join two candidates. Returns (values candidate conflicts).

ON-CONFLICT :REFUSE returns NIL and the conflicting targets rather than picking a
winner silently -- a search that quietly drops half of one parent reports a merge
it did not perform. :PREFER-A and :PREFER-B resolve, and the caller owns that
choice."
  (let ((conflicts (conflicts-between a b)))
    (when (and conflicts (eq on-conflict :refuse))
      (return-from merge-candidates (values nil conflicts)))
    (let ((table (definition-table (if (eq on-conflict :prefer-b) a b))))
      (loop for (target . source) in (trial:candidate-definitions
                                      (if (eq on-conflict :prefer-b) b a))
            do (setf (gethash target table) source))
      (values (trial:make-candidate
               :id id
               :parent (list (trial:candidate-id a) (trial:candidate-id b))
               :definitions (loop for target being the hash-keys of table
                                    using (hash-value source)
                                  collect (cons target source)))
              conflicts))))

(defun complementary-pair (archive)
  "Two frontier members that lead different cases -- GEPA's system-aware merge.
Merging two candidates good at the same thing gains nothing."
  (let* ((results (scored archive))
         (cases (case-names results)))
    (loop for case-a in cases
          for leader-a = (first (winners-on results case-a))
          do (loop for case-b in cases
                   for leader-b = (first (winners-on results case-b))
                   unless (or (equal case-a case-b) (eq leader-a leader-b))
                     do (return-from complementary-pair
                          (values (trial:result-candidate leader-a)
                                  (trial:result-candidate leader-b)))))
    (values nil nil)))

(defun report (archive)
  "A line per case naming who leads it, plus the frontier size. Selection is
invisible otherwise, and a frontier that silently collapses to one member is a
greedy search wearing a different name."
  (let* ((results (scored archive))
         (cases (case-names results)))
    (with-output-to-string (out)
      (format out "~d trials, ~d scored, frontier ~d~%"
              (length (archive-results archive)) (length results) (length (frontier archive)))
      (dolist (case-name cases)
        (let ((leaders (winners-on results case-name)))
          (format out "  ~a: ~,3f by ~{~a~^, ~}~%"
                  case-name
                  (score-on (first leaders) case-name)
                  (mapcar (lambda (r) (trial:candidate-id (trial:result-candidate r))) leaders)))))))
