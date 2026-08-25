;;;; Schemas advertised to the model, and validation of what comes back.

(in-package #:viva.tests)

(defpackage #:viva.tests.derived (:use #:cl))

(defun args (&rest plist)
  (let ((table (make-hash-table :test #'equal)))
    (loop for (key value) on plist by #'cddr do (setf (gethash key table) value))
    table))

(defun schema-property (parameters name)
  (gethash name (gethash "properties" (schema:parameter-schema parameters))))

;;; Schema shape

(define-test "a required parameter is listed as required"
  (let ((json (schema:parameter-schema '(("target" :string "what to read" :required-p t)
                                         ("note" :string "why" )))))
    (is equalp #("target") (gethash "required" json))
    (is string= "string" (gethash "type" (schema-property
                                          '(("target" :string "what to read")) "target")))))

(define-test "an enum and a default reach the schema"
  (let ((property (schema-property '(("mode" :string "how" :enum ("fast" "slow") :default "fast"))
                                   "mode")))
    (is equalp #("fast" "slow") (gethash "enum" property))
    (is string= "fast" (gethash "default" property))))

(define-test "an array type carries its item type"
  (let ((property (schema-property '(("names" (:array :string) "who")) "names")))
    (is string= "array" (gethash "type" property))
    (is string= "string" (gethash "type" (gethash "items" property)))))

(define-test "an unknown type is advertised as any, not guessed at"
  (let ((property (schema-property '(("value" nil "anything")) "value")))
    (false (nth-value 1 (gethash "type" property)))))

;;; Validation

(define-test "a missing required argument is named, with what the tool expects"
  (let ((complaint (schema:validate '(("target" :string "what" :required-p t)) (args))))
    (true complaint)
    (true (search "missing required: target" complaint))
    (true (search "target (string, required)" complaint))))

(define-test "a present argument of the wrong type is reported with its value"
  (let ((complaint (schema:validate '(("count" :integer "how many" :required-p t))
                                    (args "count" "seven"))))
    (true (search "count should be integer" complaint))
    (true (search "\"seven\"" complaint))))

(define-test "a value outside an enum is reported with the allowed set"
  (let ((complaint (schema:validate '(("mode" :string "how" :enum ("fast" "slow")))
                                    (args "mode" "sideways"))))
    (true (search "must be one of" complaint))
    (true (search "\"fast\"" complaint))))

(define-test "valid arguments validate clean, and extra keys are tolerated"
  (false (schema:validate '(("target" :string "what" :required-p t))
                          (args "target" "DEFUN FOO" "stray" 1))))

(define-test "a tool called with a missing argument never runs its body"
  (let ((ran nil))
    (let* ((tool (make-instance 'tool:function-tool
                                :name "needs_target"
                                :description "Needs a target."
                                :parameters '(("target" :string "what" :required-p t))
                                :body (lambda (a c) (declare (ignore a c)) (setf ran t) "ran")))
           (result (tool:execute tool (args) nil)))
      (true (tool:tool-result-error-p result))
      (false ran)
      (true (search "missing required: target" (tool:tool-result-output result))))))

;;; Derived tools

(defun scratch-derived (name)
  (find-symbol (string-upcase name) '#:viva.tests.derived))

(define-test "a tool derived from a live function carries its docstring and types"
  (eval (read-from-string
         "(defun viva.tests.derived::shipping-cost (weight &key (express nil))
            \"Cost to ship WEIGHT kilograms.\"
            (declare (type integer weight))
            (if express (* weight 3) weight))"))
  (let ((tool (derive:derive-tool (scratch-derived "shipping-cost"))))
    (is string= "shipping_cost" (tool:tool-name tool))
    (is string= "Cost to ship WEIGHT kilograms." (tool:tool-description tool))
    (let ((parameters (tool:tool-parameters tool)))
      (is = 2 (length parameters))
      (is string= "weight" (first (first parameters)))
      (is eq :integer (second (first parameters)))
      (true (getf (cdddr (first parameters)) :required-p))
      (is string= "express" (first (second parameters)))
      (false (getf (cdddr (second parameters)) :required-p)))))

(define-test "a derived tool actually calls the function it was derived from"
  (eval (read-from-string
         "(defun viva.tests.derived::doubled (n) \"Double N.\" (* 2 n))"))
  (let ((tool (derive:derive-tool (scratch-derived "doubled"))))
    (is string= "16" (tool:tool-result-output (tool:execute tool (args "n" 8) nil)))))

(define-test "a derived tool passes keyword arguments through"
  (eval (read-from-string
         "(defun viva.tests.derived::greet (name &key (loud nil))
            \"Greet NAME.\"
            (if loud (string-upcase name) name))"))
  (let ((tool (derive:derive-tool (scratch-derived "greet"))))
    (is string= "ada" (tool:tool-result-output (tool:execute tool (args "name" "ada") nil)))
    (is string= "ADA" (tool:tool-result-output
                       (tool:execute tool (args "name" "ada" "loud" t) nil)))))

(define-test "redefining the function redefines the tool's schema"
  (eval (read-from-string
         "(defun viva.tests.derived::drifting (a) \"One argument.\" a)"))
  (let ((before (length (tool:tool-parameters
                         (derive:derive-tool (scratch-derived "drifting"))))))
    (eval (read-from-string
           "(defun viva.tests.derived::drifting (a b) \"Two arguments.\" (list a b))"))
    (let ((after (derive:derive-tool (scratch-derived "drifting"))))
      (is = 1 before)
      (is = 2 (length (tool:tool-parameters after)))
      (is string= "Two arguments." (tool:tool-description after)))))

(define-test "deriving from something that is not a function is refused"
  (fail (derive:derive-tool 'no-such-function-anywhere)))
