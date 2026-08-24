;;;; Borders, tabs, and the marks that say what a session is doing.
;;;;
;;;; Separated from PAINT because it is decoration and paint is arrangement.
;;;; A box that knows what is inside it, or a session list that knows how a
;;;; session list is laid out, is the file that grows a section per pane kind.
;;;;
;;;; THE STATE MARKS ARE NOT DECORATION, though they look like it. herdr
;;;; regex-matches a braille spinner against a scraped screen to guess that an
;;;; agent is working, then debounces the guess three times because scraping is
;;;; noisy. Our states are :idle :working :suspended :stopping :stuck, from a
;;;; machine with a proof in spec/CellLifecycle.tla. Drawing a dot from that is
;;;; the cheapest possible demonstration of the difference.

(in-package #:viva.tui)

(defparameter *border-style* (make-style :foreground 240)
  "Grey. A border is furniture: it should bound the eye without catching it.")

(defparameter *focus-style* (make-style :foreground 13 :bold t)
  "The focused pane's border. One thing on screen is brighter than the rest,
and it is the thing keystrokes will reach.")

(defparameter *title-style* (make-style :foreground 252 :bold t))
(defparameter *dim-style* (make-style :foreground 244))

(defparameter +state-marks+
  '((:working  "*" 220)   ; amber, the colour of something in flight
    (:stuck    "!" 203)   ; red -- herdr calls this blocked, and guesses it
    (:suspended "~" 111)
    (:stopping "." 244)
    (:idle     "-" 240))
  "A mark and a 256-colour index per cell state. ASCII rather than dots,
because a terminal without the font renders U+25CF as a replacement box and a
status column of tofu is worse than no status column.")

(defun state-mark (state)
  "(MARK . STYLE) for a session state named by keyword or string."
  (let* ((key (if (keywordp state)
                  state
                  (intern (string-upcase (or state "idle")) :keyword)))
         (found (or (assoc key +state-marks+) (assoc :idle +state-marks+))))
    (cons (second found) (make-style :foreground (third found) :bold (eq key :working)))))

(defun short-label (label)
  "The last path component of LABEL, or LABEL when it is not a path.

A session's label defaults to its working directory, and a sidebar is twenty
columns wide -- so four sessions in four sibling directories all rendered as
`/Users/dev/works` and the list said nothing at all."
  (let* ((text (string-right-trim "/" (or label "")))
         (slash (position #\/ text :from-end t)))
    (if (and slash (< (1+ slash) (length text)))
        (subseq text (1+ slash))
        text)))

;;; Boxes

(defparameter +box+ '(:top-left "." :top-right "." :bottom-left "'" :bottom-right "'"
                      :horizontal "-" :vertical "|")
  "ASCII by default. Box-drawing characters are prettier and they are also the
first thing to break over a serial console, in a font without them, or under a
terminal whose width calculation disagrees about them -- and a broken border
corrupts every row it touches.")

(defparameter +rounded+ '(:top-left "╭" :top-right "╮" :bottom-left "╰" :bottom-right "╯"
                          :horizontal "─" :vertical "│"))

(defparameter *box-characters* +rounded+
  "Rounded by default; +BOX+ is the fallback for a terminal that cannot.")

(defun box-part (name) (getf *box-characters* name))

(defun draw-box (screen region &key title focused)
  "Draw a border inside REGION and return the region it encloses.

Returns the INNER region rather than drawing into REGION directly, so a caller
cannot forget to account for the border and write over it -- which is the bug
this shape exists to make impossible."
  (let ((width (region-width region))
        (height (region-height region))
        (style (if focused *focus-style* *border-style*)))
    (when (and (> width 1) (> height 1))
      (let* ((rule (with-output-to-string (out)
                     (dotimes (n (- width 2)) (write-string (box-part :horizontal) out))))
             (top (format nil "~a~a~a" (box-part :top-left) rule (box-part :top-right)))
             (bottom (format nil "~a~a~a" (box-part :bottom-left) rule (box-part :bottom-right))))
        (draw-in screen region 0 top :style style)
        (draw-in screen region (1- height) bottom :style style)
        (loop for row from 1 below (1- height)
              do (draw-in screen region row (box-part :vertical) :style style)
                 (put screen (+ (region-row region) row)
                      (+ (region-column region) width -1)
                      (box-part :vertical) :style style))
        ;; The title sits IN the top border, which is where a title costs no row.
        (when (and title (< (+ 4 (length title)) width))
          (put screen (region-row region) (+ (region-column region) 2)
               (format nil " ~a " title) :style *title-style*))))
    (make-region :name (region-name region)
                 :row (1+ (region-row region))
                 :column (1+ (region-column region))
                 :width (max 0 (- width 2))
                 :height (max 0 (- height 2)))))

;;; The tab bar

(defun draw-tabs (screen region tabs active)
  "One row of tab names, the active one lit. Returns (NAME START END) per tab.

The ranges are RETURNED rather than recomputed by whoever handles a click.
Two functions deriving the same layout independently is how a tab bar ends up
selecting the tab next to the one that was clicked, and the drift is invisible
until somebody renames a tab."
  (let ((column 1) (ranges '()))
    (loop for name in tabs
          for index from 0
          for text = (format nil " ~a " name)
          while (< (+ column (length text)) (region-width region))
          do (put screen (region-row region) (+ (region-column region) column) text
                  :style (if (eql index active)
                             (make-style :foreground 232 :background 13 :bold t)
                             *dim-style*))
             (push (list name column (+ column (length text))) ranges)
             (incf column (length text))
             (when (< (+ column 3) (region-width region))
               (put screen (region-row region) (+ (region-column region) column) "|"
                    :style *border-style*)
               (incf column 1)))
    ;; `+` is a target like any other tab, and reported the same way. It was
    ;; drawn and not reported, so clicking it did nothing and looked broken.
    (when (< (+ column 3) (region-width region))
      (put screen (region-row region) (+ (region-column region) column 1) " + "
           :style *dim-style*)
      (push (list :new (1+ column) (+ column 4)) ranges))
    (nreverse ranges)))
