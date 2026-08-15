;;;; Core packages: the harness, with no knowledge of any particular task.

(defpackage #:vivarium.message
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria))
  (:export #:text #:make-text #:text-p #:text-value
           #:thinking #:make-thinking #:thinking-p #:thinking-value
           #:tool-call #:make-tool-call #:tool-call-p
           #:tool-call-id #:tool-call-name #:tool-call-arguments
           #:message #:message-p #:message-role #:message-content
           #:assistant-message #:make-assistant-message #:assistant-message-p
           #:assistant-message-stop-reason #:assistant-message-usage
           #:user-message #:make-user-message #:user-message-p
           #:tool-result-message #:make-tool-result-message #:tool-result-message-p
           #:tool-result-message-call-id #:tool-result-message-output
           #:tool-result-message-error-p
           #:tool-calls-in #:text-of))

(defpackage #:vivarium.wire
  (:use #:cl)
  (:export #:present #:field #:text-field #:reasoning-field #:+reasoning-keys+))

(defpackage #:vivarium.schema
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria))
  (:export #:parameter-schema #:validate #:type-label #:parameter-label #:obj))

(defpackage #:vivarium.sexp
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria))
  (:export #:read-form #:call-arguments #:unreadable #:unreadable-detail #:*limit*
           #:grammar-for #:grammar-for-tools #:form-grammar #:tool-rule
           #:*channel-prefix* #:grammar-prefix-for))

(defpackage #:vivarium.tool
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria)
                    (#:schema #:vivarium.schema)
                    (#:msg #:vivarium.message))
  (:export #:tool #:tool-name #:tool-description #:tool-parameters
           #:execute #:tool-result #:make-tool-result
           #:tool-result-output #:tool-result-error-p #:tool-result-terminate-p
           #:define-tool #:function-tool #:tool-body))

(defpackage #:vivarium.agent
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria)
                    (#:msg #:vivarium.message)
                    (#:tool #:vivarium.tool))
  (:export #:agent #:agent-model #:agent-temperature #:agent-seed
           #:agent-max-tokens #:agent-parallel-tools-p #:agent-reasoning-effort
           #:agent-stream-p #:agent-abort-on-steer-p #:should-abort-p #:agent-grammar
           #:agent-provider
           #:system-prompt #:tools #:steering-messages #:follow-up-messages
           #:prepare-next-turn #:should-stop-after-turn #:emit
           #:queued-agent #:queue-steering #:queue-follow-up))

(defpackage #:vivarium.stream
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria)
                    (#:jzon #:com.inuoe.jzon)
                    (#:wire #:vivarium.wire)
                    (#:msg #:vivarium.message))
  (:export #:collect #:consume #:absorb #:payload-of
           #:accumulator #:make-accumulator #:assistant-message #:acc-usage))

(defpackage #:vivarium.provider
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria)
                    (#:agent #:vivarium.agent))
  (:export #:provider #:provider-endpoint #:provider-api-key #:provider-name
           #:make-default-provider
           #:headers #:supports-grammar-p #:constrained-output-prefix #:augment-payload
           #:llama-cpp #:llama-cpp-provider #:+harmony-output-prefix+
           #:openai #:openai-provider))

(defpackage #:vivarium.client
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria)
                    (#:jzon #:com.inuoe.jzon)
                    (#:dex #:dexador)
                    (#:wire #:vivarium.wire)
                    (#:msg #:vivarium.message)
                    (#:schema #:vivarium.schema)
                    (#:tool #:vivarium.tool)
                    (#:stream #:vivarium.stream)
                    (#:provider #:vivarium.provider)
                    (#:agent #:vivarium.agent))
  (:export #:complete #:request-payload #:client-error #:client-error-detail))

(defpackage #:vivarium.loop
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria)
                    (#:msg #:vivarium.message)
                    (#:tool #:vivarium.tool)
                    (#:agent #:vivarium.agent)
                    (#:client #:vivarium.client))
  (:export #:run #:context #:make-context #:context-messages))

