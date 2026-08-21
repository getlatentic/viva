;;;; Drawing a view onto a screen.
;;;;
;;;; Deterministic and I/O-free, for the same reason the fold is: the way a
;;;; full-screen client fails is by drawing the wrong thing, and the only way
;;;; to catch that is to render into a buffer and read it back.

(in-package #:vivarium.tui)

(defparameter *sidebar* 22)
(defparameter *tasks-width* 26)

(defun layout-for (width height)
  "The layout to use at this size.

A tmux pane is not eighty columns, and side panes that squeeze the output to
nothing are worse than no side panes. So they are dropped as the width falls,
widest-cost first: tasks, then sessions. This is a size question, not a
preference -- the panes are useless below the width where they stop fitting."
  (let ((body (cond ((< width 60) :output)
                    ((< width 100)
                     `(:beside (:fixed ,*sidebar* :sessions) (:weight 1 :output)))
                    (t `(:beside (:fixed ,*sidebar* :sessions)
                                 (:weight 1 :output)
                                 (:fixed ,*tasks-width* :tasks))))))
    ;; Under six rows there is no room for chrome; the output is the only thing
    ;; worth the space.
    (if (< height 8)
        :output
        `(:stack (:fixed 1 :tabs)
                 (:weight 1 ,body)
                 (:fixed 3 :input)
                 (:fixed 1 :status)))))

(defun wrap (text width)
  "TEXT as display rows of at most WIDTH, breaking at spaces where it can.

A hard break mid-word is what a naive client does and it makes output hard to
read; a word longer than the pane still has to break somewhere, so it breaks at
the edge."
  (let ((text (or text "")))
    (cond ((< width 1) '())
          ((<= (length text) width) (list text))
          (t (let* ((limit (min width (length text)))
                    (space (position #\Space text :end (1+ (min limit (1- (length text))))
                                                  :from-end t))
                    (break (if (and space (plusp space)) space limit)))
               (cons (subseq text 0 break)
                     (wrap (string-left-trim " " (subseq text break)) width)))))))

(defun display-rows (view width)
  "Every output line as wrapped display rows, in order."
  (let ((lines (append (view-lines view)
                       (when (plusp (length (view-partial view)))
                         (list (view-partial view))))))
    (loop for line in lines append (wrap line width))))

(defun visible-rows (view width height)
  "The rows to show, honouring scroll, oldest first.

Scrolling counts from the bottom because following is the normal case: a view
that is not scrolled shows the newest output without anybody asking."
  (let* ((rows (display-rows view width))
         (total (length rows))
         (end (max 0 (- total (view-scroll view))))
         (start (max 0 (- end height))))
    (subseq rows start end)))

(defun paint-output (view screen region)
  "Draw the conversation from the TOP of the pane.

Bottom-anchored was the first version and it looked broken: four lines of
conversation sat under fifty rows of nothing, which reads as a rendering fault
rather than as a short conversation. VISIBLE-ROWS already returns the tail when
there is more than fits, so anchoring at the top costs nothing when it is full
and fixes the case where it is not."
  (let ((rows (visible-rows view (region-width region) (region-height region))))
    (loop for row in rows
          for index from 0
          while (< index (region-height region))
          do (draw-in screen region index row))))

(defun session-label (entry)
  (cond ((and (consp entry) (consp (cdr entry))) (format nil "~a" (second entry)))
        ((consp entry) (format nil "~a" (cdr entry)))
        (t (format nil "~a" entry))))

(defun session-id (entry)
  (if (consp entry) (car entry) entry))

(defun session-state (entry)
  (if (and (consp entry) (consp (cdr entry))) (third entry) :idle))

(defun paint-sessions (view screen region)
  "One session per two rows: its name, then what it is doing.

Two rows rather than one because the name and the state are different
questions -- `which project` and `does it need me` -- and cramming both onto a
twenty-column line truncates the answer to the first."
  (loop for entry in (view-sessions view)
        for index from 0 by 2
        while (< (1+ index) (region-height region))
        do (let* ((current (equal (session-id entry) (view-current view)))
                  (mark (state-mark (session-state entry))))
             ;; A CHARACTER for which session is current, not only a colour.
             ;; Colour alone is invisible to a monochrome terminal, to anyone
             ;; who cannot distinguish the two shades, and to any test that
             ;; reads the frame -- so the one distinction that matters most is
             ;; the one that must not depend on it.
             (when current
               (draw-in screen region index ">" :column 0 :style *title-style*))
             (draw-in screen region index (car mark) :column 2 :style (cdr mark))
             (draw-in screen region index (short-label (session-label entry))
                      :column 4 :style (when current *title-style*))
             (draw-in screen region (1+ index)
                      (format nil "~(~a~)" (or (session-state entry) "idle"))
                      :column 4 :style *dim-style*))))

(defun task-mark (state)
  (case state (:running "~") (:done "+") (:failed "!") (t "?")))

(defun paint-tasks (view screen region)
  (loop for (nil state . label) in (view-tasks view)
        for index from 0
        while (< index (region-height region))
        do (draw-in screen region index (format nil "~a ~a" (task-mark state) label)
                    :style (when (eq state :failed)
                             (make-style :foreground 203)))))

(defun paint (view screen)
  "Draw VIEW onto SCREEN's back buffer. Does not flush."
  (clear-back screen)
  (let* ((width (screen-width screen))
         (height (screen-height screen))
         (regions (divide (layout-for width height) :width width :height height)))
    (flet ((region (name) (cdr (assoc name regions))))
      (a:when-let ((tabs (region :tabs)))
        (draw-tabs screen tabs (or (view-tabs view) (list "vivarium")) (view-tab view)))
      (a:when-let ((sessions (region :sessions)))
        (paint-sessions view screen (draw-box screen sessions :title "sessions")))
      (a:when-let ((tasks (region :tasks)))
        (paint-tasks view screen (draw-box screen tasks :title "tasks")))
      (a:when-let ((output (region :output)))
        (paint-output view screen
                      (draw-box screen output
                                :title (short-label (or (current-session-label view)
                                                        (view-current view) "output"))
                                :focused t)))
      (a:when-let ((input (region :input)))
        (let ((inner (draw-box screen input)))
          (draw-in screen inner 0 (format nil " > ~a" (view-input view)))))
      (a:when-let ((status (region :status)))
        (draw-in screen status 0
                 (format nil " ~a~@[  (~d back)~]"
                         (view-status view)
                         (and (plusp (view-scroll view)) (view-scroll view)))
                 :style *dim-style*)))
    screen))

(defun current-session-label (view)
  (a:when-let ((entry (find (view-current view) (view-sessions view)
                            :key #'session-id :test #'equal)))
    (session-label entry)))

(defun cursor-for (view screen)
  "Where the terminal's cursor belongs: after what has been typed.

A full-screen client that leaves the cursor wherever the last write ended is
telling the person their typing goes somewhere it does not, and screen readers
follow it too."
  (let* ((width (screen-width screen))
         (height (screen-height screen))
         (regions (divide (layout-for width height) :width width :height height))
         (input (cdr (assoc :input regions))))
    (if input
        ;; Inside the box: one row down, one column for the border, then the
        ;; three characters of " > " before anything typed.
        (cons (1+ (region-row input))
              (min (1- (screen-width screen))
                   (+ (region-column input) 4 (length (view-input view)))))
        (cons (1- height) 0))))
