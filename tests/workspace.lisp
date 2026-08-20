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
      (let* ((agent (harness:make-workspace-agent :cwd (env:env-cwd environment)
                                                  :load-resources nil))
             (everything (mapcar #'tool:tool-name (agent:tools agent))))
        ;; Named rather than counted: a bare number breaks every time a tool is
        ;; added, and says nothing about which ones are there.
        (dolist (name '("read" "write" "edit" "ls" "find" "grep" "bash" "remember" "delegate"))
          (true (member name everything :test #'string=)))
        (setf (harness:agent-active-tools agent) '("read" "grep"))
        (is equal '("read" "grep") (mapcar #'tool:tool-name (agent:tools agent)))
        ;; NIL means all of them, not none -- an agent that disabled everything
        ;; by clearing the list could never re-enable anything.
        (setf (harness:agent-active-tools agent) nil)
        (is = (length everything) (length (agent:tools agent)))))))

;;; Resume

(define-test "a resumed session restores the settings it was run under"
  ;; A conversation replayed under a different model or a wider tool set is not
  ;; the conversation that was recorded, and the transcript gives no sign.
  (with-repository (environment)
    (let* ((directory (uiop:parse-native-namestring
                       (format nil "~a/.sessions/" (env:env-cwd environment))))
           (session (session:open-session :directory directory))
           (agent (harness:make-workspace-agent :cwd (env:env-cwd environment)
                                                :session session :load-resources nil)))
      (ws-say session :user "hello")
      (harness:set-model agent "some-other-model")
      (harness:set-active-tools agent '("read"))
      (session:close-session session)
      (let ((fresh (harness:make-workspace-agent :cwd (env:env-cwd environment)
                                                 :model "default-model" :load-resources nil)))
        (harness:resume fresh (session:session-path session))
        (is string= "some-other-model" (agent:agent-model fresh))
        (is equal '("read") (harness:agent-active-tools fresh))
        (is = 1 (length (agent:tools fresh)))))))

(define-test "sessions are found by project, and by prefix of an id"
  (let* ((where "/tmp/vivarium-tests-project")
         (directory (session:session-directory where)))
    (ignore-errors (uiop:delete-directory-tree directory :validate t))
    (let ((session (session:open-session :directory directory :cwd where)))
      (ws-say session :user "the opening question")
      (session:close-session session)
      (let ((found (session:list-sessions :cwd where)))
        (is = 1 (length found))
        (is string= where (session:summary-cwd (first found)))
        (is = 1 (session:summary-messages (first found)))
        (true (mentions "the opening question" (session:summary-opening (first found))))
        ;; And by any unambiguous prefix, which is what a person types.
        (let ((id (session:summary-id (first found))))
          (is string= id (session:summary-id (session:find-session (subseq id 0 8) :cwd where)))
          (is string= id (session:summary-id (session:latest-session where)))))
      (ignore-errors (uiop:delete-directory-tree directory :validate t)))))

;;; Prompt templates

(define-test "a template substitutes positional arguments and the whole string"
  (is string= "review src/a.lisp carefully"
      (template:expand (template:make-template :name "r" :content "review $1 carefully")
                       "src/a.lisp"))
  (is string= "compare src/a.lisp with src/b.lisp"
      (template:expand (template:make-template :name "r" :content "compare $1 with $2")
                       "src/a.lisp src/b.lisp"))
  (is string= "look at src/a.lisp src/b.lisp"
      (template:expand (template:make-template :name "r" :content "look at $ARGUMENTS")
                       "src/a.lisp src/b.lisp"))
  ;; A missing argument becomes empty rather than leaving the marker in place --
  ;; a literal $2 reaching the model is a prompt about a dollar sign.
  (is string= "compare src/a.lisp with "
      (template:expand (template:make-template :name "r" :content "compare $1 with $2")
                       "src/a.lisp")))

(define-test "a template with no placeholder still receives its arguments"
  ;; The commonest template is a fixed instruction plus a path. Requiring a
  ;; placeholder for that would make the simplest one the fiddliest to write.
  (is string= (format nil "Review this for correctness.~%~%src/a.lisp")
      (template:expand (template:make-template :name "r" :content "Review this for correctness.")
                       "src/a.lisp"))
  (is string= "Review this for correctness."
      (template:expand (template:make-template :name "r" :content "Review this for correctness.")
                       "")))

(define-test "templates load from disk with their descriptions"
  (with-repository (environment)
    (env:ensure-directory environment ".vivarium/prompts")
    (env:write-text environment ".vivarium/prompts/review.md"
                    (format nil "---~%description: Review a file for correctness.~%---~%Review $1 and list what is wrong.~%"))
    (env:write-text environment ".vivarium/prompts/notes.txt" "not a template")
    (let ((templates (template:load-templates environment (list ".vivarium/prompts"))))
      (is = 1 (length templates))
      (is string= "review" (template:template-name (first templates)))
      (is string= "Review a file for correctness." (template:template-description (first templates)))
      (false (mentions "description:" (template:template-content (first templates))))
      (is string= "Review src/x.lisp and list what is wrong."
          (string-trim '(#\Newline)
                       (template:expand (first templates) "src/x.lisp"))))))

;;; Custom entries

(define-test "an injected message is attributed, and the user's is left alone"
  ;; The version this replaced returned a rewritten user message, so the
  ;; transcript showed the person saying words they never typed.
  (with-repository (environment)
    (let* ((directory (uiop:parse-native-namestring
                       (format nil "~a/.sessions/" (env:env-cwd environment))))
           (session (session:open-session :directory directory))
           (agent (harness:make-workspace-agent :cwd (env:env-cwd environment)
                                                :session session :load-resources nil)))
      (let ((harness:*agent* agent))
        (setf (harness:agent-context agent) (loop*:make-context))
        (harness:send-message "recall" "you noted: the runner is ./check")
        (ws-say session :user "what is the runner?"))
      (session:close-session session)
      (let* ((reloaded (session:load-session (session:session-path session)))
             (entries (session:context-entries reloaded))
             (messages (session:session-messages reloaded)))
        ;; Both reach the model...
        (is = 2 (length messages))
        (true (mentions "the runner is ./check" (msg:text-of (first messages))))
        (is string= "what is the runner?" (msg:text-of (second messages)))
        ;; ...but only one of them is the person speaking.
        (is = 1 (count :custom-message entries :key #'session:entry-kind))
        (is = 1 (count :message entries :key #'session:entry-kind))
        (is string= "recall"
            (gethash "custom_type"
                     (session:entry-payload
                      (find :custom-message entries :key #'session:entry-kind))))))))

(define-test "custom state is persisted and never sent to a model"
  (with-repository (environment)
    (let* ((directory (uiop:parse-native-namestring
                       (format nil "~a/.sessions/" (env:env-cwd environment))))
           (session (session:open-session :directory directory)))
      (session:append-custom session "bookkeeping" (session:object "seen" 3))
      (ws-say session :user "hello")
      (session:close-session session)
      (let ((reloaded (session:load-session (session:session-path session))))
        ;; In the tree, so it is ordered against the turns it relates to...
        (is = 2 (length (session:context-entries reloaded)))
        ;; ...and out of the conversation.
        (is = 1 (length (session:session-messages reloaded)))
        (is string= "hello" (msg:text-of (first (session:session-messages reloaded))))))))

;;; Tree navigation

(define-test "an abandoned branch is found, and summarised onto the one resumed"
  (with-repository (environment)
    (let* ((directory (uiop:parse-native-namestring
                       (format nil "~a/.sessions/" (env:env-cwd environment))))
           (session (session:open-session :directory directory))
           (agent (make-instance 'compacting-agent
                                 :environment environment :resource-environment environment
                                 :session session
                                 :script (list "The first approach hit a wall at parsing."))))
      (ws-say session :user "shared ground")
      (let ((fork-point (session:session-leaf session)))
        (ws-say session :user "try approach A")
        (ws-say session :assistant "A did not work")
        (let ((left (session:session-leaf session)))
          ;; What is being walked away from is exactly the two turns after the
          ;; fork, and not the shared ground before it.
          (let ((abandoned (session:abandoned-branch session left fork-point)))
            (is = 2 (length abandoned))
            (is string= "try approach A" (msg:text-of (first (session:session-messages abandoned)))))
          (is string= fork-point (session:branch-point session left fork-point))
          (harness:navigate agent fork-point)
          ;; The shared ground, plus what the abandoned branch established.
          (let ((messages (loop*:context-messages (harness:agent-context agent))))
            (is = 2 (length messages))
            (is string= "shared ground" (msg:text-of (first messages)))
            (true (mentions "hit a wall at parsing" (msg:text-of (second messages)))))
          ;; And the summary is on disk, on the branch that was resumed.
          (is = 1 (count :branch-summary (session:entries-of session)
                         :key #'session:entry-kind)))))))

(define-test "sessions can be searched by what was said in them"
  (let* ((where "/tmp/vivarium-tests-search")
         (directory (session:session-directory where)))
    (ignore-errors (uiop:delete-directory-tree directory :validate t))
    (let ((one (session:open-session :directory directory :cwd where))
          (two (session:open-session :directory directory :cwd where
                                     :id (format nil "b-~36r" (random (expt 2 30) (make-random-state t))))))
      (ws-say one :user "the parser drops trailing commas")
      (ws-say two :user "something else entirely")
      (session:close-session one)
      (session:close-session two)
      (is = 2 (length (session:list-sessions :cwd where)))
      (is = 1 (length (session:search-sessions "trailing commas" :cwd where)))
      (is = 0 (length (session:search-sessions "no such phrase" :cwd where)))
      (ignore-errors (uiop:delete-directory-tree directory :validate t)))))

;;; Decision points

(defclass deciding-agent (harness:workspace-agent)
  ((script :initarg :script :accessor script)))

(defmethod client:complete ((agent deciding-agent) messages)
  (declare (ignore messages))
  (or (pop (script agent))
      (msg:make-assistant-message :content (list (msg:make-text "done")) :stop-reason :stop)))

(defun ws-guarded-run (environment command)
  "One run whose single tool call is `bash COMMAND`, with guard loaded."
  (let ((agent (make-instance 'deciding-agent
                              :environment environment :resource-environment environment
                              :script (list (msg:make-assistant-message
                                             :content (list (msg:make-tool-call
                                                             :id "c1" :name "bash"
                                                             :arguments (args "command" command)))
                                             :stop-reason :tool-calls)))))
    (workspace:with-environment (environment)
      (let ((harness:*agent* agent))
        (let ((produced (loop*:run agent (list (msg:make-user-message
                                                :content (list (msg:make-text "go")))))))
          (find-if #'msg:tool-result-message-p produced))))))

(define-test "an extension can refuse a tool call before it runs"
  ;; The whole point of a decision point. Until these existed an extension could
  ;; watch `rm -rf /` go past and had no way to stop it.
  (with-repository (environment)
    (let ((extension:*registry* '()))
      (load (merge-pathnames "examples/extensions/guard.lisp"
                             (asdf:system-source-directory "vivarium")))
      ;; Refused: the marker file is never created.
      (let ((result (ws-guarded-run environment "rm -rf / ; touch refused-marker")))
        (true (msg:tool-result-message-error-p result))
        (true (mentions "Refused" (msg:tool-result-message-output result)))
        (false (env:path-exists-p environment "refused-marker")))
      ;; Allowed: an ordinary command still runs.
      (let ((result (ws-guarded-run environment "touch allowed-marker")))
        (false (msg:tool-result-message-error-p result))
        (true (env:path-exists-p environment "allowed-marker"))))))

(define-test "an extension can redact a result before anyone sees it"
  (with-repository (environment)
    (let ((extension:*registry* '()))
      (load (merge-pathnames "examples/extensions/guard.lisp"
                             (asdf:system-source-directory "vivarium")))
      (let ((result (ws-guarded-run environment "echo token=sk-abcdef123456 done")))
        (true (mentions "[redacted]" (msg:tool-result-message-output result)))
        (false (mentions "sk-abcdef" (msg:tool-result-message-output result)))
        ;; And what was around it survives -- redaction, not deletion.
        (true (mentions "done" (msg:tool-result-message-output result)))))))

(define-test "the first extension to decide wins, and cannot be overturned"
  ;; FIRE threads every handler's answer through the next; DECIDE stops at the
  ;; first. A refusal that a later-loaded extension could undo would make load
  ;; order part of the security model, invisibly.
  (let ((extension:*registry* '()))
    (extension:defextension "first"
      :description "Refuses."
      (extension:on :tool-call (lambda (event) (declare (ignore event))
                                 (tool:make-tool-result :output "no" :error-p t))))
    (extension:defextension "second"
      :description "Would allow."
      (extension:on :tool-call (lambda (event) (declare (ignore event))
                                 (tool:make-tool-result :output "yes"))))
    (let ((decision (extension:decide :tool-call '())))
      (is string= "no" (tool:tool-result-output decision))
      (true (tool:tool-result-error-p decision)))))

;;; Lanes and sub-agents

(define-test "lanes are independent lines in one file"
  (let ((session (ws-scratch-session)))
    (session:append-entry session :message
                          (msg:make-user-message :content (list (msg:make-text "shared start"))))
    (let ((root (session:session-leaf session)))
      ;; Two workers, each attaching to the same point, neither disturbing the other.
      (session:append-entry session :message
                            (msg:make-user-message :content (list (msg:make-text "worker one")))
                            :lane "lane-1" :parent root)
      (session:append-entry session :message
                            (msg:make-user-message :content (list (msg:make-text "worker two")))
                            :lane "lane-2" :parent root)
      (session:append-entry session :message
                            (msg:make-user-message :content (list (msg:make-text "main carries on"))))
      ;; The main lane never saw either worker.
      (let ((main (session:session-messages session)))
        (is = 2 (length main))
        (is string= "main carries on" (msg:text-of (second main))))
      ;; Each worker sees the shared start and only its own work.
      (dolist (pair '(("lane-1" . "worker one") ("lane-2" . "worker two")))
        (let ((messages (session:session-messages
                         (session:context-entries session
                                                  (session:lane-leaf session (car pair))))))
          (is = 2 (length messages))
          (is string= (cdr pair) (msg:text-of (second messages)))))
      (is equal '("lane-1" "lane-2" "main") (session:lanes-of session)))))

(define-test "lanes survive the round trip through the file"
  (let ((session (ws-scratch-session)))
    (ws-say session :user "shared")
    (let ((root (session:session-leaf session)))
      (session:append-entry session :message
                            (msg:make-user-message :content (list (msg:make-text "aside")))
                            :lane "lane-1" :parent root))
    (session:close-session session)
    (let ((reloaded (session:load-session (session:session-path session))))
      (is equal '("lane-1" "main") (session:lanes-of reloaded))
      (is = 1 (length (session:session-messages reloaded)))
      (is = 2 (length (session:session-messages
                       (session:context-entries reloaded
                                                (session:lane-leaf reloaded "lane-1"))))))))

(defclass delegating-agent (harness:workspace-agent)
  ;; INITFORM because SUB-AGENT builds a worker of the parent's own class and
  ;; passes only what a workspace agent takes.
  ((script :initarg :script :initform '() :accessor script)))

(defmethod client:complete ((agent delegating-agent) messages)
  (declare (ignore messages))
  (or (pop (script agent))
      (msg:make-assistant-message :content (list (msg:make-text "sub-agent says: 42"))
                                  :stop-reason :stop)))

(define-test "a sub-agent shares the world and not the conversation"
  (with-repository (environment)
    (let* ((directory (uiop:parse-native-namestring
                       (format nil "~a/.sessions/" (env:env-cwd environment))))
           (session (session:open-session :directory directory))
           (parent (make-instance 'delegating-agent
                                  :environment environment :resource-environment environment
                                  :session session :script '())))
      (setf (harness:agent-context parent)
            (loop*:make-context :messages (list (msg:make-user-message
                                                 :content (list (msg:make-text "secret parent context"))))))
      (multiple-value-bind (answer lane) (harness:delegate parent "count something")
        (is string= "sub-agent says: 42" answer)
        ;; Its turns are in the same file, on their own lane...
        (true (member lane (session:lanes-of session) :test #'string=))
        ;; ...and the parent's conversation is untouched by it.
        (is = 1 (length (loop*:context-messages (harness:agent-context parent))))
        ;; ...and the sub-agent never saw the parent's context.
        (let ((theirs (session:session-messages
                       (session:context-entries session (session:lane-leaf session lane)))))
          (false (some (lambda (message) (mentions "secret parent" (msg:text-of message)))
                       theirs)))))))

(define-test "a search does not wander into the harness's own state"
  ;; Observed three times before this existed, once badly enough that a worker
  ;; was delegated to investigate the session's own transcript.
  (with-repository (environment)
    (env:write-text environment ".vivarium/sessions/x.jsonl" "{\"text\":\"needle\"}")
    (env:write-text environment "real.txt" "needle")
    (let ((found (run-tool workspace:grep-tool "pattern" "needle")))
      (true (mentions "real.txt" found))
      (false (mentions ".vivarium" found)))
    ;; Hidden from the walk, not from the agent: a direct read still works.
    (true (mentions "needle" (run-tool workspace:read-tool
                                       "path" ".vivarium/sessions/x.jsonl")))
    ;; And an explicitly excluded path is skipped too, wherever it is.
    (let ((workspace:*excluded-paths* (list (env:join-path (env:env-cwd environment) "src"))))
      (false (mentions "src/core.lisp" (run-tool workspace:find-tool "pattern" "*.lisp"))))))

(define-test "the session directory is excluded however its path is spelled"
  ;; /tmp and /private/tmp are the same directory on macOS and do not compare
  ;; equal. The same confusion has produced three separate bugs, so the check is
  ;; that SESSION-PATHS canonicalises rather than compares raw text.
  (with-repository (environment)
    (let* ((canonical (env:env-cwd environment))
           ;; The spelling a caller would pass, before anything resolves it:
           ;; absolute, and via the /tmp symlink rather than through /private.
           (as-typed (format nil "~a/.s/"
                             (if (eql 0 (search "/private/" canonical))
                                 (subseq canonical (length "/private"))
                                 canonical)))
           (session (session:open-session :directory (uiop:parse-native-namestring as-typed)
                                          :cwd canonical))
           (agent (harness:make-workspace-agent :cwd canonical :session session
                                                :load-resources nil))
           (excluded (harness::session-paths agent)))
      (is = 1 (length excluded))
      ;; The exclusion must name the canonical spelling, or the prefix test
      ;; that uses it silently matches nothing.
      (is = 0 (search canonical (first excluded)))
      (session:close-session session))))

;;; Operations, and parallel tools

(define-test "an operation runs elsewhere and is waited for by name"
  (let* ((gate (bt:make-semaphore :count 0))
         (op (operation:start (lambda () (bt:wait-on-semaphore gate) :finished)
                              :label "slow")))
    (is eq :running (operation:status op))
    (false (operation:finished-p op))
    (bt:signal-semaphore gate)
    (multiple-value-bind (result state) (operation:await op :timeout 5)
      (is eq :finished result)
      (is eq :done state))
    ;; Findable by id afterwards, which is what makes it an operation rather
    ;; than a thread nobody kept.
    (is eq :done (operation:status (operation:operation-id op)))))

(define-test "a failed operation is a state, not a lost thread"
  ;; An operation whose thread died silently is indistinguishable from one
  ;; still running, and AWAIT would block until the timeout.
  (let ((op (operation:start (lambda () (error "deliberate")))))
    (multiple-value-bind (result state) (operation:await op :timeout 5)
      (is eq nil result)
      (is eq :failed state))
    (true (typep (operation:operation-error op) 'error))))

(define-test "suspension is cooperative, and cancellation is asked for"
  (let* ((reached (bt:make-semaphore :count 0))
         (steps 0)
         (op (operation:start (lambda ()
                                (loop repeat 50
                                      do (incf steps)
                                         (bt:signal-semaphore reached)
                                         (operation:checkpoint)
                                         (sleep 0.01))
                                :ran-to-the-end))))
    (bt:wait-on-semaphore reached :timeout 5)
    (true (operation:suspend op))
    (is eq :suspended (operation:status op))
    ;; Settle first. SUSPEND can land while the operation is mid-step, so one
    ;; more completes before it reaches the checkpoint it agreed to stop at --
    ;; which is what cooperative means. The claim is that it stops INCREASING,
    ;; not that it stops instantly, and asserting the latter is a race in the
    ;; test rather than a defect in the pause.
    (sleep 0.15)
    (let ((frozen steps))
      (sleep 0.15)
      (is = frozen steps))
    (true (operation:resume op))
    (operation:cancel op)
    (multiple-value-bind (result state) (operation:await op :timeout 5)
      (declare (ignore result))
      ;; Stopped where it agreed to stop, rather than being killed mid-step.
      (is eq :cancelled state)
      (true (< steps 50)))))

(defclass parallel-agent (harness:workspace-agent)
  ((script :initarg :script :initform '() :accessor script)))

(defmethod client:complete ((agent parallel-agent) messages)
  (declare (ignore messages))
  (or (pop (script agent))
      (msg:make-assistant-message :content (list (msg:make-text "done")) :stop-reason :stop)))

(define-test "tools in a parallel batch still find their environment"
  ;; A dynamic rebinding does not cross into a spawned thread, so before
  ;; CALL-IN-TOOL-CONTEXT every tool in a parallel batch failed with
  ;; "No environment bound" -- and PARALLEL-TOOLS is a supported setting.
  (with-repository (environment)
    (let ((agent (make-instance 'parallel-agent
                                :environment environment :resource-environment environment
                                :script (list (msg:make-assistant-message
                                               :content (list (msg:make-tool-call
                                                               :id "c1" :name "ls" :arguments (args))
                                                              (msg:make-tool-call
                                                               :id "c2" :name "read"
                                                               :arguments (args "path" "src/core.lisp")))
                                               :stop-reason :tool-calls)))))
      (setf (agent:agent-parallel-tools-p agent) t)
      ;; Deliberately NOT inside WITH-ENVIRONMENT: the agent must re-establish it.
      (let* ((produced (loop*:run agent (list (msg:make-user-message
                                               :content (list (msg:make-text "go"))))))
             (results (remove-if-not #'msg:tool-result-message-p produced)))
        (is = 2 (length results))
        (dolist (result results)
          (false (msg:tool-result-message-error-p result))
          (false (mentions "No environment bound" (msg:tool-result-message-output result))))
        (true (mentions "README.md" (msg:tool-result-message-output (first results))))
        (true (mentions "defun total" (msg:tool-result-message-output (second results))))))))

(define-test "reflection never overrides a cancellation"
  ;; The retention policy's law 3: a cancellation that landed during the work
  ;; stays in force. REFLECT on an aborting agent must return NIL without
  ;; touching the request limit -- an aborted task that then got six more
  ;; requests of budget would be a cancellation with an asterisk.
  (let ((agent (make-instance 'harness::workspace-agent
                              :environment (env:make-local-environment :cwd "/tmp")
                              :resource-environment (env:make-local-environment :cwd "/tmp")
                              :provider nil :model "none"
                              :request-limit 7)))
    (setf (harness:agent-aborting agent) t)
    (false (harness:reflect agent) "reflection ran on an aborting agent")
    (is = 7 (harness:agent-request-limit agent)
        "reflection touched the limit of a cancelled task")))

(define-test "the reflection prompt carries the policy"
  ;; The v1 policy text is load-bearing: both channels named with their
  ;; division of labour, parsimony demanded, declining made explicit. A prompt
  ;; that lost one of these is a different policy shipping under this name.
  (let ((prompt harness:*reflection-prompt*))
    (true (search "remember" prompt) "the text channel is unnamed")
    ;; The door is PARKED, so the prompt must not name it. This assertion is
    ;; inverted from what it was: it used to require create_capability, which
    ;; would have pinned the killed path in place through every future edit.
    (false (search "create_capability" prompt) "the prompt still names the parked door")
    (false (search "promote_capability" prompt) "the prompt still names the parked door")
    (true (search ".vivarium/tools/" prompt) "the registry is not named as the code channel")
    (true (search "stdin" prompt) "the calling convention is unstated")
    (true (search "prefer the note" prompt)
          "the cost caveat is gone -- the kill punished premature registration")
    (true (search "nothing to retain" prompt) "declining is no longer explicit")
    (true (search "only what transfers" prompt)
          "the answer-key guard is gone")))

;;; ---------------------------------------------------------------------------
;;; The tool registry (#4)
;;;
;;; Retention that survives the process: a script on disk plus a manifest,
;;; loaded as a real agent tool. Driven the way the loop drives it — through
;;; the real constructor and the wire schema, never by calling the body — for
;;; the reason pre-check zero exists: reading the code once said fourteen
;;; tools where the constructor said nine.
;;; ---------------------------------------------------------------------------

(defun write-registry-tool (root name manifest &key (script "#!/usr/bin/env python3
import json, sys
args = json.load(sys.stdin)
print(args.get('input', '').upper())
"))
  "Write one tool into ROOT/.vivarium/tools/NAME/. Returns the directory."
  (let ((directory (format nil "~a/.vivarium/tools/~a/" root name)))
    (ensure-directories-exist directory)
    (with-open-file (out (format nil "~atool.json" directory)
                         :direction :output :if-exists :supersede)
      (write-string manifest out))
    (let ((path (format nil "~arun.py" directory)))
      (with-open-file (out path :direction :output :if-exists :supersede)
        (write-string script out))
      (sb-posix:chmod path #o755))
    directory))

(defun substitute-manifest-name (manifest name)
  (let ((start (search "\"shout\"" manifest)))
    (concatenate 'string (subseq manifest 0 start)
                 (format nil "\"~a\"" name)
                 (subseq manifest (+ start 7)))))

(defun registry-fixture ()
  (let ((root (format nil "/tmp/vivarium-registry-~36r" (random (expt 2 48) (make-random-state t)))))
    (ensure-directories-exist (format nil "~a/" root))
    root))

(defparameter +shout-manifest+ "{
  \"name\": \"shout\",
  \"description\": \"Upper-case one string.\",
  \"version\": 1,
  \"exec\": [\"python3\", \"run.py\"],
  \"parameters\": [
    {\"name\": \"input\", \"type\": \"string\", \"description\": \"the text\", \"required\": true}
  ]
}")

(define-test "a registered tool reaches the model through the real constructor"
  (let* ((root (registry-fixture)))
    (write-registry-tool root "shout" +shout-manifest+)
    (let* ((agent (harness:make-workspace-agent :cwd root :root root :model "none"))
           (names (mapcar #'tool:tool-name (agent:tools agent))))
      (true (member "shout" names :test #'string=)
            "the registry tool is not in the model's tool set: ~s" names)
      (false (harness:agent-registry-warnings agent)
             "a valid manifest produced complaints: ~s"
             (harness:agent-registry-warnings agent)))))

(define-test "a registered tool's wire schema is well formed"
  ;; The B14 lesson as a gate: what the model receives is the JSON, not the
  ;; Lisp object, and a tool can be perfect in-image and unusable on the wire.
  (let* ((root (registry-fixture)))
    (write-registry-tool root "shout" +shout-manifest+)
    (let* ((agent (harness:make-workspace-agent :cwd root :root root :model "none"))
           (tool (find "shout" (agent:tools agent) :key #'tool:tool-name :test #'string=))
           (json (vivarium.client::tool-json tool))
           (parameters (gethash "parameters" (gethash "function" json)))
           (properties (gethash "properties" parameters)))
      (true tool "no shout tool to inspect")
      (when tool
        (is string= "shout" (gethash "name" (gethash "function" json)))
        (is string= "object" (gethash "type" parameters))
        (is string= "string" (gethash "type" (gethash "input" properties)))
        (is string= "input" (aref (gethash "required" parameters) 0))))))

(define-test "a registered tool runs, and its arguments cross as JSON not argv"
  ;; The calling convention exists because arguments crossing a shell is the
  ;; bug class this project paid for twice. A value carrying quotes, spaces
  ;; and a semicolon must arrive intact.
  (let* ((root (registry-fixture)))
    (write-registry-tool root "shout" +shout-manifest+)
    (let* ((agent (harness:make-workspace-agent :cwd root :root root :model "none"))
           (tool (find "shout" (agent:tools agent) :key #'tool:tool-name :test #'string=))
           (arguments (make-hash-table :test #'equal)))
      (setf (gethash "input" arguments) "a b; echo \"pwned\" && rm -rf /")
      (let ((result (tool:execute tool arguments nil)))
        (false (tool:tool-result-error-p result)
               "the tool errored: ~a" (tool:tool-result-output result))
        (is string= "A B; ECHO \"PWNED\" && RM -RF /"
            (string-trim '(#\Newline) (tool:tool-result-output result)))))))

(define-test "a registry tool cannot read the credentials of the process serving it"
  ;; Whitelist inheritance, not a scrub list: a tool the organism wrote runs
  ;; with PATH and HOME and nothing that was never meant for it.
  (let* ((root (registry-fixture)))
    (write-registry-tool
     root "peek" (substitute-manifest-name +shout-manifest+ "peek")
     :script "#!/usr/bin/env python3
import json, os, sys
json.load(sys.stdin)
print(os.environ.get('DEEPSEEK_API_KEY', 'ABSENT'))
")
    (sb-posix:setenv "DEEPSEEK_API_KEY" "sk-should-never-reach-a-tool" 1)
    (let* ((agent (harness:make-workspace-agent :cwd root :root root :model "none"))
           (tool (find "peek" (agent:tools agent) :key #'tool:tool-name :test #'string=))
           (arguments (make-hash-table :test #'equal)))
      (setf (gethash "input" arguments) "ignored")
      (let ((result (tool:execute tool arguments nil)))
        (true tool "no peek tool")
        (when tool
          (is string= "ABSENT" (string-trim '(#\Newline) (tool:tool-result-output result))
              "a registry tool inherited a credential"))))))

(define-test "a malformed manifest is refused with a reason and loads nothing"
  ;; Never half-loaded: the model must not see a name it cannot call.
  (dolist (case '(("not json at all" . "valid JSON")
                  ("{\"description\": \"no name\"}" . "no name")
                  ("{\"name\": \"x\", \"description\": \"d\"}" . "exec")
                  ("{\"name\": \"x\", \"description\": \"d\", \"exec\": [\"true\"], \"parameters\": [{\"name\": \"p\", \"type\": \"widget\"}]}" . "unsupported type")))
    (destructuring-bind (manifest . expected) case
      (let ((root (registry-fixture)))
        (write-registry-tool root "broken" manifest)
        (let* ((agent (harness:make-workspace-agent :cwd root :root root :model "none"))
               (names (mapcar #'tool:tool-name (agent:tools agent)))
               (warnings (harness:agent-registry-warnings agent)))
          (false (member "broken" names :test #'string=) "a malformed tool loaded anyway")
          (false (member "x" names :test #'string=) "a malformed tool loaded anyway")
          (true warnings "no reason was given for refusing ~s" manifest)
          (when warnings
            (true (search expected (first warnings))
                  "the reason does not mention ~s: ~a" expected (first warnings))))))))

(define-test "a tool that fails reports it without killing the run"
  (let* ((root (registry-fixture)))
    (write-registry-tool root "boom" (substitute-manifest-name +shout-manifest+ "boom")
                         :script "#!/usr/bin/env python3
import sys
sys.stderr.write('deliberate failure\\n')
sys.exit(3)
")
    (let* ((agent (harness:make-workspace-agent :cwd root :root root :model "none"))
           (tool (find "boom" (agent:tools agent) :key #'tool:tool-name :test #'string=))
           (arguments (make-hash-table :test #'equal)))
      (setf (gethash "input" arguments) "ignored")
      (let ((result (tool:execute tool arguments nil)))
        (true (tool:tool-result-error-p result) "a failing tool reported success")
        (true (search "exited 3" (tool:tool-result-output result))
              "the exit code is not reported: ~a" (tool:tool-result-output result))
        (true (search "deliberate failure" (tool:tool-result-output result))
              "the tool's own diagnosis was dropped")))))

;;; ---------------------------------------------------------------------------
;;; MCP: the registry served to anybody (#9)
;;;
;;; Asserted on the SERIALIZED JSON, not on the Lisp objects. The first draft
;;; of this server was correct in-image and wrong on the wire: jzon maps a
;;; keyword to a string, so :FALSE became "isError":"FALSE" -- a truthy string
;;; telling every client each successful call had failed. No in-process test
;;; could have seen it. These parse what a client would actually receive.
;;; ---------------------------------------------------------------------------

(defun mcp-exchange (request entries &key (cwd "/tmp"))
  "One request in, the parsed reply a client would receive out."
  (let ((response (vivarium.mcp::handle (com.inuoe.jzon:parse request) entries cwd)))
    (and response (com.inuoe.jzon:parse (com.inuoe.jzon:stringify response)))))

(defun mcp-entries (root)
  (registry:load-entries (env:make-local-environment :cwd root)
                         (list (format nil "~a/.vivarium/tools" root))))

(define-test "the MCP handshake answers with the shapes the specification names"
  (let ((reply (mcp-exchange "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}" '())))
    (let ((result (gethash "result" reply)))
      (is string= "2.0" (gethash "jsonrpc" reply))
      (true (stringp (gethash "protocolVersion" result)) "protocolVersion is not a string")
      (true (hash-table-p (gethash "capabilities" result)) "capabilities is not an object")
      (let ((info (gethash "serverInfo" result)))
        (true (stringp (gethash "name" info)) "serverInfo.name is not a string")
        ;; A system with no declared version yields NIL, and NIL is JSON
        ;; false. This shipped once.
        (true (stringp (gethash "version" info))
              "serverInfo.version is ~s, not a string" (gethash "version" info))))))

(define-test "a notification is never answered"
  ;; No id means no reply, by the specification. Answering one corrupts the
  ;; client's request/response pairing for everything after it.
  (false (mcp-exchange "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}" '())
         "a notification was answered"))

(define-test "tools/list projects the registry, inputSchema and all"
  (let* ((root (registry-fixture)))
    (write-registry-tool root "shout" +shout-manifest+)
    (let* ((reply (mcp-exchange "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}"
                                (mcp-entries root)))
           (tools (gethash "tools" (gethash "result" reply)))
           (tool (aref tools 0))
           (schema (gethash "inputSchema" tool)))
      (is = 1 (length tools))
      (is string= "shout" (gethash "name" tool))
      (is string= "object" (gethash "type" schema))
      (true (gethash "input" (gethash "properties" schema)) "the parameter is missing")
      (is string= "input" (aref (gethash "required" schema) 0)))))

(define-test "tools/call returns a real JSON boolean for isError"
  (let* ((root (registry-fixture)))
    (write-registry-tool root "shout" +shout-manifest+)
    (let* ((entries (mcp-entries root))
           (ok (mcp-exchange "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"shout\",\"arguments\":{\"input\":\"quiet\"}}}"
                             entries :cwd root))
           (result (gethash "result" ok))
           (content (aref (gethash "content" result) 0)))
      (is string= "text" (gethash "type" content))
      (is string= "QUIET" (string-trim '(#\Newline) (gethash "text" content)))
      ;; The bug this file exists to prevent: a STRING here is truthy in every
      ;; client language, so "FALSE" reads as failure.
      (is eq nil (gethash "isError" result)
          "isError came back as ~s, not a JSON boolean" (gethash "isError" result)))))

(define-test "a tool that fails is a result; a tool that is missing is a protocol error"
  ;; The specification's split, and it is normative: a client that cannot tell
  ;; \"your tool broke\" from \"there is no such tool\" cannot report either
  ;; honestly, and a model denied the first cannot recover from it.
  (let* ((root (registry-fixture)))
    (write-registry-tool root "boom" (substitute-manifest-name +shout-manifest+ "boom")
                         :script "#!/usr/bin/env python3
import sys; sys.exit(4)
")
    (let* ((entries (mcp-entries root))
           (ran (mcp-exchange "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"boom\",\"arguments\":{\"input\":\"x\"}}}"
                              entries :cwd root))
           (missing (mcp-exchange "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"absent\",\"arguments\":{}}}"
                                  entries :cwd root)))
      (true (gethash "result" ran) "a failing tool was reported as a protocol error")
      (is eq t (gethash "isError" (gethash "result" ran)) "a failing tool reported success")
      (false (gethash "result" missing) "a missing tool was reported as a result")
      (true (gethash "error" missing) "a missing tool produced no protocol error")
      (is = -32602 (gethash "code" (gethash "error" missing))))))

(define-test "an unsupported method is refused rather than ignored"
  (let ((reply (mcp-exchange "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"resources/list\"}" '())))
    (true (gethash "error" reply) "an unsupported method produced no error")
    (is = -32601 (gethash "code" (gethash "error" reply)))))
