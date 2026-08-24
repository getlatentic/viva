;;;; Dividing a screen into regions that exactly tile it.
;;;;
;;;; A layout is a tree: `:stack` puts children one above another, `:beside`
;;;; puts them side by side, and a leaf is a name. Each child is either
;;;; `(:fixed n ...)` -- give it exactly n rows or columns -- or
;;;; `(:weight n ...)` -- share what is left in proportion to n.
;;;;
;;;; The whole difficulty is the remainder. Three panes sharing 80 columns get
;;;; 26 each and lose two, and a layout that silently drops two columns is the
;;;; blank stripe every hand-rolled TUI has down its right edge. So the leftover
;;;; is handed out one unit at a time to the widest-weighted children until it
;;;; is gone, and the property worth testing is exactness: the regions tile the
;;;; area with no gap and no overlap, at every size.

(in-package #:vivarium.tui)

(defstruct (region (:conc-name region-))
  (name nil)
  (row 0 :type fixnum)
  (column 0 :type fixnum)
  (width 0 :type fixnum)
  (height 0 :type fixnum))

(defun child-fixed-p (child) (eq (first child) :fixed))
(defun child-size (child) (second child))
(defun child-body (child) (cddr child))

(defun shares (children total)
  "How much of TOTAL each child gets, summing to exactly TOTAL.

Fixed children are served first, clamped so an over-subscribed layout starves
the last panes rather than handing anybody a negative size. What remains is
split by weight, and the rounding leftover goes one unit at a time to the
heaviest children -- deterministic, so the same layout never jitters between
frames."
  (let* ((sizes (make-list (length children) :initial-element 0))
         (left total))
    ;; Fixed first, clamped to what is actually there.
    (loop for child in children
          for index from 0
          when (child-fixed-p child)
            do (let ((want (max 0 (min (child-size child) left))))
                 (setf (nth index sizes) want)
                 (decf left want)))
    ;; Then weights, by integer share.
    (let* ((weighted (loop for child in children
                           for index from 0
                           unless (child-fixed-p child)
                             collect (cons index (max 0 (child-size child)))))
           (weight (reduce #'+ weighted :key #'cdr :initial-value 0)))
      (when (plusp weight)
        (let ((given 0))
          (loop for (index . share) in weighted
                do (let ((size (floor (* left share) weight)))
                     (setf (nth index sizes) size)
                     (incf given size)))
          ;; The leftover, one unit each to the heaviest, largest weight first.
          (let ((order (sort (copy-list weighted) #'> :key #'cdr)))
            (loop repeat (- left given)
                  for cycle = order then (or (rest cycle) order)
                  do (incf (nth (car (first cycle)) sizes)))))))
    sizes))

(defun leaf-p (form) (not (consp form)))

(defun lay-out (form row column width height)
  "Regions for FORM inside the given box, as a list."
  (cond ((leaf-p form)
         (list (make-region :name form :row row :column column
                            :width (max 0 width) :height (max 0 height))))
        ((member (first form) '(:stack :beside))
         (let* ((children (rest form))
                (down (eq (first form) :stack))
                (sizes (shares children (if down height width))))
           (loop for child in children
                 for size in sizes
                 for offset = 0 then (+ offset previous)
                 for previous = size
                 append (let ((body (child-body child)))
                          (lay-out (if (rest body) (cons :stack body) (first body))
                                   (if down (+ row offset) row)
                                   (if down column (+ column offset))
                                   (if down width size)
                                   (if down size height))))))
        (t (error "not a layout: ~s" form))))

(defun divide (form &key (width 80) (height 24))
  "Regions for FORM over a WIDTH x HEIGHT area, as an alist of name to region."
  (loop for region in (lay-out form 0 0 width height)
        collect (cons (region-name region) region)))

(defun region-of (regions name)
  (or (cdr (assoc name regions))
      (error "no region named ~s" name)))

(defun draw-in (screen region row text &key style (column 0))
  "Draw TEXT at ROW, COLUMN of REGION, clipped to the region not the screen.

Clipping to the region is what stops one pane's long line bleeding into its
neighbour, which is the only reason panes look like panes.

COLUMN exists because the alternative is padding the text with spaces to move
it right, and those spaces are opaque: they overwrite whatever was already
drawn to their left. A session row drawn as `>`, then a state mark, then a
padded name from column zero, silently erased the first two -- so the sidebar
showed neither which session was current nor what any of them were doing, and
looked exactly like a row that had simply not been written.

The padding is not the only thing this comment has cost. Written with the
padded name in double quotes, that quote ENDED THE DOCSTRING: what followed
parsed as a free reference to NAME and a stray string, so the body began by
reading an unbound variable. The compiler said so on every build and the
warning went unread. Whether it then SIGNALS depends on the compiler: here the
unused read is elided and the suite passes, and on CI it raised and took four
tests with it. A warning nobody reads is the same as no warning."
  (when (< -1 row (region-height region))
    (let* ((line (or text ""))
           (room (- (region-width region) column)))
      (when (plusp room)
        (put screen (+ (region-row region) row) (+ (region-column region) column)
             (if (> (length line) room) (subseq line 0 room) line)
             :style style)))))

(defun within-p (region row column)
  (and (<= (region-row region) row)
       (< row (+ (region-row region) (region-height region)))
       (<= (region-column region) column)
       (< column (+ (region-column region) (region-width region)))))

(defun region-at (regions row column)
  "Which region holds ROW, COLUMN -- as (NAME . REGION), or NIL.

The regions tile exactly, so at most one can match and a miss means the click
landed outside the area entirely. That is only true because DIVIDE leaves no
gaps; hit-testing is the first thing to break when a layout does."
  (find-if (lambda (entry) (within-p (cdr entry) row column)) regions))
