;;;; Exact-replacement editing, and the diff that shows what happened.
;;;;
;;;; Three rules, all of them there because the alternative fails silently:
;;;;
;;;;   Every OLD must occur exactly once in the file. Zero is a mistake the
;;;;   model can fix by reading first; more than one is a mistake it cannot even
;;;;   see, because it edited a line it never looked at.
;;;;
;;;;   Every OLD is matched against the ORIGINAL text, never against the result
;;;;   of the previous edit. Otherwise the meaning of a batch depends on the
;;;;   order the model happened to list it in.
;;;;
;;;;   Edits may not overlap. Two replacements over the same region have no
;;;;   defined answer, and picking one quietly is how a file loses a line.
;;;;
;;;; The diff is computed from the replacement sites rather than by comparing
;;;; the two texts. Nothing here needs to *discover* what changed -- it is
;;;; already known exactly -- and a real diff algorithm would re-derive it,
;;;; approximately, at more cost.

(in-package #:viva.edit)

(define-condition edit-failure (error)
  ((detail :initarg :detail :reader edit-failure-detail))
  (:report (lambda (condition stream)
             (write-string (edit-failure-detail condition) stream))))

(defun fail (format &rest arguments)
  (error 'edit-failure :detail (apply #'format nil format arguments)))

;;; Line endings and BOM, preserved rather than normalised away

(defun line-ending-of (text)
  (if (search (format nil "~c~c" #\Return #\Newline) text) :crlf :lf))

(defun normalize-endings (text)
  (remove #\Return text))

(defun restore-endings (text ending)
  (if (eq :crlf ending)
      (with-output-to-string (out)
        (loop for character across text
              do (when (char= #\Newline character) (write-char #\Return out))
                 (write-char character out)))
      text))

;;; Placing the edits

(defstruct (placement (:conc-name placement-))
  (start 0 :type integer)
  (end 0 :type integer)
  (replacement "" :type string))

(defun occurrences (text needle)
  (loop with start = 0
        for found = (search needle text :start2 start)
        while found
        collect found
        do (setf start (1+ found))))

(defun locate (text old new index)
  (when (zerop (length old))
    (fail "Edit ~d has an empty target. Name the text to replace." (1+ index)))
  (let ((found (occurrences text old)))
    (cond ((null found)
           (fail "Edit ~d did not match. This text is not in the file:~%~a~%~
Read the file and copy the target exactly, including indentation."
                 (1+ index) (excerpt old)))
          ((rest found)
           (fail "Edit ~d matches ~d places, so there is no way to tell which ~
one you meant. Extend it with surrounding lines until it is unique:~%~a"
                 (1+ index) (length found) (excerpt old)))
          (t (make-placement :start (first found)
                             :end (+ (first found) (length old))
                             :replacement new)))))

(defun excerpt (text &key (lines 6))
  (let ((split (uiop:split-string text :separator (string #\Newline))))
    (format nil "~{  ~a~%~}~@[  ...~%~]"
            (subseq split 0 (min lines (length split)))
            (> (length split) lines))))

(defun check-disjoint (placements)
  (loop for (earlier later) on placements
        while later
        do (when (> (placement-end earlier) (placement-start later))
             (fail "Two edits cover the same region of the file. Merge them ~
into one edit that spans the whole block."))))

(defun apply-edits (text edits)
  "EDITS is a list of (OLD . NEW). Returns the new text.
Signals EDIT-FAILURE with a message written for the model that made the call."
  (when (null edits)
    (fail "No edits given."))
  (let ((placements (sort (loop for (old . new) in edits
                                for index from 0
                                collect (locate text old new index))
                          #'< :key #'placement-start)))
    (check-disjoint placements)
    (values (with-output-to-string (out)
              (let ((cursor 0))
                (dolist (placement placements)
                  (write-string text out :start cursor :end (placement-start placement))
                  (write-string (placement-replacement placement) out)
                  (setf cursor (placement-end placement)))
                (write-string text out :start cursor)))
            placements)))

;;; The diff

(defun line-start (text offset)
  (a:if-let ((newline (position #\Newline text :end offset :from-end t)))
    (1+ newline)
    0))

(defun line-end (text offset)
  (or (position #\Newline text :start (min offset (length text))) (length text)))

(defun line-number (text offset)
  (1+ (count #\Newline text :end offset)))

(defun split-lines (text)
  (uiop:split-string text :separator (string #\Newline)))

(defstruct (change (:conc-name change-))
  (line 1 :type integer) (old '() :type list) (new '() :type list))

(defun placement-change (text placement)
  "One replacement, widened to whole lines so it can be shown as a diff."
  (let ((from (line-start text (placement-start placement)))
        (to (line-end text (placement-end placement))))
    (make-change :line (line-number text from)
                 :old (split-lines (subseq text from to))
                 :new (split-lines (concatenate 'string
                                                (subseq text from (placement-start placement))
                                                (placement-replacement placement)
                                                (subseq text (placement-end placement) to))))))

(defun group-changes (changes context)
  "Changes whose context windows touch belong in one hunk.

Emitting them separately produces a diff that prints the same lines twice and
shows an already-replaced line as unchanged context in the next hunk -- which is
not a cosmetic problem, because the second hunk then contradicts the first."
  (let ((groups '()) (current '()))
    (dolist (change changes)
      (let ((previous (first current)))
        (if (and previous
                 (> (- (change-line change)
                       (+ (change-line previous) (length (change-old previous))))
                    (* 2 context)))
            (progn (push (nreverse current) groups)
                   (setf current (list change)))
            (push change current))))
    (when current (push (nreverse current) groups))
    (nreverse groups)))

(defun render-group (out lines group context delta)
  "Write one hunk. Returns how much it shifts the line numbers after it."
  (let* ((first-change (first group))
         (last-change (first (last group)))
         (from (max 1 (- (change-line first-change) context)))
         (to (min (length lines)
                  (+ (change-line last-change) (length (change-old last-change)) context -1)))
         (old-count (1+ (- to from)))
         (shift (reduce #'+ group :initial-value 0
                                  :key (lambda (change)
                                         (- (length (change-new change))
                                            (length (change-old change))))))
         (line from))
    (format out "@@ -~d,~d +~d,~d @@~%" from old-count (+ from delta) (+ old-count shift))
    (dolist (change group)
      (loop while (< line (change-line change))
            do (format out " ~a~%" (aref lines (1- line)))
               (incf line))
      (dolist (text (change-old change)) (format out "-~a~%" text))
      (dolist (text (change-new change)) (format out "+~a~%" text))
      (incf line (length (change-old change))))
    (loop while (<= line to)
          do (format out " ~a~%" (aref lines (1- line)))
             (incf line))
    shift))

(defun unified-diff (path text placements &key (context 3))
  "A unified diff of the edits PLACEMENTS make to TEXT."
  (let ((lines (coerce (split-lines text) 'vector))
        (changes (mapcar (lambda (placement) (placement-change text placement)) placements)))
    (with-output-to-string (out)
      (format out "--- ~a~%+++ ~a~%" path path)
      (let ((delta 0))
        (dolist (group (group-changes changes context))
          (incf delta (render-group out lines group context delta)))))))
