;;;; The image backend: compiling one definition into a running process.
;;;;
;;;; Behind a protocol because there are three real implementations, not a
;;;; hypothetical second one: this plain SBCL backend, genera-lab's ledger- and
;;;; session-aware image, and the forked trial child that must install without
;;;; touching its parent.

(in-package #:vivarium.image)

(defstruct (installation (:conc-name installation-))
  (target "" :type string)
  (warnings '() :type list)
  (error nil))

(define-condition install-error (error)
  ((detail :initarg :detail :reader install-error-detail))
  (:report (lambda (condition stream)
             (write-string (install-error-detail condition) stream))))

(defgeneric install-definition (backend source &key note)
  (:documentation "Compile the single top-level form in SOURCE into the image."))

(defgeneric definition-source (backend target)
  (:documentation "The source text last installed for TARGET, or NIL."))

(defgeneric rollback-definition (backend target)
  (:documentation "Undo the most recent installation of TARGET."))

(defgeneric find-targets (backend pattern)
  (:documentation "Target strings whose name contains PATTERN, case-insensitively."))

;;; Reading a definition out of agent-supplied text

(defun read-one-form (source package-name)
  "Read exactly one form from SOURCE. Signals if there is more than one.
*READ-EVAL* is off: text arriving from a model must not execute at read time."
  (let ((package (or (find-package package-name)
                     (error 'install-error
                            :detail (format nil "No such package: ~a" package-name)))))
    (let ((*package* package)
          (*read-eval* nil))
      (handler-case
          (multiple-value-bind (form position) (read-from-string source)
            (unless (eq :eof (read-from-string source nil :eof :start position))
              (error 'install-error :detail "Expected exactly one top level form, found more."))
            form)
        (install-error (condition) (error condition))
        (error (condition)
          (error 'install-error :detail (format nil "Could not read the form: ~a" condition)))))))

(defun definition-form-p (form)
  "A definition is a DEF... form naming something. Checking only for a list with
a symbol at the head would accept (+ 1 2), which then evaluates -- an agent must
not be able to run arbitrary code through the install path."
  (and (consp form)
       (symbolp (first form))
       (rest form)
       (a:starts-with-subseq "DEF" (symbol-name (first form)))
       (or (symbolp (second form)) (consp (second form)))))

(defun form-target (form)
  "A printable, stable name for what FORM defines, e.g. \"DEFUN CL-USER::FOO\"."
  (unless (definition-form-p form)
    (error 'install-error :detail "Not a definition: expected (DEFUN NAME ...) or similar."))
  (let ((operator (first form))
        (name (second form)))
    (format nil "~a ~a"
            (symbol-name operator)
            (if (symbolp name)
                (format nil "~a::~a" (package-name (symbol-package name)) (symbol-name name))
                (princ-to-string name)))))

(defun evaluate-collecting-warnings (form package-name)
  "Evaluate FORM in PACKAGE-NAME, returning (values ok-p warnings error-text).

Reading in the image's package is not enough. A definition that DERIVES names --
DEFSTRUCT's constructor and accessors, most obviously -- interns them at
macroexpansion time using whatever *PACKAGE* is bound to then. Evaluate outside
the image's package and the definition lands correctly while every symbol it
generated lands somewhere else, which surfaces later as a function that plainly
exists being reported absent.

WITH-COMPILATION-UNIT :OVERRIDE T is what makes an undefined callee visible.
SBCL defers those style warnings to the end of the enclosing compilation unit,
so without a unit of our own they surface long after the install returned -- and
a call to a function the agent has not written yet is exactly the mistake the
agent needs told about."
  (let ((warnings '()))
    (handler-case
        (progn
          (handler-bind ((warning (lambda (warning)
                                    (push (princ-to-string warning) warnings)
                                    (a:when-let ((restart (find-restart 'muffle-warning warning)))
                                      (invoke-restart restart)))))
            (let ((*package* (find-package package-name)))
              (with-compilation-unit (:override t)
                (eval form))))
          (values t (nreverse warnings) nil))
      (error (condition)
        (values nil (nreverse warnings) (princ-to-string condition))))))

;;; The plain SBCL backend

(defclass sbcl-image ()
  ((ledger :initarg :ledger :initform (ledger:make-ledger) :reader image-ledger)
   (package-name :initarg :package :initform "COMMON-LISP-USER" :accessor image-package
                 :documentation "Package that agent-supplied source is read in.")))

(defmethod install-definition ((backend sbcl-image) source &key note)
  (let* ((form (read-one-form source (image-package backend)))
         (target (form-target form)))
    (multiple-value-bind (ok-p warnings error-text)
        (evaluate-collecting-warnings form (image-package backend))
      (when ok-p
        (ledger:record (image-ledger backend) target source :note note :outcome "installed"))
      (make-installation :target target :warnings warnings :error error-text))))

(defun target-name (target)
  "The name part of a target: \"DEFUN SHOP::ORDER-TOTAL\" -> \"SHOP::ORDER-TOTAL\"."
  (let* ((text (string-upcase (string-trim " " target)))
         (space (position #\Space text)))
    (if space (subseq text (1+ space)) text)))

(defun bare-name (target)
  "The symbol name alone: \"SHOP::ORDER-TOTAL\" -> \"ORDER-TOTAL\"."
  (let* ((name (target-name target))
         (separator (search "::" name))
         (separator (or separator (position #\: name))))
    (if separator
        (subseq name (+ separator (if (search "::" name) 2 1)))
        name)))

(defun canonical-target (backend target)
  "Resolve whatever the agent typed to a target this ledger knows.

A fixed tool schema forces the agent to reproduce an exact string, and it will
get the operator prefix or the package wrong. Accepting the name it meant is
cheaper than a retry, and an ambiguous name reports its candidates rather than
silently picking one."
  (let* ((known (remove-duplicates (mapcar #'ledger:entry-target
                                           (ledger:entries (image-ledger backend)))
                                   :test #'string=))
         (exact (find target known :test #'string-equal))
         (by-name (remove (target-name target) known :key #'target-name :test-not #'string=))
         (by-bare (remove (bare-name target) known :key #'bare-name :test-not #'string=)))
    (cond (exact exact)
          ((= 1 (length by-name)) (first by-name))
          ((= 1 (length by-bare)) (first by-bare))
          ((rest by-bare)
           (error 'install-error
                  :detail (format nil "~a is ambiguous. Did you mean: ~{~a~^, ~}?" target by-bare)))
          (t nil))))

(defmethod definition-source ((backend sbcl-image) target)
  (a:if-let ((canonical (canonical-target backend target)))
    (ledger:latest-source (image-ledger backend) canonical)
    (source-from-introspection target)))

(defun definition-symbol (target)
  "Resolve \"DEFUN PKG::NAME\" or a bare \"PKG::NAME\" to a symbol, without interning."
  (let* ((text (string-upcase (string-trim " " target)))
         (space (position #\Space text))
         (name (if space (subseq text (1+ space)) text))
         (separator (search "::" name))
         (separator (or separator (position #\: name))))
    (if separator
        (a:when-let ((package (find-package (subseq name 0 separator))))
          (find-symbol (subseq name (+ separator (if (search "::" name) 2 1))) package))
        (find-symbol name *package*))))

(defvar *value-print-limit* 1200
  "How much of a live value to show. Enough to see the shape of real data.")

(defun live-value-report (symbol)
  "The current value of a variable, which is the thing a file cannot tell you.

Asked for `*STOCK*` and told only that no source was recorded, an agent guessed
it was a hash table and installed a GETHASH against a list of plists. The value
was sitting in the image the whole time. Reporting it is not a convenience --
seeing the data as it actually is, rather than as the source suggests, is the
capability this whole project is about."
  (let ((value (symbol-value symbol)))
    (format nil ";; not installed by this run; live value~%~a = ~a"
            symbol
            (let ((*print-length* 24) (*print-level* 4) (*print-readably* nil))
              (let ((text (handler-case (prin1-to-string value)
                            (error () "#<unprintable>"))))
                (if (> (length text) *value-print-limit*)
                    (concatenate 'string (subseq text 0 *value-print-limit*) " ...")
                    text))))))

(defun source-from-introspection (target)
  "A definition never installed by us is still visible in the running image: a
function has a lambda list, and a variable has a value."
  (a:when-let ((symbol (definition-symbol target)))
    (cond ((fboundp symbol)
           (format nil ";; not installed by this run; live signature only~%(~a ~a)"
                   symbol
                   (or (ignore-errors (sb-introspect:function-lambda-list symbol)) "")))
          ((boundp symbol) (live-value-report symbol)))))

(defmethod rollback-definition ((backend sbcl-image) target)
  (let* ((target (or (canonical-target backend target) target))
         (previous (ledger:previous-source (image-ledger backend) target)))
    (cond (previous
           (let ((result (install-definition backend previous :note "rollback")))
             (if (installation-error result)
                 result
                 (make-installation :target target))))
          (t (undefine backend target)))))

(defun undefine (backend target)
  "No prior version means this run introduced the definition, so removing it is
the rollback. Only the forms this backend can install are handled."
  (let ((symbol (definition-symbol target)))
    (unless symbol
      (return-from undefine
        (make-installation :target target :error (format nil "Unknown target: ~a" target))))
    (cond ((a:starts-with-subseq "DEFUN" (string-upcase target))
           (fmakunbound symbol))
          ((a:starts-with-subseq "DEFMACRO" (string-upcase target))
           (fmakunbound symbol))
          ((or (a:starts-with-subseq "DEFVAR" (string-upcase target))
               (a:starts-with-subseq "DEFPARAMETER" (string-upcase target)))
           (makunbound symbol))
          (t (return-from undefine
               (make-installation
                :target target
                :error (format nil "No previous version of ~a, and it cannot be undefined automatically."
                               target)))))
    (ledger:record (image-ledger backend) target "" :note "undefined" :outcome "rolled back")
    (make-installation :target target)))

(defmethod find-targets ((backend sbcl-image) pattern)
  (let ((needle (string-upcase pattern))
        (found '()))
    (dolist (entry (ledger:entries (image-ledger backend)))
      (pushnew (ledger:entry-target entry) found :test #'string=))
    ;; Collect every definition in the package and let the one filter below
    ;; decide. Matching the SYMBOL NAME here as well meant a search could only
    ;; succeed on the bare name: asking for "DEPOT" found nothing while
    ;; "DEFUN DEPOT::IN-STOCK-P" sat right there, because no symbol is named
    ;; DEPOT. Every benchmark task names its function outright, so none of them
    ;; ever exercised it -- the first real prompt did, and it cost the agent two
    ;; of its requests.
    (do-symbols (symbol (find-package (image-package backend)))
      (when (and (fboundp symbol)
                 (eq (symbol-package symbol) (find-package (image-package backend))))
        (pushnew (format nil "DEFUN ~a::~a" (package-name (symbol-package symbol))
                         (symbol-name symbol))
                 found :test #'string=)))
    (sort (remove-if-not (lambda (target) (search needle (string-upcase target))) found)
          #'string<)))
