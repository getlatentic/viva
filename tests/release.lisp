;;;; The install surface: what a person who has never seen this repository hits.
;;;;
;;;; Everything else in this suite tests the harness. These test the front door,
;;;; because a clean-machine run found that the first command a newcomer types
;;;; to check their install -- `vivarium test` -- was the one command that could
;;;; not work on a clean machine, and nothing here would ever have noticed: the
;;;; suite only ever ran on a machine where the dependency was already present.
;;;;
;;;; The rule these encode is that a claim in a file a newcomer reads is a claim
;;;; the suite checks. Documentation drifts silently; a red test does not.

(in-package #:vivarium.tests)

(defun repository-file (relative)
  (uiop:read-file-string
   (merge-pathnames relative (asdf:system-source-directory "vivarium"))))

(define-test "every provider in the catalogue is named in .env.example"
  ;; A provider added to the catalogue and not to the example is a provider
  ;; nobody can discover: the error message names the key, but only once you
  ;; have already failed to configure anything.
  (let ((example (repository-file ".env.example")))
    (dolist (entry models::+catalogue+)
      (dolist (variable (list (getf entry :key)
                              (getf entry :endpoint-var)
                              (getf entry :model-var)))
        (true (search variable example)
              "~a is in the catalogue but not in .env.example" variable)))))

(define-test ".env.example carries names and never a value"
  ;; The file is committed, so a key pasted into it is a key published. Every
  ;; assignment is either empty or a commented-out default.
  (dolist (line (uiop:split-string (repository-file ".env.example")
                                   :separator '(#\Newline)))
    (let ((trimmed (string-left-trim " " line)))
      (unless (or (zerop (length trimmed)) (char= #\# (char trimmed 0)))
        (let ((equals (position #\= trimmed)))
          (true equals "~s is neither a comment nor an assignment" line)
          (when equals
            (is string= "" (subseq trimmed (1+ equals))
                "~a has a value in a committed file" (subseq trimmed 0 equals))))))))

(define-test ".env.example is not swallowed by the .env ignore"
  ;; `.env.*` was added before `.env.example` existed and matched it exactly.
  ;; Writing the file is not the same as shipping it.
  (true (search "!.env.example" (repository-file ".gitignore"))))

(define-test "the test system is loaded the way that resolves its dependencies"
  ;; ASDF resolves dependencies and never downloads them. The bootstrap
  ;; quickloads the CLI, so a clean machine gets every dependency except
  ;; parachute -- which only the test system wants, and which ASDF:LOAD-SYSTEM
  ;; therefore could never obtain.
  (let ((source (repository-file "src/cli/commands.lisp")))
    (false (search "(asdf:load-system \"vivarium/tests\")" source)
           "vivarium/tests must be loaded through LOAD-TEST-SYSTEM, ~
which fetches what ASDF alone cannot")))
