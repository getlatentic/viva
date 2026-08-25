;;;; Parameter schemas, and checking what the model sent against them.
;;;;
;;;; Two jobs that belong together: the schema a tool advertises and the
;;;; validation of arguments against it must agree, and they only reliably agree
;;;; if one file owns both.
;;;;
;;;; Validation exists because of a measured failure. A model that gets an
;;;; argument slightly wrong and receives a vague error will try the same call
;;;; again; naming what was missing and what was expected is what breaks the
;;;; loop. See the target-resolution finding in the port notes.

(in-package #:viva.schema)

(defun obj (&rest plist)
  (let ((table (make-hash-table :test #'equal)))
    (loop for (key value) on plist by #'cddr
          do (setf (gethash key table) value))
    table))

;;; A parameter spec is (NAME TYPE DESCRIPTION &key REQUIRED-P ENUM DEFAULT).
;;; TYPE is :STRING :INTEGER :NUMBER :BOOLEAN :OBJECT, (:ARRAY <type>),
;;; (:OBJECT <specs>) for an object whose fields are themselves specs, or NIL
;;; for "any", which is emitted as a schema with no type rather than a guess.

(defparameter +scalar-types+ '(:string :integer :number :boolean :object))

(defun type-schema (type)
  "Refuses a type it does not recognise rather than downcasing it into a schema.

The permissive version emitted a bare :ARRAY as {\"type\": \"array\"} with no
items -- structurally incomplete, silently sent, and invisible locally because
TYPE-MATCHES-P has its own cond that did not match it either, so validation
passed and only the model saw the damage. A typo in a parameter spec has to fail
here, at load time, rather than become a malformed tool schema."
  (cond ((null type) (obj))
        ((and (consp type) (eq :array (first type)))
         (obj "type" "array" "items" (type-schema (second type))))
        ;; (:OBJECT specs) rather than a bare :OBJECT, so a tool taking a list
        ;; of records -- EDIT's replacements are the reason this exists -- can
        ;; advertise their fields instead of shipping an untyped blob and hoping.
        ((and (consp type) (eq :object (first type)))
         (parameter-schema (second type)))
        ((member type +scalar-types+) (obj "type" (string-downcase (symbol-name type))))
        ((eq type :array)
         (error "Parameter type :ARRAY needs an element type, e.g. (:array :string)."))
        (t (error "Unknown parameter type ~s. Expected ~{~s~^, ~}, (:array <type>), (:object <specs>), or NIL for any."
                  type +scalar-types+))))

(defun parameter-json (spec)
  (destructuring-bind (name type description &key required-p enum default) spec
    (declare (ignore name required-p))
    (let ((schema (type-schema type)))
      (setf (gethash "description" schema) description)
      (when enum
        (setf (gethash "enum" schema) (coerce enum 'vector)))
      (when default
        (setf (gethash "default" schema) default))
      schema)))

(defun parameter-schema (parameters)
  "Turn a list of parameter specs into a JSON Schema object."
  (let ((properties (make-hash-table :test #'equal))
        (required '()))
    (dolist (spec parameters)
      (setf (gethash (first spec) properties) (parameter-json spec))
      (when (getf (cdddr spec) :required-p)
        (push (first spec) required)))
    (obj "type" "object"
         "properties" properties
         "required" (coerce (nreverse required) 'vector))))

;;; Validation

(defun type-matches-p (type value)
  (cond ((null type) t)
        ((and (consp type) (eq :array (first type)))
         (or (listp value) (vectorp value)))
        ((and (consp type) (eq :object (first type))) (hash-table-p value))
        (t (case type
             (:string (stringp value))
             (:integer (integerp value))
             (:number (realp value))
             ;; jzon parses JSON booleans to T and NIL, and NIL is also "absent".
             ;; A present-but-false boolean is indistinguishable from a missing
             ;; one here, so accept anything rather than reject a valid call.
             (:boolean t)
             (:object (hash-table-p value))
             (t t)))))

(defun type-label (type)
  (cond ((null type) "any")
        ((and (consp type) (eq :array (first type)))
         (format nil "array of ~a" (type-label (second type))))
        ((and (consp type) (eq :object (first type)))
         (format nil "object with ~{~a~^, ~}" (mapcar #'first (second type))))
        (t (string-downcase (symbol-name type)))))

(defun missing-required (parameters arguments)
  (loop for spec in parameters
        when (and (getf (cdddr spec) :required-p)
                  (null (nth-value 1 (gethash (first spec) arguments))))
          collect (first spec)))

(defun wrong-types (parameters arguments)
  (loop for spec in parameters
        for (name type) = spec
        for value = (gethash name arguments)
        when (and (nth-value 1 (gethash name arguments))
                  (not (type-matches-p type value)))
          collect (format nil "~a should be ~a, got ~s" name (type-label type) value)))

(defun bad-enum (parameters arguments)
  (loop for spec in parameters
        for name = (first spec)
        for enum = (getf (cdddr spec) :enum)
        for value = (gethash name arguments)
        when (and enum (nth-value 1 (gethash name arguments))
                  (not (member value enum :test #'equal)))
          collect (format nil "~a must be one of ~{~s~^, ~}, got ~s" name enum value)))

(defun parameter-label (spec)
  (format nil "~a (~a~:[~;, required~])"
          (first spec) (type-label (second spec)) (getf (cdddr spec) :required-p)))

(defun validate (parameters arguments)
  "NIL when ARGUMENTS satisfy PARAMETERS, otherwise a message saying exactly what
is wrong and what the tool expects."
  (let* ((missing (missing-required parameters arguments))
         (complaints (append (when missing
                               (list (format nil "missing required: ~{~a~^, ~}" missing)))
                             (wrong-types parameters arguments)
                             (bad-enum parameters arguments))))
    (when complaints
      (format nil "~{~a~^; ~}. Expected: ~{~a~^, ~}."
              complaints (mapcar #'parameter-label parameters)))))
