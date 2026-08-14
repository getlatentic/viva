;;;; The outermost layer: one entry point for every run.
;;;;
;;;; Depends on everything and is depended on by nothing, which is the only
;;;; place a CLI belongs. Arm construction lives here rather than in each
;;;; experiment script -- that duplication is what this story exists to remove.

(defpackage #:vivarium.cli
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria)
                    (#:jzon #:com.inuoe.jzon)
                    (#:bt #:bordeaux-threads)
                    (#:tasks #:vivarium.tasks)
                    (#:msg #:vivarium.message)
                    (#:tool #:vivarium.tool)
                    (#:agent #:vivarium.agent)
                    (#:loop* #:vivarium.loop)
                    (#:image #:vivarium.image)
                    (#:ledger #:vivarium.ledger)
                    (#:image-tools #:vivarium.image-tools)
                    (#:usocket #:usocket)
                    (#:croatoan #:croatoan)
                    (#:provider #:vivarium.provider))
  (:export #:main #:arms-named #:available-arms
           #:render #:broadcast #:transcript #:screen
           #:trajectory-line #:ledger-lines #:score-line #:one-line
           #:arm #:arm-label #:arm-provider #:arm-model #:arm-effort))
