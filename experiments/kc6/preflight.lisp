;;;; KC6 pre-check one, reachability: a scripted agent with no LLM traverses
;;;; create, activate, resolve, inherit, promote, revert and discard through
;;;; the real wire, and the ledger is left holding the whole genealogy.
;;;;
;;;; Run before any model runs, and after any change to the evolution owner:
;;;;
;;;;   ./experiments/kc6/preflight.sh
;;;;
;;;; It writes one run's ledger into a fresh directory and prints the path, so
;;;; pre-check three can be computed over it immediately. Both checks exist to
;;;; catch the same class of failure -- an experiment measuring a prompt rather
;;;; than the machinery -- and neither is trustworthy on a ledger holding more
;;;; than the one run it is judging.

(require :sb-posix)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))

(let ((root (uiop:pathname-parent-directory-pathname
             (uiop:pathname-parent-directory-pathname
              (uiop:pathname-directory-pathname *load-truename*)))))
  (push root (symbol-value (find-symbol "*LOCAL-PROJECT-DIRECTORIES*" "QL"))))

(handler-bind ((warning #'muffle-warning))
  (funcall (find-symbol "QUICKLOAD" "QL") :vivarium/daemon :silent t))

(in-package #:vivarium.actor)

(defparameter *component* "kc6-preflight")

(defun say (control &rest arguments)
  (format t "~&  ~?~%" control arguments)
  (finish-output))

(defun resolve-as (task box thunk)
  "Resolve the way a worker does: in ITS OWN THREAD with the task's context
bound. SBCL threads inherit no dynamic bindings, so a preflight that resolved
on this thread would be testing something no worker ever does."
  (let ((result nil))
    (bt:join-thread
     (bt:make-thread
      (lambda ()
        (let ((*activation-box* box)
              (*resolution-task* task)
              (*resolutions-seen* (make-hash-table :test #'equal)))
          (setf result (funcall thunk))))
      :name "kc6-preflight-worker"))
    result))

(defun fail (control &rest arguments)
  (format *error-output* "~&PREFLIGHT FAILED: ~?~%" control arguments)
  (finish-output *error-output*)
  (sb-ext:exit :code 1))

(defun preflight ()
  (let* ((root (or (second sb-ext:*posix-argv*)
                   (format nil "/tmp/kc6-preflight-~36r/" (random (expt 2 30)
                                                                  (make-random-state t)))))
         (parent "kc6-parent")
         (child "kc6-child"))
    (ensure-directories-exist root)
    (setf *journal-root* root)
    (ensure-evolver)
    (say "ledger ~a" (evolution-ledger-path))

    ;; CREATE -> ACTIVATE -> RESOLVE, the task-local channel.
    (multiple-value-bind (v1 condition) (create-candidate *component* '(lambda () :v1))
      (when condition (fail "create refused: ~a" condition))
      (unless (eql v1 (activate-candidate parent v1))
        (fail "activation refused for a live task"))
      (let ((box (task-context-box parent nil)))
        (unless (eq :v1 (resolve-as parent box (lambda () (call-component *component*))))
          (fail "the pin did not resolve in a worker")))
      (say "create, activate, resolve      version ~a" v1)

      ;; INHERIT: the message the supervisor posts before a child's worker
      ;; exists. The child must resolve its parent's pin without activating.
      (evolution-ask :task-spawned child parent)
      (let ((box (task-context-box child nil)))
        (unless (eq :v1 (resolve-as child box (lambda () (call-component *component*))))
          (fail "the child did not inherit its parent's pin")))
      (say "inherit                        ~a -> ~a" parent child)

      ;; PROMOTE, the other reachability channel: a version nobody pinned,
      ;; resolved by a task that pins nothing. This is what a held-out family
      ;; does, and the transfer metric rests entirely on it.
      (multiple-value-bind (v2 condition) (create-candidate *component* '(lambda () :v2))
        (when condition (fail "second create refused: ~a" condition))
        (unless (eql v2 (promote-candidate v2))
          (fail "promotion refused"))
        (let ((box (task-context-box "kc6-fresh" nil)))
          (unless (eq :v2 (resolve-as "kc6-fresh" box (lambda () (call-component *component*))))
            (fail "a promoted default did not resolve for a task with no pins")))
        (say "promote, resolve as default    version ~a" v2)

        ;; REVERT: the lineage steps back for everyone, and no pin moves.
        (multiple-value-bind (v3 condition) (create-candidate *component* '(lambda () :v3))
          (when condition (fail "third create refused: ~a" condition))
          (promote-candidate v3)
          (revert-component *component*)
          (unless (eql v2 (vivarium.evolution:current-promoted (evolution-registry) *component*))
            (fail "revert did not step the lineage back"))
          (say "promote, revert                ~a -> ~a" v3 v2)

          ;; DISCARD, refused while pinned and accepted once nothing runs it.
          (multiple-value-bind (v4 condition) (create-candidate *component* '(lambda () :v4))
            (when condition (fail "fourth create refused: ~a" condition))
            (activate-candidate "kc6-doomed" v4)
            ;; Resolved before it is judged, because that is what a task does
            ;; with a candidate it activated -- and because pre-check three
            ;; reads this ledger: a traversal that activates versions it never
            ;; runs reports the harness as uninstrumental, which was the first
            ;; thing the pair said when run together.
            (let ((box (task-context-box "kc6-doomed" nil)))
              (unless (eq :v4 (resolve-as "kc6-doomed" box
                                          (lambda () (call-component *component*))))
                (fail "the doomed task's pin did not resolve")))
            (unless (equal '(:refused :discard-refused) (discard-candidate v4))
              (fail "a pinned candidate was discardable"))
            (evolution-tell :task-ended "kc6-doomed")
            (sleep 0.2)
            (unless (eql v4 (discard-candidate v4))
              (fail "an unpinned candidate was not discardable"))
            (say "discard refused, then accepted version ~a" v4))))

      ;; The tasks end; pins die with them, by proven law.
      (dolist (task (list parent child))
        (evolution-tell :task-ended task))
      (sleep 0.3)
      (unless (journal-sync) (fail "the ledger never confirmed"))

      ;; And the genealogy survives the image: this is the same fold KC6's
      ;; analysis runs, over the same file.
      (let ((lineage (cdr (assoc *component* (reconstruct-lineage) :test #'equal))))
        (say "lineage from the ledger        ~s" lineage)
        (unless lineage (fail "the ledger reconstructed no lineage"))))

    (format t "~&~%PREFLIGHT PASSED. Ledger: ~a~%" (evolution-ledger-path))
    (finish-output)
    (evolution-ledger-path)))

(let ((path (preflight)))
  (with-open-file (out "/tmp/kc6-preflight-ledger-path" :direction :output
                                                        :if-exists :supersede)
    (write-string path out))
  (sb-ext:exit :code 0))
