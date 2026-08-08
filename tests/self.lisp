;;;; An agent extending itself: registering a tool it wrote, editing its prompt.

(in-package #:vivarium.tests)

(defun bare-agent (&rest initargs)
  (apply #'make-instance 'scripted-agent :script '() :tools '() initargs))

(define-test "registering a definition gives the agent a working tool"
  (let* ((agent (bare-agent))
         (backend (fresh-image))
         (image-tools:*backend* backend))
    (image:install-definition backend "(defun tripled (n) \"Triple N.\" (* 3 n))")
    (self:with-self-extension (agent)
      (let ((result (tool:execute self:register-tool
                                  (arguments "target" "DEFUN VIVARIUM.TESTS.SCRATCH::TRIPLED")
                                  nil)))
        (false (tool:tool-result-error-p result))
        (true (search "tripled" (tool:tool-result-output result)))))
    (let ((registered (find "tripled" (agent:tools agent)
                            :key #'tool:tool-name :test #'string=)))
      (true registered)
      (is string= "Triple N." (tool:tool-description registered))
      (is string= "27" (tool:tool-result-output
                        (tool:execute registered (arguments "n" 9) nil))))))

(define-test "registering the same name twice replaces rather than duplicates"
  (let* ((agent (bare-agent))
         (backend (fresh-image))
         (image-tools:*backend* backend))
    (image:install-definition backend "(defun swappable (n) \"First.\" n)")
    (self:with-self-extension (agent)
      (tool:execute self:register-tool
                    (arguments "target" "DEFUN VIVARIUM.TESTS.SCRATCH::SWAPPABLE") nil)
      (image:install-definition backend "(defun swappable (n) \"Second.\" (* 10 n))")
      (tool:execute self:register-tool
                    (arguments "target" "DEFUN VIVARIUM.TESTS.SCRATCH::SWAPPABLE") nil))
    (is = 1 (length (agent:tools agent)))
    (is string= "Second." (tool:tool-description (first (agent:tools agent))))
    (is string= "50" (tool:tool-result-output
                      (tool:execute (first (agent:tools agent)) (arguments "n" 5) nil)))))

(define-test "registering something that is not a function is refused"
  (let ((agent (bare-agent))
        (image-tools:*backend* (fresh-image)))
    (self:with-self-extension (agent)
      (let ((result (tool:execute self:register-tool
                                  (arguments "target" "DEFUN NOWHERE::ABSENT") nil)))
        (true (tool:tool-result-error-p result))))
    (is = 0 (length (agent:tools agent)))))

(define-test "remember appends to the agent's own prompt"
  (let ((agent (bare-agent :system-prompt "Base instructions.")))
    (self:with-self-extension (agent)
      (tool:execute self:remember (arguments "instruction" "Roll back before retrying.") nil))
    (true (search "Base instructions." (agent:system-prompt agent)))
    (true (search "Roll back before retrying." (agent:system-prompt agent)))))

(define-test "self tools outside a bound run fail their call rather than the process"
  (let ((self:*agent* nil))
    (let ((result (tool:execute self:remember (arguments "instruction" "anything") nil)))
      (true (tool:tool-result-error-p result))
      (true (search "No agent bound" (tool:tool-result-output result))))))

(define-test "a registered tool reaches the very next request, mid-run"
  ;; The loop-level proof: the agent starts with one tool, uses it to register a
  ;; second, and the next request carries both. Nothing restarted.
  (let* ((backend (fresh-image))
         (image-tools:*backend* backend)
         (agent (make-agent (list (call-tool "register_tool"
                                             :arguments (arguments
                                                         "target"
                                                         "DEFUN VIVARIUM.TESTS.SCRATCH::LATE-ARRIVAL"))
                                  (say "registered")))))
    (image:install-definition backend "(defun late-arrival (n) \"Arrives late.\" (1+ n))")
    (setf (agent:tools agent) (list self:register-tool))
    (self:with-self-extension (agent)
      (loop*:run agent (list (user "extend yourself"))))
    (let ((tools (mapcar (lambda (r) (getf r :tools)) (requests-made agent))))
      (is equal '("register_tool") (first tools))
      (true (member "late_arrival" (second tools) :test #'string=)))))
