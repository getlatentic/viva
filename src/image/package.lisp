;;;; Image packages: the live-Lisp-image task domain the harness acts on.

(defpackage #:vivarium.ledger
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria)
                    (#:bt #:bordeaux-threads)
                    (#:jzon #:com.inuoe.jzon))
  (:export #:ledger #:make-ledger #:ledger-path
           #:record #:entries #:latest-source #:previous-source #:reset
           #:entry #:entry-id #:entry-timestamp #:entry-target #:entry-source
           #:entry-previous-source #:entry-note #:entry-outcome #:entry-json))

(defpackage #:vivarium.image
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria)
                    (#:ledger #:vivarium.ledger))
  (:export #:install-definition #:definition-source #:rollback-definition
           #:find-targets #:sbcl-image #:image-ledger #:image-package
           #:installation #:make-installation #:installation-target
           #:installation-warnings #:installation-error
           #:install-error #:install-error-detail
           #:definition-symbol #:form-target #:read-one-form))

(defpackage #:vivarium.derive
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria)
                    (#:tool #:vivarium.tool))
  (:export #:derive-tool #:build-parameters #:json-type #:split-lambda-list
           #:argument-types))

(defpackage #:vivarium.image-tools
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria)
                    (#:tool #:vivarium.tool)
                    (#:image #:vivarium.image))
  (:export #:*backend* #:*bash-timeout* #:*bash-directory* #:*bash-commands*
           #:*system-prompt* #:tool-set
           #:read-definition #:install #:rollback #:find-definitions #:bash))

(defpackage #:vivarium.inspect
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria)
                    (#:tool #:vivarium.tool)
                    (#:image #:vivarium.image))
  (:export #:*package-under-inspection* #:*handles* #:*handle-counter*
           #:begin-inspection-session #:tool-set #:inspect-value #:call-function
           #:*callable* #:capture-callables #:callable-check #:install-definition))

(defpackage #:vivarium.self
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria)
                    (#:tool #:vivarium.tool)
                    (#:schema #:vivarium.schema)
                    (#:image #:vivarium.image)
                    (#:derive #:vivarium.derive)
                    (#:agent #:vivarium.agent))
  (:export #:*agent* #:with-self-extension #:add-tool #:tool-set
           #:register-tool #:remember))

