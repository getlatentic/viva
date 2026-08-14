;;;; The live screen: trajectory on the left, image state on the right.
;;;;
;;;; Everything that decides WHAT to show is in render.lisp and is a pure
;;;; function. This file only puts strings at coordinates, which is the part
;;;; that needs a terminal and therefore cannot be tested here.
;;;;
;;;; The agent runs on a worker thread and this loop owns the main one, because
;;;; ncurses owns terminal input. Events arrive from the worker, so the queue is
;;;; behind a lock.

(in-package #:vivarium.cli)

(defclass screen ()
  ((trajectory :initform '() :accessor screen-trajectory)
   (backend :initarg :backend :reader screen-backend)
   (scores :initform '() :accessor screen-scores)
   (heading :initform "" :accessor screen-heading)
   (typing :initform "" :accessor screen-typing)
   (dirty :initform t :accessor screen-dirty-p)
   (lock :initform (bt:make-lock "vivarium.screen") :reader screen-lock)))

(defmethod render ((renderer screen) event)
  (bt:with-lock-held ((screen-lock renderer))
    (case (getf event :type)
      (:opening (setf (screen-heading renderer)
                      (format nil "~a via ~a" (getf event :task) (getf event :arm))))
      (:scored (setf (screen-scores renderer) (getf event :scores)))
      (t (a:when-let ((line (trajectory-line event)))
           (push line (screen-trajectory renderer)))))
    (setf (screen-dirty-p renderer) t)))

;;; Drawing

(defun put (window row column text width)
  (when (and (>= row 0) (plusp width))
    (croatoan:move window row column)
    (croatoan:add-string window
                         (let ((flat (substitute #\Space #\Tab (or text ""))))
                           (if (> (length flat) width) (subseq flat 0 width) flat)))))

(defun last-n (list n) (let ((have (length list))) (if (> have n) (subseq list 0 n) list)))

(defun paint-screen (renderer window)
  (let* ((height (croatoan:height window))
         (width (croatoan:width window))
         (split (floor width 2))
         (body (- height 4)))
    (croatoan:clear window)
    (put window 0 0 (screen-heading renderer) width)
    (put window 1 0 (make-string width :initial-element #\─) width)
    ;; Left: the trajectory, newest at the bottom, which is how a log reads.
    (let ((lines (reverse (last-n (screen-trajectory renderer) body))))
      (loop for line in lines
            for row from 2
            do (put window row 0 line (1- split))))
    ;; Right: the image as it stands now. State, so it is redrawn rather than
    ;; appended -- the whole reason this is a pane and not more log lines.
    (loop for line in (last-n (ledger-lines (screen-backend renderer)) body)
          for row from 2
          do (put window row (1+ split) line (- width split 2)))
    (loop for row from 2 below (- height 2)
          do (put window row split "│" 1))
    (put window (- height 2) 0 (make-string width :initial-element #\─) width)
    (put window (- height 2) 2 (format nil " ~a " (score-line (screen-scores renderer))) (- width 4))
    (put window (- height 1) 0 (format nil "steer> ~a" (screen-typing renderer)) width)
    (croatoan:refresh window)
    (setf (screen-dirty-p renderer) nil)))

;;; The loop that owns the terminal

(defun drive-screen (renderer worker on-steer)
  "Poll the keyboard and repaint until WORKER finishes. Returns when it does."
  (croatoan:with-screen (window :input-echoing nil :input-blocking nil :cursor-visible t)
    (loop
      (let ((key (croatoan:get-char window)))
        (cond ((null key))
              ((member key '(#\Newline #\Return))
               (let ((text (string-trim " " (screen-typing renderer))))
                 (setf (screen-typing renderer) "")
                 (when (plusp (length text))
                   (funcall on-steer text)
                   (render renderer (list :type :steer :text text)))))
              ((member key '(#\Rubout #\Backspace))
               (let ((typed (screen-typing renderer)))
                 (when (plusp (length typed))
                   (setf (screen-typing renderer) (subseq typed 0 (1- (length typed)))))))
              ((and (characterp key) (graphic-char-p key))
               (setf (screen-typing renderer)
                     (concatenate 'string (screen-typing renderer) (string key))))))
      (when (screen-dirty-p renderer)
        (bt:with-lock-held ((screen-lock renderer)) (paint-screen renderer window)))
      (unless (bt:thread-alive-p worker)
        (paint-screen renderer window)
        (return))
      (sleep 0.03))))
