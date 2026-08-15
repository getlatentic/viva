;;;; Two ways to run the workspace agent.
;;;;
;;;; The library is the product; these are thin. A shell is a listener that
;;;; paints events onto a terminal, and an IPC server is a listener that writes
;;;; them as JSON. Neither knows anything the library does not, which is the
;;;; test of whether the library is actually reusable.

(defpackage #:vivarium.console
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria)
                    (#:bt #:bordeaux-threads)
                    (#:jzon #:com.inuoe.jzon)
                    (#:schema #:vivarium.schema)
                    (#:loop* #:vivarium.loop)
                    (#:wire #:vivarium.wire)
                    (#:msg #:vivarium.message)
                    (#:tool #:vivarium.tool)
                    (#:agent #:vivarium.agent)
                    (#:env #:vivarium.env)
                    (#:workspace #:vivarium.workspace)
                    (#:skill #:vivarium.skill)
                    (#:memory #:vivarium.memory)
                    (#:extension #:vivarium.extension)
                    (#:session #:vivarium.session)
                    (#:models #:vivarium.models)
                    (#:harness #:vivarium.harness))
  (:export #:run-shell #:run-ipc #:build-agent #:*colour*
           #:call-summary #:paint))
