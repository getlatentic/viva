;;;; Level 1: the tools an agent needs to do ordinary work.
;;;;
;;;; Every tool is driven through TOOL:EXECUTE with a hash table of JSON-shaped
;;;; arguments -- the same path a model's call takes -- rather than through its
;;;; Lisp function. A tool can work perfectly when called directly and still be
;;;; unusable, because what the model sees is the schema and what it sends is a
;;;; hash table. This suite exists to make that distinction unable to hide.
;;;;
;;;; Several of these encode a bug that was actually shipped and found by
;;;; running the thing: the duplicated extension registration, the diff that
;;;; printed a hunk twice, the confinement that refused the harness's own
;;;; resource directories.

(in-package #:vivarium.tests)

(defun temporary-repository ()
  "A throwaway repository with a .gitignore, a nested source tree, a skill and
an instruction file. Returned as an unconfined environment over its root."
  (let* ((root (format nil "/tmp/vivarium-tests-~36r" (random (expt 2 48) (make-random-state t))))
         (environment (env:make-local-environment :cwd "/tmp")))
    (env:ensure-directory environment (format nil "~a/src/deep" root))
    (env:ensure-directory environment (format nil "~a/node_modules/junk" root))
    (env:ensure-directory environment (format nil "~a/.vivarium/skills/tidy" root))
    (flet ((put (relative content)
             (env:write-text environment (format nil "~a/~a" root relative) content)))
      (put ".gitignore" (format nil "node_modules/~%*.log~%"))
      (put "README.md" (format nil "# Probe~%"))
      (put "src/core.lisp" (format nil "~{~a~%~}"
                                   '("(defun total (items)"
                                     "  (reduce #'+ items))"
                                     ""
                                     "(defun average (items)"
                                     "  (/ (total items) (length items)))")))
      (put "src/deep/nested.lisp" "(defun nested () :here)")
      (put "node_modules/junk/huge.lisp" "(defun total () :decoy)")
      (put "debug.log" "ignored")
      (put ".vivarium/skills/tidy/SKILL.md"
           (format nil "---~%name: tidy~%description: How to tidy this repository.~%---~%Run the formatter.~%"))
      (put "VIVARIUM.md" "Always run `make check`."))
    (env:make-local-environment :cwd root)))

(defun discard-repository (environment)
  (ignore-errors
   (uiop:delete-directory-tree
    (uiop:parse-native-namestring (format nil "~a/" (env:env-cwd environment))) :validate t)))

(defmacro with-repository ((environment) &body body)
  `(let ((,environment (temporary-repository)))
     (unwind-protect (let ((workspace:*environment* ,environment)) ,@body)
       (discard-repository ,environment))))

(defun run-tool (tool &rest plist)
  "Run TOOL the way the loop does. Returns (values OUTPUT ERROR-P).

EVERY TEST FILE SHARES ONE PACKAGE, so a helper here silently replaces one of
the same name anywhere else and breaks tests in files it never mentions. It has
happened twice: CALL-TOOL, then SAY. `vivarium check` now refuses a duplicate
rather than leaving it to be rediscovered a third time."
  (let ((result (tool:execute tool (apply #'args plist) nil)))
    (values (tool:tool-result-output result) (tool:tool-result-error-p result))))

(defun mentions (needle text) (and (search needle text) t))

;;; Reading

(define-test "read returns a file and reports where to continue"
  (with-repository (environment)
    (declare (ignore environment))
    (true (mentions "(defun average" (run-tool workspace:read-tool "path" "src/core.lisp")))
    (let ((partial (run-tool workspace:read-tool "path" "src/core.lisp" "offset" 1 "limit" 2)))
      (true (mentions "Use offset=3 to continue" partial))
      (false (mentions "(defun average" partial)))))

(define-test "read names what was wrong rather than failing obscurely"
  (with-repository (environment)
    (declare (ignore environment))
    (multiple-value-bind (output error-p) (run-tool workspace:read-tool "path" "nope.lisp")
      (true error-p)
      (true (mentions "No such file" output)))
    ;; The schema layer, not the tool body: a tool that receives a missing
    ;; argument as NIL fails somewhere inside itself, and the model is told
    ;; about that internal failure instead of about the call it got wrong.
    (true (mentions "missing required: path" (run-tool workspace:read-tool "offset" 2)))))

;;; Searching

(define-test "find and grep skip what .gitignore excludes"
  (with-repository (environment)
    (declare (ignore environment))
    (let ((found (run-tool workspace:find-tool "pattern" "*.lisp")))
      (true (mentions "src/deep/nested.lisp" found))
      (false (mentions "node_modules" found)))
    (let ((matches (run-tool workspace:grep-tool "pattern" "defun total")))
      (true (mentions "src/core.lisp:1:(defun total" matches))
      (false (mentions "node_modules" matches)))))

(define-test "a pattern with no slash matches on the file name at any depth"
  (true (glob:matches-p "*.lisp" "src/deep/nested.lisp"))
  (true (glob:matches-p "src/**/*.lisp" "src/deep/nested.lisp"))
  ;; The globstar has to match nothing at all, or **/*.lisp misses the root.
  (true (glob:matches-p "**/*.lisp" "core.lisp"))
  (false (glob:matches-p "src/*.lisp" "src/deep/nested.lisp")))

(define-test "a malformed regular expression is a tool error, not a crash"
  (with-repository (environment)
    (declare (ignore environment))
    (multiple-value-bind (output error-p) (run-tool workspace:grep-tool "pattern" "(defun total (items)")
      (true error-p)
      (true (mentions "literal" output)))
    (true (mentions "core.lisp" (run-tool workspace:grep-tool "pattern" "(defun total (items)"
                                           "literal" t)))))

;;; Editing

(define-test "an ambiguous or absent edit target is refused"
  (with-repository (environment)
    (declare (ignore environment))
    (multiple-value-bind (output error-p)
        (run-tool workspace:edit-tool "path" "src/core.lisp"
                   "edits" (vector (args "old_text" "items" "new_text" "xs")))
      (true error-p)
      (true (mentions "matches" output)))
    (multiple-value-bind (output error-p)
        (run-tool workspace:edit-tool "path" "src/core.lisp"
                   "edits" (vector (args "old_text" "absent" "new_text" "x")))
      (true error-p)
      (true (mentions "did not match" output)))
    ;; Refused means refused: neither attempt may have written anything.
    (true (mentions "(reduce #'+ items))" (run-tool workspace:read-tool "path" "src/core.lisp")))))

(define-test "edits arrive in whichever shape the model sent them"
  (with-repository (environment)
    (declare (ignore environment))
    (true (mentions "Replaced 1 block"
                    (run-tool workspace:edit-tool "path" "src/core.lisp"
                               "edits" "[{\"old_text\": \"(defun total\", \"new_text\": \"(defun sum-of\"}]")))
    (true (mentions "Replaced 1 block"
                    (run-tool workspace:edit-tool "path" "src/core.lisp"
                               "old_text" "(defun sum-of" "new_text" "(defun total"
                               "edits" #())))))

(define-test "edits close enough to touch are shown as one hunk"
  ;; Two hunks whose context overlaps print the same lines twice, and the second
  ;; shows an already-replaced line as unchanged context -- a diff that
  ;; contradicts itself.
  (let* ((text (format nil "~{~a~%~}" '("one" "two" "three" "four" "five")))
         (diff (nth-value 1 (edit:apply-edits text '(("one" . "ONE") ("three" . "THREE"))))))
    (let ((rendered (edit:unified-diff "f" text diff)))
      (is = 1 (count-if (lambda (line) (search "@@" line))
                        (uiop:split-string rendered :separator (string #\Newline))))
      (true (mentions "-one" rendered))
      (true (mentions "+THREE" rendered)))))

(define-test "distant edits are shown as separate hunks"
  (let* ((text (format nil "~{~a~%~}" (loop for index from 1 to 40 collect (format nil "line ~2,'0d" index))))
         (placements (nth-value 1 (edit:apply-edits text '(("line 02" . "LINE 02") ("line 30" . "LINE 30"))))))
    (is = 2 (count-if (lambda (line) (search "@@" line))
                      (uiop:split-string (edit:unified-diff "f" text placements)
                                         :separator (string #\Newline))))))

;;; Skills, memory, extensions

(define-test "a skill advertises its description and withholds its body"
  (with-repository (environment)
    (multiple-value-bind (skills warnings) (skill:load-skills environment (list ".vivarium/skills"))
      (is = 0 (length warnings))
      (is = 1 (length skills))
      (is string= "tidy" (skill:skill-name (first skills)))
      (true (mentions "Run the formatter" (skill:skill-content (first skills))))
      (false (mentions "description:" (skill:skill-content (first skills))))
      (let ((block* (skill:prompt-block skills)))
        (true (mentions "<name>tidy</name>" block*))
        ;; The body must stay out of the prompt, or forty skills cost forty
        ;; files of context instead of forty lines.
        (false (mentions "Run the formatter" block*))))))

(define-test "what the agent remembers is loaded back as instructions"
  (with-repository (environment)
    (true (mentions "make check"
                    (memory:context-block (memory:context-files environment))))
    (run-tool memory:remember "note" "The build is `make check`.")
    (run-tool memory:remember "note" "The parser lives in src/core.lisp.")
    (let ((block* (memory:context-block (memory:context-files environment))))
      (true (mentions "The build is" block*))
      (true (mentions "The parser lives" block*)))))

(define-test "reloading extensions does not duplicate their tools"
  ;; Appending rather than replacing put two tools of the same name in the
  ;; request, which the provider rejects as malformed -- surfacing as a 400 on
  ;; the request AFTER the one that reloaded.
  (with-repository (environment)
    (let ((extension:*registry* '()))
      (env:ensure-directory environment ".vivarium/extensions")
      (env:write-text environment ".vivarium/extensions/probe.lisp"
                      "(in-package #:vivarium.extension)
(defextension \"probe\"
  :description \"A probe.\"
  (register-tool (make-instance 'vivarium.tool:function-tool
                                :name \"probe_ping\" :description \"Ping.\" :parameters '()
                                :body (lambda (a c) (declare (ignore a c)) \"pong\"))))")
      (let ((directories (list (env:join-path (env:env-cwd environment) ".vivarium" "extensions"))))
        (dotimes (round 3)
          (is = 0 (length (extension:load-extensions environment :directories directories
                                                                 :require-trust nil)))
          (is = 1 (length (extension:all-tools)))))
      (is string= "pong" (run-tool (first (extension:all-tools)))))))

(define-test "a project's extensions do not load until the project is trusted"
  (with-repository (environment)
    (let ((extension:*registry* '()))
      (env:ensure-directory environment ".vivarium/extensions")
      (env:write-text environment ".vivarium/extensions/probe.lisp" "(in-package #:cl-user)")
      (let ((complaints (extension:load-extensions
                         environment
                         :directories (list (env:join-path (env:env-cwd environment)
                                                           ".vivarium" "extensions")))))
        (is = 1 (length complaints))
        (true (mentions "not a trusted project" (first complaints)))))))

(define-test "a broken extension is reported rather than fatal"
  (with-repository (environment)
    (let ((extension:*registry* '()))
      (env:ensure-directory environment ".vivarium/extensions")
      (env:write-text environment ".vivarium/extensions/broken.lisp" "(this is not valid lisp")
      (let ((complaints (extension:load-extensions
                         environment
                         :directories (list (env:join-path (env:env-cwd environment)
                                                           ".vivarium" "extensions"))
                         :require-trust nil)))
        (is = 1 (length complaints))
        (true (mentions "did not load" (first complaints)))))))

;;; Confinement

(define-test "a root refuses paths outside it and permits paths inside"
  (with-repository (environment)
    (let ((workspace:*environment* (env:make-local-environment :cwd (env:env-cwd environment)
                                                               :root (env:env-cwd environment))))
      (multiple-value-bind (output error-p) (run-tool workspace:read-tool "path" "/etc/hosts")
        (true error-p)
        (true (mentions "Refused" output)))
      (true (mentions "(defun total" (run-tool workspace:read-tool "path" "src/core.lisp"))))))

(define-test "confinement does not stop the harness reading its own resources"
  ;; A rooted agent used to refuse to start, one second in, on the home
  ;; directory's extension folder -- a path the agent had not asked for.
  (with-repository (environment)
    (let ((extension:*registry* '()))
      (multiple-value-bind (agent complaints)
          (harness:make-workspace-agent :cwd (env:env-cwd environment)
                                        :root (env:env-cwd environment))
        (declare (ignore complaints))
        (is = 1 (length (harness:agent-skills agent)))
        (true (mentions "make check" (agent:system-prompt agent)))
        (true (mentions "<name>tidy</name>" (agent:system-prompt agent)))))))

;;; Sessions

(define-test "a transcript survives the round trip with its tool calls intact"
  (let* ((directory (uiop:parse-native-namestring
                     (format nil "/tmp/vivarium-tests-session-~36r/" (random (expt 2 40) (make-random-state t)))))
         (session (session:open-session :directory directory)))
    (unwind-protect
         (progn
           (session:record-entry session :message
                                 (msg:make-user-message :content (list (msg:make-text "find the bug"))))
           (session:record-entry session :message
                                 (msg:make-assistant-message
                                  :content (list (msg:make-tool-call :id "c1" :name "read"
                                                                     :arguments (args "path" "src/core.lisp")))
                                  :stop-reason :tool-calls))
           (session:record-entry session :message
                                 (msg:make-tool-result-message :call-id "c1" :output "..."))
           (session:close-session session)
           (let ((messages (session:session-messages (session:load-session (session:session-path session)))))
             (is = 3 (length messages))
             (is string= "find the bug" (msg:text-of (first messages)))
             ;; The ids are the part that matters: a transcript whose calls and
             ;; results no longer line up cannot be resumed, because the
             ;; provider rejects the conversation.
             (is string= "c1" (msg:tool-call-id (first (msg:tool-calls-in (second messages)))))
             (is string= "src/core.lisp"
                 (gethash "path" (msg:tool-call-arguments
                                  (first (msg:tool-calls-in (second messages))))))
             (is eq :tool-calls (msg:assistant-message-stop-reason (second messages)))
             (is string= "c1" (msg:tool-result-message-call-id (third messages)))))
      (ignore-errors (uiop:delete-directory-tree directory :validate t)))))

;;; The shell's command table

(define-test "every shell command can actually be invoked"
  ;; The handlers are reached through a table, so an arity mistake is invisible
  ;; to the compiler and shows up as `invalid number of arguments` the first
  ;; time a person types the command.
  (with-repository (environment)
    (let ((extension:*registry* '()))
      (let ((agent (harness:make-workspace-agent :cwd (env:env-cwd environment)))
            (out (make-broadcast-stream)))
        (dolist (verb (symbol-value (find-symbol "+VERBS+" "VIVARIUM.CONSOLE")))
          (unless (member (funcall (find-symbol "VERB-NAME" "VIVARIUM.CONSOLE") verb)
                          '("exit" "trust" "skill") :test #'string=)
            (finish (funcall (funcall (find-symbol "VERB-HANDLER" "VIVARIUM.CONSOLE") verb)
                             agent "" out))))))))

;;; The session, through the path that actually writes it

(defclass replaying-agent (harness:workspace-agent)
  ((script :initarg :script :accessor script)))

(defmethod client:complete ((agent replaying-agent) messages)
  (declare (ignore messages))
  (or (pop (script agent))
      (msg:make-assistant-message :content (list (msg:make-text "done")) :stop-reason :stop)))

(define-test "a run records its tool results, not only its assistant messages"
  ;; The encoder was tested by handing it a tool result directly, which says
  ;; nothing about whether anything ever hands it one. Nothing did: the loop
  ;; pushes results into the context without emitting a :MESSAGE, so every
  ;; recorded transcript held calls with no results and could not be resumed.
  (with-repository (environment)
    (let* ((directory (uiop:parse-native-namestring
                       (format nil "~a/.sessions/" (env:env-cwd environment))))
           (session (session:open-session :directory directory))
           (agent (make-instance 'replaying-agent
                                 :environment environment
                                 :resource-environment environment
                                 :session session
                                 :script (list (msg:make-assistant-message
                                                :content (list (msg:make-tool-call
                                                                :id "c1" :name "ls"
                                                                :arguments (args)))
                                                :stop-reason :tool-calls)))))
      (workspace:with-environment (environment)
        (loop*:run agent (list (msg:make-user-message
                                :content (list (msg:make-text "what is here?"))))))
      (session:close-session session)
      (let ((messages (session:session-messages (session:load-session (session:session-path session)))))
        (is = 1 (count-if #'msg:tool-result-message-p messages))
        (is string= "c1" (msg:tool-result-message-call-id
                          (find-if #'msg:tool-result-message-p messages)))
        (true (mentions "README.md" (msg:tool-result-message-output
                                     (find-if #'msg:tool-result-message-p messages))))))))

(define-test "an empty file reads as empty rather than failing"
  (with-repository (environment)
    (env:write-text environment "blank.py" "")
    (multiple-value-bind (output error-p) (run-tool workspace:read-tool "path" "blank.py")
      (false error-p)
      (is string= "" output))))

(define-test "records sit beside the conversation and never enter it"
  ;; Pi's split, and it earns its place immediately: telemetry has to interleave
  ;; with the turn that produced it, and must not be sent back to a model.
  (with-repository (environment)
    (let* ((directory (uiop:parse-native-namestring
                       (format nil "~a/.sessions/" (env:env-cwd environment))))
           (session (session:open-session :directory directory)))
      (session:record-entry session :message
                            (msg:make-user-message :content (list (msg:make-text "hello"))))
      (session:append-record session :tool-finished "name" "read" "ms" 12)
      (session:append-record session :usage "prompt_tokens" 100 "completion_tokens" 7)
      (session:close-session session)
      (let* ((reloaded (session:load-session (session:session-path session)))
             (entries (session:entries-of reloaded))
             (messages (session:session-messages reloaded)))
        ;; One message and two records. The header is not an entry -- it sets
        ;; the session's own fields.
        (is = 3 (length entries))
        (is = 1 (length messages))
        (is string= "hello" (msg:text-of (first messages)))
        (is = 2 (length (session:records-of entries)))
        (is = 1 (length (session:records-of entries :usage)))
        (is = 100 (gethash "prompt_tokens"
                           (session:entry-payload
                            (first (session:records-of entries :usage)))))))))

;;; The session tree

(defun ws-scratch-session ()
  (session:open-session
   :directory (uiop:parse-native-namestring
               (format nil "/tmp/vivarium-tests-session-~36r/" (random (expt 2 40) (make-random-state t))))
   :cwd "/somewhere"))

(defun ws-say (session role text)
  (session:record-entry session :message
                        (if (eq :user role)
                            (msg:make-user-message :content (list (msg:make-text text)))
                            (msg:make-assistant-message :content (list (msg:make-text text))))))

(define-test "a session round-trips through the file, tree and all"
  (let ((session (ws-scratch-session)))
    (ws-say session :user "one")
    (ws-say session :assistant "two")
    (session:append-record session :usage "prompt_tokens" 10 "completion_tokens" 2)
    (ws-say session :user "three")
    (session:close-session session)
    (let ((reloaded (session:load-session (session:session-path session))))
      (is string= "/somewhere" (session:session-cwd reloaded))
      ;; Records are in the file and out of the conversation.
      (is = 1 (length (session:records-of reloaded)))
      (is = 3 (length (session:context-entries reloaded)))
      (is = 3 (length (session:session-messages reloaded)))
      (is string= "three" (msg:text-of (first (last (session:session-messages reloaded)))))
      ;; And the tree really is a chain, not a pile.
      (let ((chain (session:context-entries reloaded)))
        (false (session:entry-parent (first chain)))
        (is string= (session:entry-id (first chain))
            (session:entry-parent (second chain)))))))

(define-test "a branch shares its history and neither side is copied"
  (let ((session (ws-scratch-session)))
    (ws-say session :user "shared")
    (let ((fork-point (session:session-leaf session)))
      (ws-say session :user "down the first branch")
      (is = 2 (length (session:session-messages session)))
      ;; Go back and take the other road.
      (session:fork session fork-point)
      (ws-say session :user "down the second branch")
      (let ((messages (session:session-messages session)))
        (is = 2 (length messages))
        (is string= "shared" (msg:text-of (first messages)))
        (is string= "down the second branch" (msg:text-of (second messages))))
      ;; Both children hang off the same parent, in one file.
      (is = 2 (length (session:children-of session fork-point))))))

(define-test "compaction replaces the past and keeps the tail"
  (let ((session (ws-scratch-session)))
    (dolist (text '("first" "second" "third" "fourth"))
      (ws-say session :user text))
    (session:compact session "They discussed four things." :keep 1)
    (ws-say session :user "after")
    (let ((messages (session:session-messages session)))
      ;; summary + retained tail + the new turn
      (is = 3 (length messages))
      (true (mentions "They discussed four things" (msg:text-of (first messages))))
      (is string= "fourth" (msg:text-of (second messages)))
      (is string= "after" (msg:text-of (third messages))))
    ;; Nothing was destroyed: the pre-compaction turns are still on disk.
    (session:close-session session)
    (let ((reloaded (session:load-session (session:session-path session))))
      ;; Four turns before the compaction, one after: all still on disk, and
      ;; reachable by walking a leaf that predates the compaction.
      (is = 5 (count :message (session:entries-of reloaded) :key #'session:entry-kind))
      (is = 1 (count :compaction (session:entries-of reloaded) :key #'session:entry-kind)))))

(define-test "a run can be resumed from what was written"
  (with-repository (environment)
    (let* ((directory (uiop:parse-native-namestring
                       (format nil "~a/.sessions/" (env:env-cwd environment))))
           (session (session:open-session :directory directory)))
      (ws-say session :user "what is here?")
      (session:record-entry session :message
                            (msg:make-assistant-message
                             :content (list (msg:make-tool-call :id "c1" :name "ls" :arguments (args)))
                             :stop-reason :tool-calls))
      (session:record-entry session :message
                            (msg:make-tool-result-message :call-id "c1" :output "README.md"))
      (session:close-session session)
      (let ((agent (harness:make-workspace-agent :cwd (env:env-cwd environment)
                                                 :load-resources nil)))
        (multiple-value-bind (agent restored)
            (harness:resume agent (session:session-path session))
          (is = 3 restored)
          ;; The tool call and its result must both come back, and in order, or
          ;; the provider rejects the conversation on the very next request.
          (let ((messages (loop*:context-messages (harness:agent-context agent))))
            (is = 3 (length messages))
            (is string= "c1" (msg:tool-call-id (first (msg:tool-calls-in (second messages)))))
            (is string= "c1" (msg:tool-result-message-call-id (third messages)))))))))

;;; Compaction

(defun ws-turn (role text &key calls result-for)
  (cond (result-for (msg:make-tool-result-message :call-id result-for :output text))
        ((eq :assistant role)
         (msg:make-assistant-message
          :content (append (when (plusp (length text)) (list (msg:make-text text)))
                           (mapcar (lambda (id) (msg:make-tool-call :id id :name "ls" :arguments (args)))
                                   calls))
          :stop-reason (if calls :tool-calls :stop)))
        (t (msg:make-user-message :content (list (msg:make-text text))))))

(define-test "compaction triggers on the provider's count, never an estimate"
  (let ((settings (compaction:make-settings :context-limit 1000 :reserve 200)))
    (false (compaction:due-p settings 0))
    (false (compaction:due-p settings 799))
    (true (compaction:due-p settings 800))
    (false (compaction:due-p (compaction:make-settings :enabled-p nil :context-limit 1000 :reserve 200)
                             900))))

(define-test "the retained tail never begins on an orphaned tool result"
  ;; A result whose call was summarised away is rejected by every provider, so
  ;; the tail extends backwards over the assistant message that made the calls
  ;; -- and over ALL of a parallel batch, not just the last one.
  (let ((messages (list (ws-turn :user "old news")
                        (ws-turn :assistant "working" :calls '("c1" "c2"))
                        (ws-turn nil "first result" :result-for "c1")
                        (ws-turn nil "second result" :result-for "c2")
                        (ws-turn :assistant "done"))))
    (dolist (budget '(1 5 20 500))
      (let ((tail (compaction:retained-tail messages budget)))
        (true (plusp (length tail)))
        (false (msg:tool-result-message-p (first tail)))))
    ;; A budget that only fits the last message still keeps it.
    (is = 1 (length (compaction:retained-tail messages 1)))))

(defclass compacting-agent (harness:workspace-agent)
  ((script :initarg :script :accessor script)
   (summarised :initform nil :accessor summarised)))

(defmethod client:complete ((agent compacting-agent) messages)
  (declare (ignore messages))
  (or (pop (script agent))
      (msg:make-assistant-message :content (list (msg:make-text "done")) :stop-reason :stop)))

(defmethod compaction:summarise ((agent compacting-agent) messages &key instruction)
  (declare (ignore instruction))
  ;; The summariser normally builds a bare scribe agent of its own, so
  ;; overriding CLIENT:COMPLETE here would not reach it and the test would go to
  ;; the network. Overriding SUMMARISE is the seam.
  (setf (summarised agent) messages)
  (or (pop (script agent)) "a summary"))

(define-test "a compaction replaces the context and is written to the session"
  (with-repository (environment)
    (let* ((directory (uiop:parse-native-namestring
                       (format nil "~a/.sessions/" (env:env-cwd environment))))
           (session (session:open-session :directory directory))
           (agent (make-instance 'compacting-agent
                                 :environment environment :resource-environment environment
                                 :session session
                                 ;; The summariser's reply, when COMPACT-NOW asks.
                                 :script (list "They looked at three files."))))
      (setf (harness:agent-context agent)
            (loop*:make-context :messages (list (ws-turn :user "one")
                                                (ws-turn :assistant "two")
                                                (ws-turn :user "three")))
            (harness:agent-compaction agent)
            (compaction:make-settings :keep-recent 1))
      (let ((context (harness:compact-now agent)))
        (true context)
        (let ((messages (loop*:context-messages context)))
          ;; The summary, then whatever tail fitted.
          (true (mentions "They looked at three files" (msg:text-of (first messages))))
          (true (<= (length messages) 3))
          (is string= "three" (msg:text-of (first (last messages))))))
      (session:close-session session)
      (let ((reloaded (session:load-session (session:session-path session))))
        (is = 1 (count :compaction (session:entries-of reloaded) :key #'session:entry-kind))
        ;; And the compaction is what the resumed conversation starts from.
        (true (mentions "They looked at three files"
                        (msg:text-of (first (session:session-messages reloaded)))))))))

(define-test "an extension can cancel a compaction or write its own summary"
  (with-repository (environment)
    (let ((extension:*registry* '()))
      (let ((agent (make-instance 'compacting-agent
                                  :environment environment :resource-environment environment
                                  :script '())))
        (setf (harness:agent-context agent)
              (loop*:make-context :messages (list (ws-turn :user "one") (ws-turn :user "two")))
              (harness:agent-compaction agent) (compaction:make-settings :keep-recent 1))
        ;; Written the way an extension author would, so the test exercises the
        ;; public path rather than the registry's internals.
        (extension:defextension "veto"
          :description "Refuses every compaction."
          (extension:on :before-compaction (lambda (event) (declare (ignore event)) :cancel)))
        ;; Cancelled: no model request is made, and the script is empty, so a
        ;; summariser that ran at all would error rather than return NIL.
        (false (harness:compact-now agent))))))

;;; Runtime tool control

(define-test "the active tool set narrows what the model is offered"
  (with-repository (environment)
    (let ((extension:*registry* '()))
      (let ((agent (harness:make-workspace-agent :cwd (env:env-cwd environment)
                                                 :load-resources nil)))
        (is = 8 (length (agent:tools agent)))
        (setf (harness:agent-active-tools agent) '("read" "grep"))
        (is = 2 (length (agent:tools agent)))
        (is equal '("read" "grep") (mapcar #'tool:tool-name (agent:tools agent)))
        ;; NIL means all of them, not none -- an agent that disabled everything
        ;; by clearing the list could never re-enable anything.
        (setf (harness:agent-active-tools agent) nil)
        (is = 8 (length (agent:tools agent)))))))
