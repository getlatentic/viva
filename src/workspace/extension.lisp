;;;; Extensions: code the harness did not ship, changing what the harness does.
;;;;
;;;; This is the seam the whole project needs. Level 2 asks whether an agent can
;;;; change itself for the current task; Level 3 asks whether it can keep the
;;;; change. Both are questions about whether there is anywhere for a change to
;;;; LIVE that outlasts a process and is not a fork of the harness. An extension
;;;; is that place, and an agent that writes one has written a durable
;;;; improvement rather than a temporary one.
;;;;
;;;; An extension is a Lisp file. Loading it runs it, and while it runs its
;;;; registrations attribute to it:
;;;;
;;;;     (extension:defextension "recall"
;;;;       :description "Injects relevant past notes before each request."
;;;;       (extension:register-tool recall-tool)
;;;;       (extension:on :before-request #'inject-relevant-notes))
;;;;
;;;; Loading a file from a repository is arbitrary code execution, so a project
;;;; directory is only loaded once its root has been trusted. The trust record
;;;; is per-root and lives outside the project, where the project cannot edit it.

(in-package #:viva.extension)

(defstruct (command (:conc-name command-))
  (name "" :type string)
  (description "" :type string)
  (handler nil :type (or null function)))

(defstruct (extension (:conc-name extension-))
  (name "" :type string)
  (description "" :type string)
  (path "" :type string)
  (tools '() :type list)
  (commands '() :type list)
  (providers '() :type list)
  (hooks '() :type list))

(defvar *registry* '()
  "Loaded extensions, in load order.")

(defvar *current* nil
  "The extension being loaded, so registrations know whose they are.")

(defun reset-registry ()
  (setf *registry* '()))

(defun loaded-extensions () (reverse *registry*))

(defun current ()
  (or *current*
      (error "Registration outside an extension. Wrap it in DEFEXTENSION.")))

(defmacro defextension (name &body options-and-body)
  "Declare an extension and run its registrations.

  (defextension \"recall\"
    :description \"Injects relevant past notes before each request.\"
    (register-tool recall-tool))"
  (let ((description (getf options-and-body :description ""))
        (body (loop for rest on options-and-body by #'cddr
                    unless (keywordp (first rest))
                      return rest)))
    `(let ((*current* (make-extension :name ,name :description ,description
                                      :path (if *load-truename* (namestring *load-truename*) ""))))
       (register-extension *current*)
       (progn ,@body)
       *current*)))

(defun register-extension (extension)
  "Add EXTENSION, replacing any earlier one of the same name.

Replacing rather than appending is what makes reloading idempotent. Appending
looks harmless until the tool list has two entries called `recall` and the
provider rejects the whole request as malformed -- which is what happened, and
which surfaced as a 400 on the request AFTER the one that reloaded."
  (setf *registry* (remove (extension-name extension) *registry*
                           :key #'extension-name :test #'string=))
  (push extension *registry*)
  extension)

(defun register-tool (tool)
  "Add TOOL to the model's tool set for every run in this process."
  (push tool (extension-tools (current)))
  tool)

(defun register-command (name &key (description "") handler)
  "Add a command the operator can invoke as /NAME in the shell or by name over IPC."
  (let ((command (make-command :name name :description description :handler handler)))
    (push command (extension-commands (current)))
    command))

(defun on (event handler)
  "Subscribe HANDLER to EVENT. See FIRE for the contract."
  (push (cons event handler) (extension-hooks (current)))
  handler)

(defun all-tools ()
  (loop for extension in (loaded-extensions)
        append (reverse (extension-tools extension))))

(defun all-commands ()
  (loop for extension in (loaded-extensions)
        append (reverse (extension-commands extension))))

(defun find-command (name)
  (find name (all-commands) :key #'command-name :test #'string-equal))

;;; Firing
;;;
;;; A handler returning NIL means "I only observed"; returning a value means "use
;;; this instead", and it is threaded into the next handler. That single rule
;;; covers observation, transformation and veto without three mechanisms, and it
;;; makes the order of extensions explicit rather than accidental.

(defun decide (event payload)
  "Ask for a decision. The FIRST handler to answer wins; the rest are not asked.

Different from FIRE, which threads every handler's replacement through the next.
A decision must not be overturnable, or the order of extensions silently becomes
part of the security model -- an extension that refuses `rm -rf` should not be
undone by one loaded after it that merely wanted to add a header."
  (dolist (extension (loaded-extensions) nil)
    (loop for (name . handler) in (reverse (extension-hooks extension))
          when (eq name event)
            do (a:when-let ((answer (handler-case (funcall handler payload)
                                      (error (condition)
                                        (warn "Extension ~a failed on ~a: ~a"
                                              (extension-name extension) event condition)
                                        nil))))
                 (return-from decide answer)))))

(defun register-provider (name provider)
  "Make PROVIDER available under NAME, as a model choice.

Pi's registerProvider. An extension is the right place for it: a gateway with
its own auth, a local server, a proxy that rewrites requests -- none of those
belong in the harness's catalogue, and all of them are one file."
  (push (cons name provider) (extension-providers (current)))
  provider)

(defun all-providers ()
  (loop for extension in (loaded-extensions) append (reverse (extension-providers extension))))

(defun fire (event payload)
  "Run every handler for EVENT over PAYLOAD, threading replacements. Returns the
final payload. A handler that signals is reported and skipped -- one broken
extension must not take the run with it."
  (let ((value payload))
    (dolist (extension (loaded-extensions) value)
      (loop for (name . handler) in (reverse (extension-hooks extension))
            when (eq name event)
              do (handler-case
                     (a:when-let ((replacement (funcall handler value)))
                       (setf value replacement))
                   (error (condition)
                     (warn "Extension ~a failed on ~a: ~a"
                           (extension-name extension) event condition)))))))

;;; Loading

;;; Trust moved to viva.trust when the tool registry turned out to need
;;; the same answer. These stay as the names this package already exported.

(defun trust-file () (trust:trust-file))
(defun trusted-roots (environment) (trust:trusted-roots environment))
(defun trusted-p (environment root) (trust:trusted-p environment root))
(defun trust (environment root) (trust:trust environment root))

(defun extension-directories (environment)
  "Where extensions are looked for: this machine's, then this project's."
  (list (env:home-path "extensions")
        (env:project-path (env:env-cwd environment) "extensions")))

(defun load-file-safely (path)
  (handler-case (progn (load path) nil)
    (error (condition)
      (format nil "~a did not load: ~a" path condition))))

(defun load-extensions (environment &key (directories (extension-directories environment))
                                      (require-trust t))
  "Load every .lisp file in DIRECTORIES. Returns a list of complaints.

A directory inside the working tree is skipped unless its root has been trusted,
because loading it executes it and the working tree is exactly the thing an
untrusted repository controls."
  (let ((complaints '())
        (project (env:env-cwd environment)))
    (dolist (directory directories (nreverse complaints))
      (when (env:path-exists-p environment directory)
        (cond ((and require-trust
                    (a:starts-with-subseq project directory)
                    (not (trusted-p environment project)))
               (push (format nil "~a was not loaded: ~a is not a trusted project. ~
Trust it to enable its extensions." directory project)
                     complaints))
              (t
               (dolist (info (sort (env:list-directory environment directory)
                                   #'string< :key #'env:info-name))
                 (when (a:ends-with-subseq ".lisp" (env:info-name info))
                   (a:when-let ((complaint (load-file-safely (env:info-path info))))
                     (push complaint complaints))))))))))

;;; Declared rather than discovered
;;;
;;; A DIRECTORY SCAN IS NOT A DECLARATION. Everything above loads whatever it
;;; finds, which is the right shape for a directory a person keeps their own
;;; files in and the wrong one for saying what this installation is. Nothing can
;;; name a capability, disable one, or refer to something already in the binary.
;;;
;;; So a capability registers itself under a name, and `config` says which names
;;; are active. A built-in and a file somebody wrote are then the same kind of
;;; thing, differing only in where the code came from -- which is the whole
;;; point: the bare harness is the baseline, and everything past it is something
;;; the configuration asked for.
;;;
;;; A CONTRIBUTION IS TOOLS AND PROMPT, and deliberately no more. Those two are
;;; what the agent surface already takes, so this adds a way to select what is
;;; there rather than a second way to reach it. A capability needing more than
;;; the two is the signal to widen this on purpose.

(defvar *builtins* '()
  "NAME -> (DESCRIPTION . CONTRIBUTE). CONTRIBUTE is called at request-assembly
time and returns a plist of :TOOLS and :PROMPT.

CALLED LATE, not at registration: what a capability offers can depend on what
the organism has done to itself since it started, and a list captured at load
time would be the list before any of that.")

(defun register-builtin (name contribute &key (description ""))
  "Offer NAME as a capability this build can be asked for."
  (setf *builtins* (cons (cons name (cons description contribute))
                         (remove name *builtins* :key #'car :test #'equal)))
  name)

(defun builtin-names ()
  (sort (mapcar #'car *builtins*) #'string<))

(defun builtin-description (name)
  (a:when-let ((found (assoc name *builtins* :test #'equal)))
    (second found)))

(defun declared (setting)
  "The capability names SETTING asks for.

`on` AND `off` STILL WORK. KC6's three arms are written in them and its results
name them, so the words that produced published numbers keep meaning what they
meant: `on` is the self-modification door, `off` is nothing at all."
  (let ((given (string-trim " " (or setting ""))))
    (cond ((or (zerop (length given)) (string-equal "off" given)) '())
          ((string-equal "on" given) (list "self-modify"))
          (t (remove ""
                     (mapcar (lambda (part) (string-trim " " part))
                             (uiop:split-string given :separator ","))
                     :test #'equal)))))

(defun contributions (names)
  "What NAMES contribute, as (values TOOLS PROMPTS COMPLAINTS).

A NAME NOBODY REGISTERED IS A COMPLAINT, not a silence. A configuration that
asks for a capability and gets none has been misread, and the only thing worse
than a setting that does nothing is one that does nothing quietly."
  (let ((tools '()) (prompts '()) (complaints '()))
    (dolist (name names)
      (a:if-let ((found (assoc name *builtins* :test #'equal)))
        (let ((offered (handler-case (funcall (cddr found))
                         (error (condition)
                           (push (format nil "~a could not be enabled: ~a" name condition)
                                 complaints)
                           '()))))
          (setf tools (append tools (getf offered :tools)))
          (a:when-let ((prompt (getf offered :prompt)))
            (setf prompts (append prompts (list prompt)))))
        (push (format nil "no capability called ~s. This build offers: ~{~a~^, ~}"
                      name (or (builtin-names) (list "none")))
              complaints)))
    (values tools prompts (nreverse complaints))))
