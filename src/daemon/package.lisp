;;;; The organism: one long-lived process, sessions living inside it.
;;;;
;;;; The rule the whole design turns on, and the reason this package exists:
;;;;
;;;;   terminal lifetime  /=  vivarium lifetime
;;;;   task lifetime      /=  vivarium lifetime
;;;;   RPC lifetime       /=  vivarium lifetime
;;;;
;;;; A harness that exits after each task can only pretend to evolve. Closing a
;;;; client leaves the organism running, and self-modification becomes a
;;;; property of a process that persists rather than something bolted onto a
;;;; command that does not.
;;;;
;;;; See docs/architecture.md, which is frozen.

(defpackage #:vivarium.event
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria)
                    (#:jzon #:com.inuoe.jzon)
                    (#:msg #:vivarium.message)
                    (#:tool #:vivarium.tool))
  (:export #:event #:make-event #:event-p #:event-name #:event-session
           #:event-sequence #:event-time #:event-data #:as-json #:from-json
           #:from-loop #:+names+ #:name-valid-p))

(defpackage #:vivarium.actor
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria)
                    (#:bt #:bordeaux-threads)
                    (#:mailbox #:sb-concurrency)
                    (#:jzon #:com.inuoe.jzon)
                    (#:msg #:vivarium.message)
                    (#:agent #:vivarium.agent)
                    (#:env #:vivarium.env)
                    (#:harness #:vivarium.harness)
                    (#:operation #:vivarium.operation)
                    (#:session #:vivarium.session)
                    (#:kernel #:vivarium.kernel)
                    (#:tasktree #:vivarium.tasktree)
                    (#:tool #:vivarium.tool)
                    (#:event #:vivarium.event))
  ;; Sealed. A cell is an ownership boundary, not an object with a mailbox
  ;; attached: CELL-AGENT, CELL-STATE, CELL-EVENTS and CELL-QUEUED were
  ;; exported, which let anything read or hold actor-owned state directly --
  ;; the escape hatch every law here exists to remove. Ask through SNAPSHOT,
  ;; say through TELL and SUBMIT, listen through SUBSCRIBE. Tests reach inside
  ;; with :: on purpose; testing internals is what they are for.
  (:export #:cell #:cell-id #:spawn #:tell #:submit #:ask-now
           #:shutdown #:await-shutdown #:await-turn
           #:subscribe #:subscribe-since #:unsubscribe #:since
           #:find-cell #:all-cells #:snapshot #:+terminal-events+ #:*journal-root*
           #:spawn-task #:cancel-task #:task-tree-snapshot #:ensure-supervisor
           #:ensure-evolver #:create-candidate #:activate-candidate
           #:promote-candidate #:revert-component #:discard-candidate
           #:call-component #:resolve-component #:reconstruct-lineage
           #:evolution-registry #:*activation-box* #:*default-door*
           #:capability-tools))

(defpackage #:vivarium.daemon
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria)
                    (#:bt #:bordeaux-threads)
                    (#:mailbox #:sb-concurrency)
                    (#:jzon #:com.inuoe.jzon)
                    (#:sockets #:sb-bsd-sockets)
                    (#:msg #:vivarium.message)
                    (#:tool #:vivarium.tool)
                    (#:agent #:vivarium.agent)
                    (#:env #:vivarium.env)
                    (#:session #:vivarium.session)
                    (#:harness #:vivarium.harness)
                    (#:models #:vivarium.models)
                    (#:operation #:vivarium.operation)
                    (#:event #:vivarium.event)
                    (#:actor #:vivarium.actor))
  (:export #:serve #:stop #:running-p #:socket-path #:connect
           #:daemon-error #:with-connection #:request #:diagnostics))
