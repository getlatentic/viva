;;;; guard -- refuse destructive commands, and redact secrets out of results.
;;;;
;;;; Exists to prove a capability the harness did not have until the decision
;;;; points did. Every extension hook here was observational: an extension could
;;;; watch a `rm -rf /` go past and had no way to stop it, and could watch an API
;;;; key come back in a tool result and had no way to remove it before the model
;;;; and the transcript both saw it.
;;;;
;;;; A refusal is returned as an ordinary TOOL-RESULT rather than signalled. The
;;;; model then reads "refused, and why" as it reads any other result, and can
;;;; choose something else -- where an exception would end the run and teach it
;;;; nothing. Saying no is a message, not a crash.

(in-package #:vivarium.extension)

(defparameter +guard-refused+
  '("rm -rf /" "rm -rf ~" "mkfs" "dd if=" ":(){" "> /dev/sda" "chmod -R 777 /")
  "Fragments that are never a mistake worth making twice. Deliberately short and
literal: a clever matcher here would refuse work someone meant to do, and the
cost of a false refusal is higher than the cost of a narrow list.")

(defparameter +guard-secrets+
  '("sk-" "ghp_" "AKIA" "-----BEGIN")
  "Prefixes worth removing from a tool result before anyone sees it.")

(defun guard-command (call)
  (let ((arguments (vivarium.message:tool-call-arguments call)))
    (and (hash-table-p arguments)
         (or (gethash "command" arguments) ""))))

(defun guard-refuse (event)
  "Refuse a command that matches, by answering with the refusal itself."
  (let ((call (getf event :call)))
    (when (string= "bash" (vivarium.message:tool-call-name call))
      (let ((command (guard-command call)))
        (a:when-let ((hit (find-if (lambda (fragment) (search fragment command))
                                   +guard-refused+)))
          (vivarium.harness:record :guard-refused "command" command "matched" hit)
          (vivarium.tool:make-tool-result
           :output (format nil "Refused: this command contains ~s, which the guard ~
extension does not allow. Nothing was run. If you need this, ask the person ~
running the session to do it." hit)
           :error-p t))))))

(defun guard-redact (event)
  "Take anything secret-shaped out of a result before the model or the
transcript sees it. Returning a replacement is the only way -- by the time this
would have been an observation, the value is already in both."
  (let* ((result (getf event :result))
         (text (vivarium.tool:tool-result-output result)))
    (when (some (lambda (prefix) (search prefix text)) +guard-secrets+)
      (vivarium.harness:record :guard-redacted "bytes" (length text))
      (vivarium.tool:make-tool-result
       :output (guard-scrub text)
       :error-p (vivarium.tool:tool-result-error-p result)))))

(defun guard-scrub (text)
  (let ((result text))
    (dolist (prefix +guard-secrets+ result)
      (loop for found = (search prefix result)
            while found
            ;; To the next whitespace, which is where a token ends in every
            ;; format that puts one in a tool result.
            do (let ((end (or (position-if (lambda (character)
                                             (member character '(#\Space #\Newline #\Tab #\" #\')))
                                           result :start found)
                              (length result))))
                 (setf result (concatenate 'string (subseq result 0 found)
                                           "[redacted]" (subseq result end))))))))

(defextension "guard"
  :description "Refuses destructive shell commands and redacts secrets from results."
  (on :tool-call #'guard-refuse)
  (on :tool-result #'guard-redact))
