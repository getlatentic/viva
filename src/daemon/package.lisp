;;;; The organism: one long-lived process, sessions living inside it.
;;;;
;;;; The rule the whole design turns on, and the reason this package exists:
;;;;
;;;;   terminal lifetime  /=  viva lifetime
;;;;   task lifetime      /=  viva lifetime
;;;;   RPC lifetime       /=  viva lifetime
;;;;
;;;; A harness that exits after each task can only pretend to evolve. Closing a
;;;; client leaves the organism running, and self-modification becomes a
;;;; property of a process that persists rather than something bolted onto a
;;;; command that does not.
;;;;
;;;; See docs/architecture.md, which is frozen.

(defpackage #:viva.event
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria)
                    (#:jzon #:com.inuoe.jzon)
                    (#:msg #:viva.message)
                    (#:session #:viva.session)
                    (#:tool #:viva.tool))
  (:export #:event #:make-event #:event-p #:event-name #:event-session
           #:event-sequence #:event-time #:event-data #:as-json #:from-json
           #:from-loop #:+names+ #:name-valid-p #:call-json))

(defpackage #:viva.actor
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria)
                    (#:bt #:bordeaux-threads)
                    (#:mailbox #:sb-concurrency)
                    (#:jzon #:com.inuoe.jzon)
                    (#:msg #:viva.message)
                    (#:agent #:viva.agent)
                    (#:env #:viva.env)
                    (#:harness #:viva.harness)
                    (#:operation #:viva.operation)
                    (#:session #:viva.session)
                    (#:kernel #:viva.kernel)
                    (#:tasktree #:viva.tasktree)
                    (#:tool #:viva.tool)
                    (#:registry #:viva.registry)
                    (#:event #:viva.event))
  ;; Sealed. A cell is an ownership boundary, not an object with a mailbox
  ;; attached: CELL-AGENT, CELL-STATE, CELL-EVENTS and CELL-QUEUED were
  ;; exported, which let anything read or hold actor-owned state directly --
  ;; the escape hatch every law here exists to remove. Ask through SNAPSHOT,
  ;; say through TELL and SUBMIT, listen through SUBSCRIBE. Tests reach inside
  ;; with :: on purpose; testing internals is what they are for.
  (:export #:cell #:cell-id #:spawn #:tell #:submit #:submit-retention #:busy-p #:ask-now #:publish
           #:shutdown #:await-shutdown #:await-turn
           #:subscribe #:subscribe-since #:unsubscribe #:since
           #:find-cell #:all-cells #:snapshot #:+terminal-events+ #:*journal-root*
           #:live-sessions #:unmark-live #:live-root
           #:spawn-task #:cancel-task #:task-tree-snapshot #:ensure-supervisor
           #:ensure-evolver #:create-candidate #:activate-candidate
           #:promote-candidate #:revert-component #:discard-candidate
           #:register-file-tool #:ledger-registrations
           #:call-component #:resolve-component #:reconstruct-lineage
           #:evolution-registry #:*activation-box* #:*default-door*
           #:capability-tools))

(defpackage #:viva.daemon
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria)
                    (#:germline #:viva.germline)
                    (#:jobs #:viva.jobs)
                    (#:bt #:bordeaux-threads)
                    (#:mailbox #:sb-concurrency)
                    (#:jzon #:com.inuoe.jzon)
                    (#:sockets #:sb-bsd-sockets)
                    (#:msg #:viva.message)
                    (#:tool #:viva.tool)
                    (#:agent #:viva.agent)
                    (#:env #:viva.env)
                    (#:session #:viva.session)
                    (#:harness #:viva.harness)
                    (#:models #:viva.models)
                    (#:operation #:viva.operation)
                    (#:event #:viva.event)
                    (#:loop* #:viva.loop)
                    (#:workspace #:viva.workspace)
                    (#:actor #:viva.actor))
  (:export #:serve #:stop #:running-p #:socket-path #:connect
           #:daemon-error #:with-connection #:request #:diagnostics))
