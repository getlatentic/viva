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
    (if (< height 6)
        :output
        `(:stack (:fixed 1 :title)
                 (:weight 1 ,body)
                 (:fixed 1 :input)
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
  (let ((rows (visible-rows view (region-width region) (region-height region))))
    (loop for row in rows
          for index from (max 0 (- (region-height region) (length rows)))
          do (draw-in screen region index row))))

(defun session-label (entry)
  (if (consp entry) (format nil "~a" (cdr entry)) (format nil "~a" entry)))

(defun session-id (entry)
  (if (consp entry) (car entry) entry))

(defun paint-sessions (view screen region)
  (draw-in screen region 0 "sessions")
  (loop for entry in (view-sessions view)
        for index from 1
        while (< index (region-height region))
        do (draw-in screen region index
                    (format nil "~a ~a"
                            (if (equal (session-id entry) (view-current view)) ">" " ")
                            (session-label entry)))))

(defun task-mark (state)
  (case state (:running "~") (:done "+") (:failed "!") (t "?")))

(defun paint-tasks (view screen region)
  (draw-in screen region 0 "tasks")
  (loop for (nil state . label) in (view-tasks view)
        for index from 1
        while (< index (region-height region))
        do (draw-in screen region index (format nil "~a ~a" (task-mark state) label))))

(defun paint (view screen)
  "Draw VIEW onto SCREEN's back buffer. Does not flush."
  (clear-back screen)
  (let* ((width (screen-width screen))
         (height (screen-height screen))
         (regions (divide (layout-for width height) :width width :height height)))
    (flet ((region (name) (cdr (assoc name regions))))
      (a:when-let ((title (region :title)))
        (draw-in screen title 0
                 (format nil "vivarium  ~a~@[  ~a~]"
                         (or (view-current view) "no session")
                         (and (view-busy view) "working"))))
      (a:when-let ((sessions (region :sessions))) (paint-sessions view screen sessions))
      (a:when-let ((tasks (region :tasks))) (paint-tasks view screen tasks))
      (a:when-let ((output (region :output))) (paint-output view screen output))
      (a:when-let ((input (region :input)))
        (draw-in screen input 0 (format nil "> ~a" (view-input view))))
      (a:when-let ((status (region :status)))
        (draw-in screen status 0
                 (format nil "~a~@[  (~d back)~]"
                         (view-status view)
                         (and (plusp (view-scroll view)) (view-scroll view))))))
    screen))

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
        (cons (region-row input)
              (min (1- (screen-width screen))
                   (+ (region-column input) 2 (length (view-input view)))))
        (cons (1- height) 0))))
