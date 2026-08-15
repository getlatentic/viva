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
                    (#:msg #:vivarium.message)
                    (#:tool #:vivarium.tool))
  (:export #:event #:make-event #:event-name #:event-session #:event-sequence
           #:event-time #:event-data #:as-json #:from-loop
           #:+names+ #:name-valid-p))

(defpackage #:vivarium.actor
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria)
                    (#:bt #:bordeaux-threads)
                    (#:mailbox #:sb-concurrency)
                    (#:msg #:vivarium.message)
                    (#:agent #:vivarium.agent)
                    (#:harness #:vivarium.harness)
                    (#:operation #:vivarium.operation)
                    (#:session #:vivarium.session)
                    (#:event #:vivarium.event))
  (:export #:cell #:cell-id #:cell-agent #:cell-state #:cell-label
           #:spawn #:tell #:ask-now #:shutdown #:cell-events #:subscribe #:unsubscribe
           #:find-cell #:all-cells #:cell-sequence #:since #:busy-p #:cell-queued
           #:+terminal-events+ #:quiesce))

(defpackage #:vivarium.daemon
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria)
                    (#:bt #:bordeaux-threads)
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
           #:*socket* #:daemon-error #:with-connection #:request #:diagnostics))
