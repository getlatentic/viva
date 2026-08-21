;;;; A screen that writes only what changed.
;;;;
;;;; The naive full-screen loop clears and redraws everything every frame. It
;;;; is simple and it flickers, and over ssh or inside a multiplexer it is the
;;;; difference between an interface that feels alive and one that feels like a
;;;; slideshow -- a full 80x24 repaint is ~2KB per frame for a cursor that
;;;; moved one column.
;;;;
;;;; So: two buffers. Draw into one, compare against the other, and emit only
;;;; the runs that differ. The comparison is the entire feature; everything
;;;; else here is bookkeeping around it.

(in-package #:vivarium.tui)

(defstruct (screen (:conc-name screen-))
  (width 80 :type fixnum)
  (height 24 :type fixnum)
  (front nil)   ; what the terminal is showing
  (back nil))   ; what it should be showing

(defun blank-grid (width height)
  (let ((grid (make-array (list height width) :element-type 'character)))
    (dotimes (row height grid)
      (dotimes (column width)
        (setf (aref grid row column) #\Space)))))

(defun make-blank-screen (&key (width 80) (height 24))
  (make-screen :width width :height height
               :front (blank-grid width height)
               :back (blank-grid width height)))

(defun clear-back (screen)
  "Blank what is being drawn, without touching what is shown."
  (dotimes (row (screen-height screen))
    (dotimes (column (screen-width screen))
      (setf (aref (screen-back screen) row column) #\Space))))

(defun put (screen row column text)
  "Draw TEXT at ROW, COLUMN. Clipped, never wrapped.

Clipping rather than wrapping because a line that wraps has silently changed
the layout of everything below it, and a truncated line is a visible bug while
a shifted layout is a confusing one."
  (when (< -1 row (screen-height screen))
    (loop for character across (or text "")
          for at from column
          while (< at (screen-width screen))
          when (>= at 0)
            do (setf (aref (screen-back screen) row at) character))))

(defun screen-rows (screen &optional (which :back))
  "The buffer as a list of strings, for tests and for looking at.

Reading the grid rather than parsing the escape sequences a flush emits: what
is being asserted is what the frame SAYS, and a test that decodes cursor moves
to find out is testing the wrong layer twice."
  (let ((grid (ecase which (:back (screen-back screen)) (:front (screen-front screen)))))
    (loop for row below (screen-height screen)
          collect (let ((line (make-string (screen-width screen))))
                    (dotimes (column (screen-width screen) line)
                      (setf (char line column) (aref grid row column)))))))

(defun move-to (row column)
  (format nil "~c[~d;~dH" #\Escape (1+ row) (1+ column)))

(defun row-differences (screen row)
  "The runs in ROW that changed, as (START . TEXT).

Runs rather than cells: a cursor move costs about as many bytes as six
characters, so emitting one per changed cell is slower than redrawing the line.
A run ends when the buffers agree again."
  (let ((runs '()) (start nil) (piece (make-string-output-stream)))
    (dotimes (column (screen-width screen))
      (let ((new (aref (screen-back screen) row column))
            (old (aref (screen-front screen) row column)))
        (cond ((char/= new old)
               (unless start (setf start column))
               (write-char new piece))
              (start
               (push (cons start (get-output-stream-string piece)) runs)
               (setf start nil)))))
    (when start
      (push (cons start (get-output-stream-string piece)) runs))
    (nreverse runs)))

(defun flush (screen stream)
  "Emit what changed, and remember it as shown. Returns the bytes written.

The count is returned because it is the thing worth asserting: a frame in which
nothing changed must cost nothing, and that is a number, not an impression."
  (let ((written 0))
    (dotimes (row (screen-height screen))
      (dolist (run (row-differences screen row))
        (let ((text (format nil "~a~a" (move-to row (car run)) (cdr run))))
          (write-string text stream)
          (incf written (length text))))
      ;; Front becomes what was just drawn, one row at a time.
      (dotimes (column (screen-width screen))
        (setf (aref (screen-front screen) row column)
              (aref (screen-back screen) row column))))
    (finish-output stream)
    written))
