;;;; The outermost layer: one entry point for every run.
;;;;
;;;; Depends on everything and is depended on by nothing, which is the only
;;;; place a CLI belongs. Arm construction lives here rather than in each
;;;; experiment script -- that duplication is what this story exists to remove.

(defpackage #:viva.cli
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria)
                    (#:jzon #:com.inuoe.jzon)
                    (#:bt #:bordeaux-threads)
                    (#:tasks #:viva.tasks)
                    (#:msg #:viva.message)
                    (#:tool #:viva.tool)
                    (#:agent #:viva.agent)
                    (#:loop* #:viva.loop)
                    (#:image #:viva.image)
                    (#:ledger #:viva.ledger)
                    (#:image-tools #:viva.image-tools)
                    (#:tui #:viva.tui)
                    (#:usocket #:usocket)
                    (#:croatoan #:croatoan)
                    (#:provider #:viva.provider)
                    (#:models #:viva.models)
                    (#:console #:viva.console)
                    (#:harness #:viva.harness)
                    (#:mcp #:viva.mcp)
                    (#:workspace #:viva.workspace)
                    (#:env #:viva.env)
                    (#:session #:viva.session)
                    (#:trust #:viva.trust)
                    (#:germline #:viva.germline)
                    (#:config #:viva.config)
                    (#:daemon #:viva.daemon)
                    (#:actor #:viva.actor))
  (:export #:main #:arms-named #:available-arms
           #:render #:broadcast #:transcript #:screen
           #:trajectory-line #:ledger-lines #:score-line #:one-line
           #:arm #:arm-label #:arm-provider #:arm-model #:arm-effort))
