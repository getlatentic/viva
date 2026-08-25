;;;; Two ways to run the workspace agent.
;;;;
;;;; The library is the product; these are thin. A shell is a listener that
;;;; paints events onto a terminal, and an IPC server is a listener that writes
;;;; them as JSON. Neither knows anything the library does not, which is the
;;;; test of whether the library is actually reusable.

(defpackage #:viva.console
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria)
                    (#:bt #:bordeaux-threads)
                    (#:jzon #:com.inuoe.jzon)
                    (#:schema #:viva.schema)
                    (#:loop* #:viva.loop)
                    (#:wire #:viva.wire)
                    (#:msg #:viva.message)
                    (#:tool #:viva.tool)
                    (#:agent #:viva.agent)
                    (#:env #:viva.env)
                    (#:workspace #:viva.workspace)
                    (#:skill #:viva.skill)
                    (#:memory #:viva.memory)
                    (#:extension #:viva.extension)
                    (#:session #:viva.session)
                    (#:models #:viva.models)
                    (#:harness #:viva.harness)
                    (#:compaction #:viva.compaction)
                    (#:template #:viva.template))
  (:export #:run-shell #:run-ipc #:build-agent #:*colour*
           #:call-summary #:paint))
