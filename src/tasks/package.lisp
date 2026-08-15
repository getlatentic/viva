;;;; The task set: the instrument every scored experiment measures against.
;;;;
;;;; Depends on the image because a task installs definitions through it. Search
;;;; deliberately does NOT depend on this -- RUN-TRIAL takes thunks and does not
;;;; care where they came from -- so dependencies keep pointing inward.

(defpackage #:vivarium.service
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria)
                    (#:image #:vivarium.image))
  (:export #:fresh-package #:install-all #:seeded
           #:sym #:call-in #:value-in #:set-value-in
           #:+event-substrate+ #:+session-substrate+
           #:build-events #:build-sessions #:build-cache #:build-pending
           #:reference-revenue #:event-count #:refund-ids #:distinct-skus))

(defpackage #:vivarium.burden
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria)
                    (#:tool #:vivarium.tool))
  (:export #:*log* #:start-recording #:record-call #:record-turn-boundary
           #:recording-tool-set #:observation-burden #:burden-report
           #:inspect-calls #:investigation-requests #:turns
           #:gate-2 #:median #:+read-only-tools+
           #:+burden-threshold+ #:+solve-rate-threshold+))

(defpackage #:vivarium.tasks
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria)
                    (#:image #:vivarium.image)
                    (#:ledger #:vivarium.ledger)
                    (#:derive #:vivarium.derive)
                    (#:msg #:vivarium.message)
                    (#:tool #:vivarium.tool)
                    (#:agent #:vivarium.agent)
                    (#:loop* #:vivarium.loop)
                    (#:image-tools #:vivarium.image-tools)
                    (#:service #:vivarium.service)
                    (#:inspect #:vivarium.inspect)
                    (#:burden #:vivarium.burden)
                    (#:self #:vivarium.self))
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
