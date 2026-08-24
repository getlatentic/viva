;;;; The task set: the instrument every scored experiment measures against.
;;;;
;;;; Depends on the image because a task installs definitions through it. Search
;;;; deliberately does NOT depend on this -- RUN-TRIAL takes thunks and does not
;;;; care where they came from -- so dependencies keep pointing inward.

(defpackage #:viva.service
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria)
                    (#:image #:viva.image))
  (:export #:fresh-package #:install-all #:seeded
           #:sym #:call-in #:value-in #:set-value-in
           #:+event-substrate+ #:+session-substrate+
           #:build-events #:build-sessions #:build-cache #:build-pending
           #:reference-revenue #:event-count #:refund-ids #:distinct-skus))

(defpackage #:viva.burden
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria)
                    (#:tool #:viva.tool))
  (:export #:*log* #:start-recording #:record-call #:record-turn-boundary
           #:recording-tool-set #:observation-burden #:burden-report
           #:inspect-calls #:investigation-requests #:turns
           #:gate-2 #:median #:+read-only-tools+
           #:+burden-threshold+ #:+solve-rate-threshold+))

(defpackage #:viva.tasks
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria)
                    (#:image #:viva.image)
                    (#:ledger #:viva.ledger)
                    (#:derive #:viva.derive)
                    (#:msg #:viva.message)
                    (#:tool #:viva.tool)
                    (#:agent #:viva.agent)
                    (#:loop* #:viva.loop)
                    (#:image-tools #:viva.image-tools)
                    (#:service #:viva.service)
                    (#:inspect #:viva.inspect)
                    (#:burden #:viva.burden)
                    (#:self #:viva.self))
  (:export #:task #:task-p #:make-task #:deftask
           #:task-id #:task-family #:task-split #:task-package
           #:task-prompt #:task-setup #:task-cases #:task-file-form
           #:register-task #:find-task #:all-tasks #:tasks-in #:task-families
           #:setup #:cases-for #:score #:scored-fraction #:intact-p
           #:*registry*
           #:bench-agent #:attempt-task #:attempt #:attempt-p
           #:attempt-task-id #:attempt-label #:attempt-scores #:attempt-requests
           #:attempt-elapsed-ms #:attempt-error #:attempt-total #:attempt-ceiling
           #:attempt-burden #:bench-tool-set #:experiment-b-tool-set #:+experiment-b-arms+
           #:bench-limit #:bench-requests #:score-cases
           #:attempt-fraction #:attempt-repeatedly #:fraction-summary
           #:attempt-contamination #:contamination-in
           #:jail-directory #:repository-root))
