;;;; Deriving a tool definition from a function that is already in the image.
;;;;
;;;; In a file-based harness a tool schema is hand-written next to the code and
;;;; drifts from it. Here the lambda list, the argument types and the docstring
;;;; are all live objects, so the schema is read off the function itself. Two
;;;; consequences worth stating plainly:
;;;;
;;;;   - a schema cannot go stale, because redefining the function redefines it;
;;;;   - an agent that installs a DEFUN has thereby written a tool, with no
;;;;     schema to author. That is what makes capability injection ([E3]) usable
;;;;     by an agent rather than only by a person editing the harness.
;;;;
;;;; SBCL derives argument types even without declarations, so ORDER-TOTAL above
;;;; yields (FUNCTION (LIST &KEY (:TAX SINGLE-FLOAT) ...)) with no help.

(in-package #:vivarium.derive)

(defun json-type (cl-type)
  "Map a Common Lisp type specifier to a schema type, or NIL for \"any\".
Guessing a type where SBCL derived none would advertise a constraint the
function does not actually have."
  (let ((head (if (consp cl-type) (first cl-type) cl-type)))
    (case head
      ((string simple-string base-string) :string)
      ((integer fixnum bignum unsigned-byte signed-byte) :integer)
      ((number real float single-float double-float rational ratio) :number)
      ((boolean) :boolean)
      ((list cons sequence vector simple-vector) '(:array nil))
      ((hash-table) :object)
      ((symbol keyword) :string)
      (t nil))))

(defun split-lambda-list (lambda-list)
  "Return (values required optional keys), each a list of symbols."
  (let ((section :required) (required '()) (optional '()) (keys '()))
    (dolist (item lambda-list)
      (case item
        (&optional (setf section :optional))
        (&key (setf section :key))
        ((&rest &aux &allow-other-keys &body) (setf section :ignored))
        (t (let ((name (if (consp item) (first item) item)))
             (case section
               (:required (push name required))
               (:optional (push name optional))
               (:key (push name keys)))))))
    (values (nreverse required) (nreverse optional) (nreverse keys))))

(defun argument-types (symbol)
  "Return (values positional-types key-type-alist) from the derived ftype."
  (let ((ftype (ignore-errors (sb-introspect:function-type symbol))))
    (unless (and (consp ftype) (eq 'function (first ftype)))
      (return-from argument-types (values '() '())))
    (let ((arguments (second ftype))
          (positional '()) (keys '()) (section :required))
      (dolist (item arguments)
        (case item
          (&optional (setf section :optional))
          (&key (setf section :key))
          ((&rest &allow-other-keys) (setf section :ignored))
          (t (if (eq section :key)
                 (when (consp item) (push (cons (first item) (second item)) keys))
                 (unless (eq section :ignored) (push item positional))))))
      (values (nreverse positional) (nreverse keys)))))

(defun parameter-name (symbol)
  (string-downcase (symbol-name symbol)))

(defun docstring-lines (symbol)
  (or (documentation symbol 'function) ""))

(defun build-parameters (symbol)
  "Parameter specs for SYMBOL, required for positionals and optional for the rest."
  (multiple-value-bind (required optional keys) (split-lambda-list
                                                 (sb-introspect:function-lambda-list symbol))
    (multiple-value-bind (positional-types key-types) (argument-types symbol)
      (append
       (loop for name in required
             for type in (append positional-types (make-list (length required)))
             collect (list (parameter-name name) (json-type type)
                           (format nil "~a" (parameter-name name)) :required-p t))
       (loop for name in optional
             collect (list (parameter-name name) nil (parameter-name name)))
       (loop for name in keys
             for type = (cdr (assoc (intern (symbol-name name) :keyword) key-types))
             collect (list (parameter-name name) (json-type type) (parameter-name name)))))))

(defun call-with-arguments (symbol parameters arguments)
  "Apply SYMBOL to the values the model supplied, in lambda-list order."
  (multiple-value-bind (required optional keys) (split-lambda-list
                                                 (sb-introspect:function-lambda-list symbol))
    (declare (ignore optional))
    (let ((positional (loop for name in required
                            collect (gethash (parameter-name name) arguments)))
          (keyword-arguments (loop for name in keys
                                   for key = (parameter-name name)
                                   when (nth-value 1 (gethash key arguments))
                                     append (list (intern (symbol-name name) :keyword)
                                                  (gethash key arguments)))))
      (declare (ignore parameters))
      (apply symbol (append positional keyword-arguments)))))

(defun derive-tool (symbol &key name description)
  "A tool that calls SYMBOL, with its schema read off the live function."
  (unless (fboundp symbol)
    (error "Cannot derive a tool from ~a: it is not a function." symbol))
  (let ((parameters (build-parameters symbol)))
    (make-instance 'tool:function-tool
                   :name (or name (substitute #\_ #\- (parameter-name symbol)))
                   :description (or description (docstring-lines symbol))
                   :parameters parameters
                   :body (lambda (arguments context)
                           (declare (ignore context))
                           (princ-to-string (call-with-arguments symbol parameters arguments))))))
