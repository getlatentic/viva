;;;; Reading model-emitted s-expressions, and the grammars that constrain them.

(in-package #:viva.tests)

;;; Reading

(define-test "a form reads back as a list"
  (let ((form (sexp:read-form "(shipping-cost :weight 7)")))
    (is = 3 (length form))
    (is string= "SHIPPING-COST" (symbol-name (first form)))
    (is eq :weight (second form))
    (is = 7 (third form))))

(define-test "read-eval is off, so a form cannot execute while being read"
  ;; #. is the whole reason a naive READ on model output is unsafe.
  (fail (sexp:read-form "(install :source #.(error \"pwned\"))") 'sexp:unreadable))

(define-test "symbols intern into a sandbox, not into a package that matters"
  (let ((form (sexp:read-form "(some-tool :key totally-new-symbol)")))
    (is string= "VIVA.SEXP.SANDBOX" (package-name (symbol-package (first form))))
    (false (find-symbol "TOTALLY-NEW-SYMBOL" '#:common-lisp-user))))

(define-test "two forms are refused, as are unbalanced ones"
  (fail (sexp:read-form "(a :b 1) (c :d 2)") 'sexp:unreadable)
  (fail (sexp:read-form "(a :b 1") 'sexp:unreadable))

(define-test "an over-long form is refused before it is read"
  (let ((sexp:*limit* 40))
    (fail (sexp:read-form (format nil "(x :y \"~a\")" (make-string 100 :initial-element #\a)))
          'sexp:unreadable)))

;;; A call as a form

(define-test "a call converts to the same arguments table the JSON path builds"
  (multiple-value-bind (name arguments)
      (sexp:call-arguments (sexp:read-form "(shipping-cost :weight 7 :express t)"))
    (is string= "shipping_cost" name)
    (is = 7 (gethash "weight" arguments))
    (is eq t (gethash "express" arguments))))

(define-test "a false boolean is really false, not a same-named foreign symbol"
  ;; In a package that inherits nothing, the model's `nil` reads as a fresh
  ;; symbol named "NIL" which is true. Every boolean argument would then mean
  ;; its opposite, silently.
  (multiple-value-bind (name arguments)
      (sexp:call-arguments (sexp:read-form "(shipping-cost :weight 1 :express nil)"))
    (declare (ignore name))
    (false (gethash "express" arguments))
    (is eq cl:nil (gethash "express" arguments))))

(define-test "a keyword name with a hyphen maps to the tool's parameter name"
  (multiple-value-bind (name arguments)
      (sexp:call-arguments (sexp:read-form "(read-definition :target \"DEFUN SHOP::TOTAL\")"))
    (is string= "read_definition" name)
    (is string= "DEFUN SHOP::TOTAL" (gethash "target" arguments))))

(define-test "a definition passes as a form, with no escaping at all"
  ;; The JSON path carries this as a string with every quote and newline
  ;; escaped. Here it is just a list.
  (multiple-value-bind (name arguments)
      (sexp:call-arguments
       (sexp:read-form "(install :source (defun total (lines) (reduce #'+ lines)))"))
    (is string= "install" name)
    (let ((source (gethash "source" arguments)))
      (is string= "DEFUN" (symbol-name (first source)))
      (is string= "TOTAL" (symbol-name (second source))))))

(define-test "a malformed call is reported rather than half-read"
  (fail (sexp:call-arguments (sexp:read-form "(tool 1 2 3)")) 'sexp:unreadable)
  (fail (sexp:call-arguments (sexp:read-form "(tool :key)")) 'sexp:unreadable)
  (fail (sexp:call-arguments (sexp:read-form "42")) 'sexp:unreadable))

;;; Grammars
;;;
;;; llama.cpp builds one of these from a JSON Schema automatically. Nothing does
;;; it for s-expressions, so the Lisp arm has to bring its own or the comparison
;;; is between a constrained format and an unconstrained one.

(define-test "a required parameter is mandatory in the grammar, an optional one is not"
  (let ((grammar (sexp:grammar-for "shipping_cost"
                                   '(("weight" :integer "kg" :required-p t)
                                     ("express" :boolean "fast?")))))
    (true (search "\"(shipping_cost\"" grammar))
    (true (search "\" :weight \" integer" grammar))
    (true (search "(\" :express \" boolean)?" grammar))
    ;; The terminals a call can use must be defined, or the grammar is unusable.
    (true (search "integer ::=" grammar))
    (true (search "list ::=" grammar))))

(define-test "an enum becomes a literal alternation, not a free string"
  (let ((grammar (sexp:grammar-for "pick" '(("mode" :string "how" :required-p t
                                             :enum ("fast" "slow"))))))
    (true (search "(\"fast\" | \"slow\")" grammar))))

(define-test "several tools become alternatives under one root"
  (let ((grammar (sexp:grammar-for-tools
                  '(("install" ("source" nil "a form" :required-p t))
                    ("rollback" ("target" :string "what" :required-p t))))))
    (true (search "root ::= (call0 | call1)" grammar))
    (true (search "call0 ::= \"(install\"" grammar))
    (true (search "call1 ::= \"(rollback\"" grammar))))

(define-test "an arbitrary-form grammar admits nesting"
  (true (search "root ::= list" (sexp:form-grammar)))
  (true (search "value ::= atom | list" (sexp:form-grammar))))

(define-test "a channel prefix is folded into the root, not appended after it"
  ;; A grammar constrains the whole completion. Without the model's own framing,
  ;; llama-server rejects its own model's output as unparseable -- verified as a
  ;; 500 against gpt-oss.
  (let ((grammar (sexp:grammar-for "install" '(("note" :string "why" :required-p t))
                                   :prefix provider:+harmony-output-prefix+)))
    (true (search "root ::= \"<|channel|>final<|message|>\" \"(install\"" grammar)))
  (let ((many (sexp:grammar-for-tools '(("a" ("x" :string "x" :required-p t))
                                        ("b" ("y" :string "y" :required-p t)))
                                      :prefix provider:+harmony-output-prefix+)))
    (true (search "root ::= \"<|channel|>final<|message|>\" (call0 | call1)" many)))
  ;; Default is no prefix, which is right for a raw endpoint.
  (true (search "root ::= \"(install\"" (sexp:grammar-for "install" '()))))
