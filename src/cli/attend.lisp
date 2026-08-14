;;;; Watch an agent work a task, and steer it while it does.
;;;;
;;;; This file composes; it neither formats nor draws. Renderers consume one
;;;; event stream (render.lisp), the screen owns the terminal (screen.lisp), and
;;;; the transcript is always among the renderers because it is the artefact.
;;;;
;;;; CONSEQUENCE OF E1, and it will surprise someone: the agent runs on a worker
;;;; thread so the screen can own input, which means this process has two
;;;; threads and can never fork a trial. CHECK-ZYGOTE would refuse. Attending
;;;; and searching have to be separate processes.

(in-package #:vivarium.cli)

;;; A session is what an agent works on: a package to install into, something to
;;; say, and optionally cases that score the result. A registered task is one way
;;; to build one and your own prompt is another, so ATTEND and RUN are the same
;;; command over two sources rather than two commands.

(defstruct (session (:conc-name session-))
  (label "" :type string)
  (package "" :type string)
  (prompt "" :type string)
  (backend nil)
  (cases '() :type list)
  (jail nil))

(defun task-session (task)
  (let ((backend (make-instance 'image:sbcl-image :package (tasks:task-package task))))
    (tasks:setup task backend)
    (make-session :label (string (tasks:task-id task))
                  :package (tasks:task-package task)
                  :prompt (tasks:task-prompt task)
                  :backend backend
                  ;; Built before the agent acts: a case closes over the world
                  ;; it will later compare against.
                  :cases (tasks:cases-for task backend)
                  ;; Scored runs jail the shell. One agent read the file holding
                  ;; its own scoring cases.
                  :jail (tasks:jail-directory task))))

(defun ad-hoc-session (prompt &key package load systems jail)
  "Your own prompt against your own code. No cases, so nothing is scored -- the
ledger is the whole report."
  (let ((name (or package "VIVARIUM.SCRATCH")))
    (unless (find-package name)
      (make-package name :use '(#:common-lisp)))
    (dolist (system systems) (asdf:load-system system))
    (dolist (file load) (load file))
    (make-session :label name :package name :prompt prompt
                  :backend (make-instance 'image:sbcl-image :package name)
                  :jail jail)))

(defclass attending-agent (tasks:bench-agent)
  ((renderers :initarg :renderers :accessor agent-renderers :initform '())))

(defmethod agent:emit ((agent attending-agent) event)
  (broadcast (agent-renderers agent) event))

(defun steer-with (agent)
  (lambda (text)
    (agent:queue-steering
     agent (msg:make-user-message :content (list (msg:make-text text))))))

(defun attend-renderers (parsed backend)
  "The transcript always; a screen too when there is a terminal to draw on and
--plain was not asked for. Piping or CI gets the transcript alone, unchanged."
  (let ((plain (or (flag parsed "plain")
                   (not (interactive-stream-p *standard-output*)))))
    (cons (make-instance 'transcript)
          (unless plain (list (make-instance 'screen :backend backend))))))

(defun run-attended (agent session renderers)
  "Run the agent on a worker so the screen can own the keyboard."
  (let* ((screen (find-if (lambda (r) (typep r 'screen)) renderers))
         (worker (bt:make-thread
                  (lambda ()
                    (let ((image-tools:*backend* (session-backend session))
                          (image-tools:*bash-directory* (session-jail session)))
                      (handler-case
                          (loop*:run agent (list (msg:make-user-message
                                                  :content (list (msg:make-text
                                                                  (session-prompt session))))))
                        (error (condition)
                          (broadcast renderers (list :type :message
                                                     :message (msg:make-assistant-message
                                                               :content (list (msg:make-text
                                                                               (princ-to-string condition)))
                                                               :stop-reason :error)))))))
                  :name "vivarium-agent")))
    (if screen
        (drive-screen screen worker (steer-with agent))
        (steer-from-stdin agent worker))
    (bt:join-thread worker)))

(defun steer-from-stdin (agent worker)
  "The --plain path: no screen, so READ-LINE can have its own thread."
  (let ((reader (bt:make-thread
                 (lambda ()
                   (loop for line = (read-line *standard-input* nil nil)
                         while (and line (bt:thread-alive-p worker))
                         do (let ((text (string-trim " " line)))
                              (when (plusp (length text))
                                (funcall (steer-with agent) text)))))
                 :name "vivarium-steer")))
    (bt:join-thread worker)
    (ignore-errors (bt:destroy-thread reader))))

(defun attend-session (session parsed)
  (let* ((arm (first (arms-named (a:when-let ((m (flag parsed "model"))) (list m)))))
         (renderers (attend-renderers parsed (session-backend session))))
    (unless arm
      (format t "~&No arm available. Set a key in .env.~%")
      (return-from attend-session 1))
    (let ((agent (make-instance 'attending-agent
                                :renderers renderers
                                :provider (arm-provider arm) :model (arm-model arm)
                                :reasoning-effort (arm-effort arm)
                                :limit (flag-integer parsed "limit" 12)
                                :stream t :abort-on-steer t
                                :system-prompt image-tools:*system-prompt*
                                :tools (image-tools:tool-set))))
      (broadcast renderers (list :type :opening :task (session-label session)
                                 :arm (arm-label arm) :prompt (session-prompt session)))
      (run-attended agent session renderers)
      (broadcast renderers (list :type :scored :backend (session-backend session)
                                 :scores (tasks:score-cases (session-cases session))
                                 :requests (tasks:bench-requests agent))))
    0))

(defun command-attend (parsed)
  (let ((name (first (args-positional parsed))))
    (unless name
      (format t "~&usage: vivarium attend <task> [--model NAME] [--limit N] [--plain]~%~
Use `vivarium run` with a prompt of your own for anything else.~%")
      (return-from command-attend 1))
    (attend-session (task-session (tasks:find-task (a:make-keyword (string-upcase name))))
                    parsed)))

(defun prompt-from (parsed)
  "The prompt, from an argument, a file, or standard input -- so it can be typed,
kept in version control, or piped."
  (let ((positional (first (args-positional parsed)))
        (file (flag parsed "file")))
    (cond (file (uiop:read-file-string file))
          (positional positional)
          ((not (interactive-stream-p *standard-input*))
           (with-output-to-string (out)
             (loop for line = (read-line *standard-input* nil nil)
                   while line do (write-line line out))))
          (t nil))))

(defun command-run (parsed)
  "An agent against your own code, with your own prompt."
  (let ((prompt (prompt-from parsed)))
    (unless (and prompt (plusp (length (string-trim '(#\Space #\Newline) prompt))))
      (format t "~&usage: vivarium run <prompt> [--package NAME] [--system S] [--load F]~%~
       vivarium run --file prompt.txt --package MYAPP~%~
       echo <prompt> | vivarium run --system my-app~%")
      (return-from command-run 1))
    (attend-session
     (ad-hoc-session prompt
                     :package (a:when-let ((p (flag parsed "package"))) (string-upcase p))
                     :systems (flag-list parsed "system")
                     :load (flag-list parsed "load")
                     ;; Unjailed by default: this is your project, and an agent
                     ;; that cannot see it is useless here. Scored runs are the
                     ;; opposite case and jail themselves.
                     :jail (a:when-let ((d (flag parsed "jail"))) (pathname d)))
     parsed)))
