;;;; Sessions carried across an upgrade.
;;;;
;;;; The daemon replaces its image in the same process (exec.lisp), and what a
;;;; cell holds only in memory goes with the old image. So the old image writes
;;;; it down and the new one continues from it: the same id, the same event
;;;; numbering and journal file, the same prompts waiting. The conversation is
;;;; read back from the transcript, the way a restored session reads it, and
;;;; the recent events from the journal they were written to.

(in-package #:viva.actor)

(defun hold-sessions ()
  "Hold every session: running turns finish, nothing new starts, prompts wait.
Asserted again while the upgrade waits, because a session resumed mid-turn has
left the hold and holding it again is what drains it."
  (setf *holding* t)
  (dolist (cell (all-cells)) (tell cell :hold)))

(defun release-sessions ()
  "Start what the hold kept waiting."
  (setf *holding* nil)
  (dolist (cell (all-cells)) (tell cell :release)))

(defun at-rest-p (cell)
  "Is CELL somewhere an image can be replaced around? Nothing running, nothing
able to start, and nothing posted that the coordinator has not handled.

A SUSPENDED TURN IS NOT AT REST. Its worker is a thread parked mid-turn, and a
thread does not cross an exec."
  (owning (cell)
    (and (zerop (mailbox:mailbox-count (cell-mailbox cell)))
         (let ((machine (cell-machine cell)))
           (case (first machine)
             ((:held :stuck :completed) t)
             (:suspended (eq :none (second machine)))
             (t nil))))))

(defun journal-settled ()
  "T once everything posted to the journal is on disk -- including when nothing
ever was. The owner starts with the first session, and a daemon with none has
no owner to confirm anything; JOURNAL-SYNC calls that unconfirmed, which is the
right answer for a reader and the wrong one for an upgrade."
  (if (bt:with-lock-held (*journal-lock*) *journal-machine*)
      (journal-sync)
      t))

(defun settle (cell &key (timeout 10))
  "Wait until CELL has handled everything posted to it so far. T when it has."
  (let ((semaphore (bt:make-semaphore :count 0)))
    (tell cell :barrier :semaphore semaphore)
    (and (bt:wait-on-semaphore semaphore :timeout timeout) t)))

(defun unsettled-reason (cell)
  "Why CELL is not at rest yet, in words for the person waiting, or NIL."
  (unless (at-rest-p cell)
    (let ((machine (owning (cell) (cell-machine cell))))
      (case (first machine)
        (:suspended (format nil "~a is paused in the middle of a turn" (cell-id cell)))
        ((:draining :working) (format nil "~a is finishing a turn" (cell-id cell)))
        ((:stopping :flushing) (format nil "~a is stopping" (cell-id cell)))
        (t (format nil "~a is handling a message" (cell-id cell)))))))

;;; The record

(defun queued-record (entry)
  (destructuring-bind (turn . options) entry
    (event::object "turn" turn
                   "text" (getf options :text)
                   "source" (getf options :source)
                   "retain" (and (getf options :retain) t))))

(defun queued-entry (record)
  "RECORD as the queue holds it: (TURN . the message's own options)."
  (let ((turn (gethash "turn" record)))
    (cons turn
          (append (list :turn turn)
                  (a:when-let ((text (gethash "text" record))) (list :text text))
                  (a:when-let ((source (gethash "source" record))) (list :source source))
                  (when (gethash "retain" record) (list :retain t))))))

(defun cell-record (cell)
  "What the next image needs to continue CELL and cannot read back from disk.
Taken at rest, with every event committed to the journal."
  (owning (cell)
    (let ((machine (cell-machine cell)))
      (event::object "id" (cell-id cell)
                     "label" (cell-label cell)
                     ;; THE TRANSCRIPT'S CWD, which is what finds it again. The
                     ;; cell's own is canonical, and on macOS /var is a link to
                     ;; /private/var: the same directory under a slug no
                     ;; transcript was stored under.
                     "cwd" (or (a:when-let ((session (harness:agent-session (cell-agent cell))))
                                 (session:session-cwd session))
                               (cell-cwd cell))
                     "model" (cell-model cell)
                     "staged" (a:when-let ((choice (cell-staged-model cell)))
                                (models:choice-label choice))
                     "opening" (cell-opening cell)
                     "turns" (cell-turns cell)
                     "sequence" (cell-sequence cell)
                     "journal" (cell-journal-path cell)
                     "degraded" (a:when-let ((degraded (cell-degraded cell)))
                                  (string-downcase (symbol-name degraded)))
                     "state" (case (first machine)
                               (:held (if (eq :suspended (third machine)) "suspended" "idle"))
                               (:suspended "suspended")
                               (t (string-downcase (symbol-name (first machine)))))
                     "queued" (coerce (mapcar #'queued-record (cell-queued cell)) 'vector)
                     "capability" (a:when-let ((identity (agent-capability-identity (cell-agent cell))))
                                    (event::object "task" (first identity)
                                                   "seen" (coerce (second identity) 'vector)))))))

(defun adopt-cell (record agent)
  "Continue, in this image, the session RECORD describes, answering with AGENT.

HELD, not idle. The prompts that waited through the upgrade start when the
daemon releases its sessions, which it does once every one of them is back --
so a session whose turn begins early cannot race the ones still arriving."
  (let* ((sequence (gethash "sequence" record))
         (queued (map 'list #'queued-entry (or (gethash "queued" record) #())))
         (state (gethash "state" record))
         (cell (make-cell :id (gethash "id" record)
                          :label (gethash "label" record)
                          :agent agent
                          :model (gethash "model" record)
                          :cwd (env:env-cwd (harness:agent-environment agent))
                          :opening (or (gethash "opening" record) "")
                          :turns (gethash "turns" record)
                          :sequence sequence
                          :committed sequence
                          :journal-path (gethash "journal" record)
                          :degraded (a:when-let ((degraded (gethash "degraded" record)))
                                      (a:make-keyword (string-upcase degraded)))
                          :queued queued
                          :machine (cond ((equal state "stuck") '(:stuck))
                                         ((equal state "suspended")
                                          `(:held ,(length queued) :suspended))
                                         (t `(:held ,(length queued) :idle))))))
    (listen-through cell agent)
    (a:when-let ((identity (gethash "capability" record)))
      (adopt-capability-identity agent (list (gethash "task" identity)
                                             (coerce (or (gethash "seen" identity) #()) 'list))))
    (when (equal state "suspended")
      (harness:suspend-agent agent))
    (a:when-let ((label (gethash "staged" record)))
      (setf (cell-staged-model cell) (ignore-errors (models:resolve-model label))))
    (ensure-journal)
    ;; The hot tail, read back from the journal the old image wrote it to.
    (dolist (event (read-journal cell (max 0 (- sequence +tail-limit+)) sequence))
      (setf (svref (cell-tail cell) (mod (event:event-sequence event) +tail-limit+))
            event))
    (sync-mechanics cell)
    (bt:with-lock-held (*registry-lock*) (setf (gethash (cell-id cell) *cells*) cell))
    (handler-case (mark-live cell)
      (error (condition)
        (format *error-output* "~&viva live-marker: ~a not written: ~a~%" (cell-id cell) condition)))
    (release-descriptors cell)
    (setf (cell-parked cell) t)
    cell))

(defun subscribed-p (cell key)
  "Is KEY still receiving CELL's events? A subscriber that fell too far behind is
dropped, and carrying it across would resume a stream it was told had ended."
  (owning (cell) (and (assoc key (cell-subscribers cell) :test #'equal) t)))

;;; The task tree

(defun tasks-running-p ()
  "Is any task still live? A task is a thread, and a thread does not cross."
  (and *supervisor*
       (some #'tasktree:live-p
             (bt:with-lock-held ((supervisor-lock *supervisor*))
               (tasktree:tree-tasks (supervisor-tree *supervisor*))))))

(defun tasks-record ()
  "The tree as text, or NIL when this image never had one. Plain values --
keywords, integers, strings -- so the printer writes it and the reader reads it."
  (when *supervisor*
    (with-standard-io-syntax
      (let ((*print-readably* t))
        (prin1-to-string
         (bt:with-lock-held ((supervisor-lock *supervisor*))
           (supervisor-tree *supervisor*)))))))

(defun adopt-tasks (text)
  "Give this image the task tree TEXT describes. Every task in it has ended, so
there is nothing to rig."
  (when text
    (let ((tree (with-standard-io-syntax
                  (let ((*read-eval* nil))
                    (read-from-string text)))))
      (let ((supervisor (ensure-supervisor)))
        (bt:with-lock-held ((supervisor-lock supervisor))
          (setf (supervisor-tree supervisor) tree))))))

;;; Self-modification in flight

(defun evolution-record ()
  "The evolver as text, or NIL when this image never had one: the registry
value, the source of every version that has one, which versions are file-backed,
the door, and the counter task identities are minted from.

A CANDIDATE IS NOT WRITTEN DOWN anywhere else -- it lives for its task, and a
session's task lives as long as its agent. Without this, a session part-way
through trying a capability would find it gone after an upgrade it never saw."
  (when *evolver*
    (with-standard-io-syntax
      (let ((*package* (find-package '#:viva.capabilities))
            (*print-readably* t))
        (prin1-to-string
         (bt:with-lock-held ((evolver-lock *evolver*))
           (list :registry (evolver-registry *evolver*)
                 :door (evolver-door *evolver*)
                 :counter (bt:with-lock-held (*capability-lock*) *capability-counter*)
                 :sources (loop for id being the hash-keys of (evolver-sources *evolver*)
                                  using (hash-value kept)
                                collect (list id (kept-source kept) (kept-note kept)))
                 :file-backed (loop for id being the hash-keys of (evolver-functions *evolver*)
                                      using (hash-value function)
                                    unless function collect id))))))))

(defun adopt-evolution (text)
  "Give this image the evolver TEXT describes, before anything asks for one:
the same versions under the same ids, each compiled again from its source, and
each task's activations back in its box."
  (when text
    (let* ((plist (with-standard-io-syntax
                    (let ((*package* (find-package '#:viva.capabilities))
                          (*read-eval* nil))
                      (read-from-string text))))
           (registry (getf plist :registry))
           (evolver (make-evolver :door (getf plist :door) :registry registry)))
      (loop for (id source note) in (getf plist :sources)
            do (multiple-value-bind (function condition)
                   (compile-capability (viva.evolution:version-component registry id) source)
                 (if function
                     (setf (gethash id (evolver-functions evolver)) function
                           (gethash id (evolver-sources evolver))
                           (make-kept :source source :note note))
                     (format *error-output* "~&viva capability: version ~d not carried over: ~a~%"
                             id condition))))
      (dolist (id (getf plist :file-backed))
        (setf (gethash id (evolver-functions evolver)) nil))
      (loop for (task) in (viva.evolution::registry-pins registry)
            do (refresh-box evolver task))
      (bt:with-lock-held (*capability-lock*)
        (setf *capability-counter* (max *capability-counter* (getf plist :counter 0))))
      (bt:with-lock-held (*evolver-lock*)
        (unless *evolver*
          (setf (evolver-thread evolver)
                (bt:make-thread (lambda () (run-evolver evolver)) :name "viva-evolution")
                *evolver* evolver))))))

(defun agent-capability-identity (agent)
  "AGENT's task identity for self-modification and what it has resolved, or NIL
when it never used a capability."
  (bt:with-lock-held (*capability-lock*)
    (a:when-let ((task (gethash agent *capability-tasks*)))
      (list task
            (a:when-let ((seen (gethash agent *capability-seen*)))
              (a:hash-table-keys seen))))))

(defun adopt-capability-identity (agent identity)
  "Give AGENT the task identity IDENTITY names, so the candidates and pins that
belong to it are still its own."
  (when identity
    (destructuring-bind (task seen) identity
      (bt:with-lock-held (*capability-lock*)
        (setf (gethash agent *capability-tasks*) task)
        (let ((table (make-hash-table :test #'equal)))
          (dolist (key seen) (setf (gethash key table) t))
          (setf (gethash agent *capability-seen*) table))))))
