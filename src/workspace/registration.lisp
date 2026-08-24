;;;; Writing a tool into the registry, and refusing one that misdescribes itself.
;;;;
;;;; A `tool.json` is written by a model and describes a script the same model
;;;; wrote. Nothing checked that the two agreed, and the way they disagree is
;;;; expensive: the manifest omits a parameter the script requires, so the
;;;; model calls the tool without it, the script fails on a missing key deep in
;;;; its own body, and the failure lands in a LATER task, on a DIFFERENT agent
;;;; than the one that wrote it -- which then spends turns guessing at a
;;;; signature nobody wrote down.
;;;;
;;;; In-image tools never had this problem: derive.lisp reads the schema off
;;;; the live function, so it cannot go stale. File-backed tools gave that
;;;; property up and nothing replaced it. This replaces it.
;;;;
;;;; THE SEAM IS A DECLARED CALLING CONVENTION, not a probe with real
;;;; arguments. A script that receives parameters MUST answer a describe
;;;; request -- `{"vivarium":"describe"}` on stdin -- with its own parameter
;;;; list, and must do nothing else when asked. Then the script is the
;;;; authority on its own interface and the manifest is a cache of it, so
;;;; there is no second copy free to drift. Probing with invented real
;;;; arguments was the alternative and it runs the tool for effect at
;;;; registration, which is a side effect nobody asked for.
;;;;
;;;; A tool that declares NO parameters is not probed. There is nothing for it
;;;; to lie about, and every tool graduation writes is of that shape -- so the
;;;; cost of this check falls exactly on the tools that carry the risk.
;;;;
;;;; AT REGISTRATION, not at load and not at first call. Registration is when
;;;; the model that wrote both files is still there to fix them. Loading is too
;;;; late to be useful and too expensive to run a script for.

(in-package #:vivarium.registry)

(defvar *on-register* nil
  "Called with a tool's name after it is registered, or NIL.

A HOOK rather than a call, because the evolution ledger lives in the daemon and
the daemon loads after this file. A registry that reached upward for it would
invert the dependency and make the workspace unusable without a daemon. Nil by
default: the ledger is the daemon's, so registering without one is registering
without a ledger, which is what a plain `vivarium run` should do.")

(defparameter *describe-request* "{\"vivarium\":\"describe\"}"
  "What a script is sent to make it state its own interface.")

(defparameter *describe-timeout* 20
  "Seconds a describe may take. A script that hangs answering what it takes is
refused rather than waited for.")

(defun digest-of (text)
  "A 64-bit FNV-1a of TEXT, as hex.

For noticing that a script CHANGED, not for defending against somebody who
wants it to appear unchanged. Nothing here is a security boundary -- the
registry already refuses to load an untrusted project at all -- and a
dependency-free eight lines is the right size for the job it does."
  (let ((hash 14695981039346656037))
    (loop for character across (or text "")
          do (setf hash (logand (* (logxor hash (char-code character)) 1099511628211)
                                #xFFFFFFFFFFFFFFFF)))
    (format nil "~(~16,'0x~)" hash)))

(defun script-path (directory exec)
  "The file EXEC actually runs, or NIL if it names none in DIRECTORY."
  (loop for argument in exec
        for beside = (merge-pathnames argument (uiop:ensure-directory-pathname directory))
        when (probe-file beside) return (namestring beside)))

(defun described-parameters (entry directory)
  "What the script says it takes. Returns (values LIST REASON).

LIST holds (NAME TYPE REQUIRED) per parameter, or NIL with a reason if the
script would not say."
  (multiple-value-bind (exit output)
      (let ((*timeout* *describe-timeout*))
        (run-entry entry (com.inuoe.jzon:parse *describe-request*) directory))
    (cond
      ((not (zerop exit))
       (values nil (format nil "the script did not answer a describe request ~
(exit ~d~@[: ~a~]). A tool that takes parameters must answer ~a on stdin with ~
its own parameter list." exit (and (plusp (length output)) (string-trim '(#\Newline) output))
                           *describe-request*)))
      (t
       (let ((table (handler-case (com.inuoe.jzon:parse output)
                      (error () nil))))
         (cond
           ((not (hash-table-p table))
            (values nil (format nil "the script's describe answer is not a JSON object: ~s"
                                (subseq output 0 (min 200 (length output))))))
           ((not (vectorp (field table "parameters")))
            (values nil "the script's describe answer has no parameters array"))
           (t (values (loop for spec across (field table "parameters")
                            collect (list (field spec "name")
                                          (field spec "type")
                                          (eq t (field spec "required"))))
                      nil))))))))

(defun disagreement (declared described)
  "Why DECLARED and DESCRIBED are not the same interface, or NIL.

Both directions matter and they fail differently. A manifest that promises a
parameter the script ignores wastes a turn sending it. A manifest that omits
one the script REQUIRES is the expensive one -- the model cannot send what it
was never told about, and finds out inside somebody else's traceback."
  (flet ((declared-name (spec) (first spec))
         (declared-type (spec) (string-downcase (symbol-name (second spec))))
         (declared-required (spec) (getf (cdddr spec) :required-p)))
    (or
     (loop for spec in declared
           for match = (find (declared-name spec) described :key #'first :test #'equal)
           thereis (cond
                     ((null match)
                      (format nil "the manifest declares ~s but the script does not accept it"
                              (declared-name spec)))
                     ((not (equal (declared-type spec) (second match)))
                      (format nil "the manifest calls ~s a ~a; the script calls it a ~a"
                              (declared-name spec) (declared-type spec) (second match)))))
     (loop for spec in described
           when (and (third spec)
                     (not (find (first spec) declared :key #'declared-name :test #'equal)))
             return (format nil "the script requires ~s, which the manifest does not declare"
                            (first spec))))))

(defun manifest-text (name description exec parameters digest)
  (com.inuoe.jzon:stringify
   (a:alist-hash-table
    (list (cons "name" name)
          (cons "description" description)
          (cons "exec" (coerce exec 'vector))
          (cons "digest" digest)
          (cons "parameters"
                (map 'vector
                     (lambda (spec)
                       (a:alist-hash-table
                        (list (cons "name" (first spec))
                              (cons "type" (string-downcase (symbol-name (second spec))))
                              (cons "description" (or (third spec) ""))
                              (cons "required" (if (getf (cdddr spec) :required-p) t nil)))
                        :test #'equal))
                     parameters)))
    :test #'equal)
   :pretty t))

(defun register (environment &key name description exec parameters script script-name)
  "Write a tool into this project's registry. Returns (values NAME REASON).

The script is written first and the manifest last, so a refusal leaves no
manifest -- a directory with a script and no tool.json is invisible to the
loader, where a manifest naming a script that was never checked is a tool the
model will call."
  (let* ((directory (env:project-path (env:env-cwd environment) "tools" name))
         (digest (digest-of script)))
    (handler-case
        (progn
          (env:ensure-directory environment directory)
          (env:write-text environment (env:join-path directory script-name) script)
          (let ((entry (make-entry :name name :description description
                                   :exec (coerce exec 'list)
                                   :parameters parameters :directory directory)))
            ;; Only a tool that takes parameters can misdescribe what it takes.
            (when parameters
              (multiple-value-bind (described reason) (described-parameters entry directory)
                (when reason (return-from register (values nil reason)))
                (a:when-let ((wrong (disagreement parameters described)))
                  (return-from register (values nil wrong)))))
            (env:write-text environment (env:join-path directory "tool.json")
                            (manifest-text name description exec parameters digest))
            ;; After the manifest, never before: a registration that was
            ;; refused must leave no ledger entry claiming it happened.
            (when *on-register*
              (ignore-errors (funcall *on-register* name)))
            (values name nil)))
      (error (condition)
        (values nil (format nil "could not register ~a: ~a" name condition))))))

;;; Staleness, which is a load-time question

(defun stale-reason (environment entry manifest-digest)
  "Why ENTRY should not be called, or NIL.

A manifest that recorded a digest is making a claim about the script beside
it. If the script has changed since, the manifest describes something that no
longer exists, and calling it is how a model learns the signature moved. A
manifest with no digest makes no claim and is left alone -- every tool written
before this existed is of that kind."
  (when manifest-digest
    (a:when-let ((path (script-path (entry-directory entry) (entry-exec entry))))
      (let ((text (ignore-errors (env:read-text environment path))))
        (when (and text (not (equal manifest-digest (digest-of text))))
          (format nil "~a is stale: ~a has changed since its manifest was written. ~
Register it again so the two agree."
                  (entry-name entry) (file-namestring path)))))))
