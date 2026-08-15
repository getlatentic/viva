;;;; The tool protocol.
;;;;
;;;; Tools are CLOS objects behind a generic EXECUTE rather than closures in a
;;;; table, because an agent that adds a capability to itself mid-run does it by
;;;; adding a method -- not by rebuilding a dispatch table it does not own.

(in-package #:vivarium.tool)

(defclass tool ()
  ((name :initarg :name :reader tool-name :type string)
   (description :initarg :description :reader tool-description :type string)
   ;; ((name type description &key required) ...), turned into JSON schema at the
   ;; provider boundary. Kept declarative so a schema is never hand-written.
   (parameters :initarg :parameters :initform '() :reader tool-parameters)))

(defmethod print-object ((tool tool) stream)
  (print-unreadable-object (tool stream :type t)
    (write-string (tool-name tool) stream)))

(defstruct (tool-result (:conc-name tool-result-))
  (output "" :type string)
  (error-p nil :type boolean)
  ;; A tool may end the batch -- Pi's `terminate` -- so a tool that hands control
  ;; back to the user does not get followed by another model request.
  (terminate-p nil :type boolean))

(defgeneric execute (tool arguments context)
  (:documentation "Run TOOL with ARGUMENTS, returning a TOOL-RESULT.
ARGUMENTS is the hash table the model produced. CONTEXT is the loop's context."))

(defmethod execute ((tool tool) arguments context)
  (declare (ignore arguments context))
  (make-tool-result :output (format nil "Tool ~a has no implementation." (tool-name tool))
                    :error-p t))

(defmethod execute :around ((tool tool) arguments context)
  "Check the arguments against the schema before running anything, then make sure
a tool that signals fails its own call rather than the whole run.

Validating first matters more than it looks: a tool that receives a missing
argument as NIL usually fails somewhere inside its body, and the model gets a
message about that internal failure instead of about the call it got wrong."
  (a:if-let ((complaint (schema:validate (tool-parameters tool) arguments)))
    (make-tool-result :output complaint :error-p t)
    (handler-case (coerce-result (call-next-method))
      (error (condition)
        (make-tool-result :output (princ-to-string condition) :error-p t)))))

(defun coerce-result (value)
  "Let a tool body return a string for the common case."
  (etypecase value
    (tool-result value)
    (string (make-tool-result :output value))
    (null (make-tool-result :output ""))))

;;; The common case: a tool whose behaviour is one body of code.

(defclass function-tool (tool)
  ((body :initarg :body :reader tool-body :type function)))

(defmethod execute ((tool function-tool) arguments context)
  (funcall (tool-body tool) arguments context))

(defmacro define-tool (variable (arguments context) &body options-and-body)
  "Define a FUNCTION-TOOL bound to VARIABLE.

The model-visible name is derived from VARIABLE unless :NAME says otherwise --
needed as soon as a tool is called `read`, because the variable would then be
CL:READ and the definition a package-lock violation.

The body is wrapped in a block named after VARIABLE, so a guard clause can
return early without the caller needing a symbol out of this package.

  (define-tool read-tool (args ctx)
    :name \"read\"
    :description \"Read a file.\"
    :parameters ((\"path\" :string \"Where\" :required-p t))
    (contents-of (gethash \"path\" args)))"
  ;; The options are collected before anything is looked up, because GETF over
  ;; the whole form signals on the body: a list of options followed by an odd
  ;; number of body forms is not a property list, and GETF only got away with it
  ;; while every key it was asked for happened to be present.
  (let* ((options (loop for rest on options-and-body by #'cddr
                        while (keywordp (first rest))
                        append (list (first rest) (second rest))))
         (body (loop for rest on options-and-body by #'cddr
                     unless (keywordp (first rest))
                       return rest))
         (description (getf options :description))
         (parameters (getf options :parameters))
         (name (or (getf options :name)
                   (string-downcase (substitute #\_ #\- (symbol-name variable))))))
    `(defparameter ,variable
       (make-instance 'function-tool
                      :name ,name
                      :description ,description
                      :parameters ',parameters
                      :body (lambda (,arguments ,context)
                              (declare (ignorable ,arguments ,context))
                              (block ,variable ,@body))))))
