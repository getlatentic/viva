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

(in-package #:viva.tui)

(defstruct (style (:conc-name style-))
  (foreground nil)   ; a keyword like :cyan, or 0-255, or NIL for the default
  (background nil)
  (bold nil)
  (dim nil))

(defparameter +colours+
  '((:black . 0) (:red . 1) (:green . 2) (:yellow . 3)
    (:blue . 4) (:magenta . 5) (:cyan . 6) (:white . 7))
  "The eight every terminal has had since before anybody agreed on the rest.
An integer is passed through as a 256-colour index instead.")

(defun sgr (style)
  "The escape sequence that turns STYLE on, or the reset when it is NIL.

Emitted per run rather than per cell. A cell-by-cell attribute write costs more
than the text it decorates, which is the same trap the run-based diff exists to
avoid -- so style is part of what defines a run, not something layered over it."
  (if (null style)
      (format nil "~c[0m" #\Escape)
      (let ((codes '("0")))
        (when (style-bold style) (push "1" codes))
        (when (style-dim style) (push "2" codes))
        (a:when-let ((foreground (style-foreground style)))
          (push (if (integerp foreground)
                    (format nil "38;5;~d" foreground)
                    (format nil "~d" (+ 30 (cdr (assoc foreground +colours+)))))
                codes))
        (a:when-let ((background (style-background style)))
          (push (if (integerp background)
                    (format nil "48;5;~d" background)
                    (format nil "~d" (+ 40 (cdr (assoc background +colours+)))))
                codes))
        (format nil "~c[~{~a~^;~}m" #\Escape (nreverse codes)))))

(defstruct (screen (:conc-name screen-))
  (width 80 :type fixnum)
  (height 24 :type fixnum)
  (front nil)          ; what the terminal is showing
  (back nil)           ; what it should be showing
  (front-styles nil)   ; and the attributes of each, in step with them
  (back-styles nil)
  ;; INVARIANT: if the front buffer was discarded, the physical terminal must
  ;; be invalidated too. A fresh front buffer claims the terminal is blank; if
  ;; it is not, every stale cell survives forever, because the diff sees no
  ;; difference between "blank here" and "blank here". That is two frames on
  ;; screen at once, and it is what a resize looked like.
  ;;
  ;; The flag lives on the SCREEN rather than at the call site that resized.
  ;; Making resize remember to clear works exactly until something else
  ;; recreates a buffer -- a theme change, a reconnect, a detach and reattach --
  ;; and then the same bug returns wearing a different hat.
  (invalid t :type boolean))

(defun blank-grid (width height)
  (let ((grid (make-array (list height width) :element-type 'character)))
    (dotimes (row height grid)
      (dotimes (column width)
        (setf (aref grid row column) #\Space)))))

(defun blank-styles (width height)
  (make-array (list height width) :initial-element nil))

(defun make-blank-screen (&key (width 80) (height 24))
  (make-screen :width width :height height
               :front (blank-grid width height)
               :back (blank-grid width height)
               :front-styles (blank-styles width height)
               :back-styles (blank-styles width height)))

(defun clear-back (screen)
  "Blank what is being drawn, without touching what is shown."
  (dotimes (row (screen-height screen))
    (dotimes (column (screen-width screen))
      (setf (aref (screen-back screen) row column) #\Space
            (aref (screen-back-styles screen) row column) nil))))

(defun put (screen row column text &key style)
  "Draw TEXT at ROW, COLUMN in STYLE. Clipped, never wrapped.

Clipping rather than wrapping because a line that wraps has silently changed
the layout of everything below it, and a truncated line is a visible bug while
a shifted layout is a confusing one."
  (when (< -1 row (screen-height screen))
    (loop for character across (or text "")
          for at from column
          while (< at (screen-width screen))
          when (>= at 0)
            do (setf (aref (screen-back screen) row at) character
                     (aref (screen-back-styles screen) row at) style))))

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

(defun style-at (screen row column &optional (which :back))
  "The style of one cell, so a colour claim can be asserted rather than looked at."
  (let ((grid (ecase which (:back (screen-back-styles screen))
                           (:front (screen-front-styles screen)))))
    (and (< -1 row (screen-height screen)) (< -1 column (screen-width screen))
         (aref grid row column))))

(defun move-to (row column)
  (format nil "~c[~d;~dH" #\Escape (1+ row) (1+ column)))

(defun row-differences (screen row)
  "The runs in ROW that changed, as (START STYLE . TEXT).

Runs rather than cells: a cursor move costs about as many bytes as six
characters, so emitting one per changed cell is slower than redrawing the line.
A run ends when the buffers agree again, OR when the style changes -- because
one escape sequence decorates a whole run, and a run of mixed styles would need
one per cell, which is the cost this exists to avoid."
  (let ((runs '()) (start nil) (style nil) (piece (make-string-output-stream)))
    (flet ((close-run ()
             (when start
               (push (list* start style (get-output-stream-string piece)) runs)
               (setf start nil))))
      (dotimes (column (screen-width screen))
        (let ((new (aref (screen-back screen) row column))
              (old (aref (screen-front screen) row column))
              (new-style (aref (screen-back-styles screen) row column))
              (old-style (aref (screen-front-styles screen) row column)))
          (cond ((or (char/= new old) (not (equalp new-style old-style)))
                 (unless (and start (equalp style new-style)) (close-run))
                 (unless start (setf start column style new-style))
                 (write-char new piece))
                (t (close-run)))))
      (close-run))
    (nreverse runs)))

(defparameter +erase-all+ (format nil "~c[2J" #\Escape))

(defun invalidate (screen)
  "Declare that the terminal no longer shows what the front buffer claims."
  (setf (screen-invalid screen) t)
  screen)

(defun flush (screen stream)
  "Emit what changed, and remember it as shown. Returns the bytes written.

The count is returned because it is the thing worth asserting: a frame in which
nothing changed must cost nothing, and that is a number, not an impression."
  (let ((written 0))
    ;; The invalidation is discharged HERE, where the terminal is actually
    ;; written to, so no caller can hold a fresh buffer and forget to clear.
    (when (screen-invalid screen)
      (write-string +erase-all+ stream)
      (incf written (length +erase-all+))
      (setf (screen-invalid screen) nil))
    (dotimes (row (screen-height screen))
      (dolist (run (row-differences screen row))
        (destructuring-bind (start style . body) run
          (let ((text (if style
                          (format nil "~a~a~a~a" (move-to row start) (sgr style) body (sgr nil))
                          (format nil "~a~a" (move-to row start) body))))
            (write-string text stream)
            (incf written (length text)))))
      ;; Front becomes what was just drawn, one row at a time.
      (dotimes (column (screen-width screen))
        (setf (aref (screen-front screen) row column)
              (aref (screen-back screen) row column)
              (aref (screen-front-styles screen) row column)
              (aref (screen-back-styles screen) row column))))
    (finish-output stream)
    written))
