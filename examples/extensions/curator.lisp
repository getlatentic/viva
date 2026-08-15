;;;; curator -- consolidate memory into procedure, because asking did not work.
;;;;
;;;; Measured over five conditions and eighty-four runs, memory the agent wrote
;;;; for itself was not measurably better than having no memory at all
;;;; (-1.9 calls/task, 1.6x its own standard error), while four hand-written
;;;; procedural facts were (-4.8, 4.5x). Rewriting what the REMEMBER tool asks
;;;; for changed the style and halved the volume and moved the cost not at all.
;;;;
;;;; The reason is structural, not a wording problem. An agent writing a note has
;;;; just finished exactly one task, so its idea of "a durable fact about this
;;;; project" is anchored to whatever it just touched -- and it will restate that
;;;; defect as a convention however the request is phrased. `balance() must never
;;;; wrap in float()` is one bug wearing a convention's clothes.
;;;;
;;;; A consolidator has no such anchor. It is handed notes from MANY tasks at
;;;; once, so "what is true of the project rather than of one job" stops being a
;;;; judgement it has to make about its own recent work and becomes something
;;;; visible in the input: the parts that recur. That is why this is a mechanism
;;;; and not another paragraph in a tool description.
;;;;
;;;; It runs on :RUN-END -- everything the agent did has happened, nothing is
;;;; waiting on the answer -- and costs one extra model request per run.

(in-package #:vivarium.extension)

(defparameter +curator-threshold+ 3
  "Notes required before consolidating. Below this there is nothing to compare:
one note about one task is indistinguishable from a project fact, which is the
whole difficulty.")

(defparameter +curator-instruction+
  "Below are notes written by an engineer after finishing several separate jobs
in one repository. Each was written immediately after one job, so each is
coloured by that job.

Rewrite them as a short list of durable facts about the REPOSITORY: how it is
built and tested, conventions that hold across files, which directories are live
and which are dead, where things are. Keep what would help someone starting a
completely unrelated job here tomorrow.

Drop anything that is really about one past defect -- a specific function that
was wrong, a specific value that should have been something else, what a
particular test asserts. If a note only makes sense to someone who hit that same
bug, it is not a fact about the repository.

Merge duplicates. Prefer fewer, more general lines. Reply with the lines only,
one per line, each beginning with \"- \", and nothing else.")

(defun curator-notes (text)
  (remove-if (lambda (line) (< (length (string-trim '(#\Space #\-) line)) 8))
             (uiop:split-string text :separator (string #\Newline))))

(defun curator-ask (agent prompt)
  "One model request on the agent's own provider, with no tools and no history.

Deliberately a bare agent rather than the working one: the consolidator must see
the notes and nothing else. Handed the run's conversation it would have the very
anchor this exists to remove."
  (let ((scribe (make-instance 'vivarium.agent:queued-agent
                               :provider (vivarium.agent:agent-provider agent)
                               :model (vivarium.agent:agent-model agent)
                               :max-tokens 1024
                               :system-prompt +curator-instruction+
                               :tools '())))
    (vivarium.message:text-of
     (vivarium.client:complete
      scribe
      (list (vivarium.message:make-user-message
             :content (list (vivarium.message:make-text prompt))))))))

(defun curator-consolidate (event)
  (declare (ignore event))
  (let ((agent vivarium.harness:*agent*))
    (unless agent (return-from curator-consolidate nil))
    (let* ((environment (vivarium.harness:agent-environment agent))
           (existing (vivarium.memory:read-memory environment))
           (notes (curator-notes existing)))
      (when (< (length notes) +curator-threshold+)
        (return-from curator-consolidate nil))
      (let ((rewritten (handler-case (curator-ask agent (format nil "~{~a~%~}" notes))
                         ;; A failed consolidation must lose nothing. The
                         ;; original notes are the only copy.
                         (error () nil))))
        (when (and rewritten (plusp (length (curator-notes rewritten))))
          (vivarium.env:write-text
           environment
           (vivarium.memory:memory-path environment)
           (format nil "# What I have learned working here~%~%~{~a~%~}"
                   (curator-notes rewritten))))))
    nil))

(defextension "curator"
  :description "Rewrites accumulated notes into repository-level procedure after each run."
  (on :run-end #'curator-consolidate)
  (register-command "consolidate"
                    :description "Consolidate memory now."
                    :handler (lambda (agent argument)
                               (declare (ignore argument))
                               (let ((vivarium.harness:*agent* agent))
                                 (curator-consolidate nil)
                                 (vivarium.memory:read-memory
                                  (vivarium.harness:agent-environment agent))))))
