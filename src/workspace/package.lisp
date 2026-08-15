;;;; Level 1 packages: the ordinary work an agent harness has to be able to do.
;;;;
;;;; Vivarium's first world was a live Lisp image, which made it a research
;;;; instrument that could not edit a file. These packages give it the other
;;;; world -- a directory, a shell, durable notes -- so that self-modification
;;;; has something to be self-modification FOR.
;;;;
;;;; The layering is the same one Pi settled on and the dependencies point the
;;;; same way:
;;;;
;;;;   env         a capability boundary: files and processes, nothing else
;;;;   glob/bound  pure text machinery, no I/O
;;;;   edit        exact replacement and diffs over strings
;;;;   workspace   the tools themselves, written against ENV only
;;;;   skill       instructions discovered on disk
;;;;   memory      instructions the agent keeps for itself
;;;;   extension   third-party code that adds tools, hooks and commands
;;;;   session     the transcript, durable across restarts
;;;;   harness     the wiring, and the only place that knows about all of them

(defpackage #:vivarium.env
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria))
  (:export #:environment #:local-environment #:make-local-environment
           #:env-cwd #:env-root
           #:absolute-path #:join-path #:relative-path #:parent-path #:base-name
           #:read-text #:read-bytes #:write-text #:file-info
           #:info-name #:info-path #:info-kind #:info-size
           #:list-directory #:ensure-directory #:delete-path #:path-exists-p
           #:exec #:exec-status #:exec-output
           #:env-error #:env-error-code #:env-error-path #:complain))

(defpackage #:vivarium.glob
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria))
  (:export #:matches-p #:compile-glob #:ignore-set #:make-ignore-set
           #:ignored-p #:add-ignore-file #:add-patterns #:+default-ignores+))

(defpackage #:vivarium.bound
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria))
  (:export #:truncate-head #:truncation #:truncation-text #:truncation-cut-p
           #:truncation-lines #:truncation-reason #:truncation-first-line-too-long-p
           #:format-size #:+max-lines+ #:+max-bytes+ #:*max-lines* #:*max-bytes*))

(defpackage #:vivarium.edit
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria))
  (:export #:apply-edits #:edit-failure #:edit-failure-detail
           #:unified-diff #:line-ending-of #:normalize-endings #:restore-endings))

(defpackage #:vivarium.workspace
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria)
                    (#:jzon #:com.inuoe.jzon)
                    (#:tool #:vivarium.tool)
                    (#:env #:vivarium.env)
                    (#:glob #:vivarium.glob)
                    (#:bound #:vivarium.bound)
                    (#:edit #:vivarium.edit))
  (:export #:*environment* #:environment #:with-environment #:display-path
           #:read-file #:write-file #:edit-file #:list-files #:find-files
           #:search-files #:run-bash #:*bash-timeout* #:walk
           #:read-tool #:write-tool #:edit-tool
           #:ls-tool #:find-tool #:grep-tool #:bash-tool
           #:file-tools #:search-tools #:tool-set
           #:build-system-prompt #:*base-prompt* #:tool-summaries))

(defpackage #:vivarium.skill
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria)
                    (#:env #:vivarium.env)
                    (#:glob #:vivarium.glob))
  (:export #:skill #:skill-name #:skill-description #:skill-content
           #:skill-path #:skill-hidden-p
           #:load-skills #:find-skill #:prompt-block #:invocation
           #:parse-frontmatter #:skill-warning #:warning-message #:warning-path))

(defpackage #:vivarium.memory
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria)
                    (#:tool #:vivarium.tool)
                    (#:env #:vivarium.env)
                    (#:workspace #:vivarium.workspace))
  (:export #:context-files #:context-block #:+context-names+
           #:memory-path #:read-memory #:record-memory
           #:remember #:memory-tool #:*memory-file*))

(defpackage #:vivarium.template
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria)
                    (#:env #:vivarium.env)
                    (#:skill #:vivarium.skill))
  (:export #:template #:make-template #:template-name #:template-description #:template-content
           #:template-path #:load-templates #:find-template #:expand #:replace-all))

(defpackage #:vivarium.extension
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria)
                    (#:tool #:vivarium.tool)
                    (#:env #:vivarium.env))
  (:export #:extension #:extension-name #:extension-path #:extension-tools
           #:extension-commands #:extension-hooks
           #:*registry* #:defextension #:register-extension #:loaded-extensions
           #:load-extensions #:extension-directories
           #:extension-description
           #:register-tool #:register-command #:register-provider #:on #:fire #:decide
           #:all-providers #:extension-providers
           #:hook #:command #:command-name #:command-description #:command-handler
           #:find-command #:all-commands #:all-tools #:reset-registry
           #:trust #:trusted-p #:trust-file))

(defpackage #:vivarium.session
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria)
                    (#:jzon #:com.inuoe.jzon)
                    (#:msg #:vivarium.message))
  (:export #:session #:session-p #:open-session #:session-path #:session-id
           #:session-entries #:session-cwd #:session-leaf #:session-parent
           #:record-entry #:append-entry #:append-record #:append-custom-message #:append-custom #:entries-of #:records-of
           #:close-session #:load-session #:session-messages #:latest-session
           #:session-directory #:usage-of #:+format-version+ #:+conversation-kinds+
           #:list-sessions #:search-sessions #:find-session #:describe-session #:slug
           #:summary #:summary-id #:summary-path #:summary-cwd #:summary-time
           #:summary-messages #:summary-opening
           #:ancestry #:context-entries #:children-of #:entry-at #:compact #:fork
           #:path-to-root #:branch-point #:abandoned-branch #:append-branch-summary
           #:object #:record-p #:entry #:entry-id #:entry-parent #:entry-kind #:entry-payload
           #:entry-time))

(defpackage #:vivarium.compaction
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria)
                    (#:msg #:vivarium.message)
                    (#:agent #:vivarium.agent)
                    (#:client #:vivarium.client))
  (:export #:settings #:make-settings #:settings-enabled-p #:settings-context-limit
           #:settings-reserve #:settings-keep-recent #:threshold #:due-p
           #:retained-tail #:rough-tokens #:summarise #:render #:+instruction+))

(defpackage #:vivarium.models
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria)
                    (#:provider #:vivarium.provider))
  (:export #:choice #:choice-label #:choice-provider #:choice-model #:choice-effort
           #:available-models #:resolve-model #:+catalogue+ #:choice-context-limit))

(defpackage #:vivarium.harness
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria)
                    (#:msg #:vivarium.message)
                    (#:tool #:vivarium.tool)
                    (#:agent #:vivarium.agent)
                    (#:loop* #:vivarium.loop)
                    (#:env #:vivarium.env)
                    (#:workspace #:vivarium.workspace)
                    (#:skill #:vivarium.skill)
                    (#:memory #:vivarium.memory)
                    (#:extension #:vivarium.extension)
                    (#:session #:vivarium.session)
                    (#:compaction #:vivarium.compaction)
                    (#:template #:vivarium.template))
  (:export #:workspace-agent #:make-workspace-agent #:agent-environment
           #:agent-skills #:agent-templates #:agent-session #:agent-extensions #:agent-listener
           #:agent-request-limit #:agent-requests #:agent-context #:agent-aborting
           #:agent-extra-tools #:agent-extra-prompt #:agent-resource-environment
           #:agent-extension-directories #:agent-compaction #:agent-active-tools
           #:compact-now #:set-model #:set-active-tools #:apply-settings
           #:send-message #:append-custom #:navigate #:tree-lines #:close-agent
           #:ask #:converse #:resume #:refresh-resources #:harness-tool-set #:record
           #:*agent* #:*default-model* #:*default-provider-name*))
