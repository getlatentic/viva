;;;; Retiring what stopped earning its place.
;;;;
;;;; The reflection turn writes and nothing removes, so every skill and tool it
;;;; retains is permanent by default -- and the cost of a wrong retention is
;;;; paid on every later task, in loaded context, forever. A year of reflection
;;;; becomes a folder nobody reads and everybody pays for.
;;;;
;;;; ONE COUNTER, TWO DIRECTIONS. The same count that graduates a skill to a
;;;; tool when reuse is evident (#8) retires it when disuse is. A second
;;;; counter for the second question would be a second thing to keep in step.
;;;;
;;;; RETIRED, NOT DELETED. A retirement is a judgement made by a threshold, and
;;;; thresholds are wrong sometimes. Moving the directory into
;;;; `.vivarium/retired/` stops it loading, leaves it readable, and makes the
;;;; undo `mv` -- or `git checkout`, since these are files in somebody's
;;;; repository. Deleting would make a wrong retirement unrecoverable and
;;;; silent at once.

(in-package #:vivarium.decay)

(defparameter *window-days* 30
  "Days a retention may go unused before it is retired. Codex's pipeline calls
this max_unused_days and treats it as half the design rather than an
afterthought.")

(defparameter *keep-above-uses* 5
  "A retention used at least this often is kept regardless of when it was last
reached for. Something used twenty times and quiet for a month is seasonal, not
dead, and retiring it is how a person learns not to trust the mechanism.")

(defconstant +seconds-per-day+ 86400)

(defstruct (retirement (:conc-name retirement-))
  (name "" :type string)
  (kind :skill :type keyword)
  (uses 0 :type integer)
  (idle-days 0 :type integer)
  (from "" :type string)
  (to "" :type string))

(defun idle-days (last-used now)
  (if last-used
      (max 0 (floor (- now last-used) +seconds-per-day+))
      0))

(defun retire-p (uses last-used now &key (window *window-days*) (keep *keep-above-uses*))
  "Should something with this history be retired?

A retention with NO last-used stamp is kept. It was written before the stamp
existed, and retiring on missing evidence would delete the history of everyone
who upgraded rather than the retentions that stopped paying."
  (and last-used
       (< uses keep)
       (>= (idle-days last-used now) window)))

(defun retired-directory (environment kind)
  (env:join-path (env:env-cwd environment) ".vivarium" "retired"
                 (string-downcase (symbol-name kind))))

(defun retire (environment kind name from &key uses idle-days)
  "Move one retention out of the way. Returns a RETIREMENT, or NIL if it could
not be moved -- in which case it stays loaded, which is the safe direction."
  (let* ((into (retired-directory environment kind))
         (to (env:join-path into name)))
    (when (ignore-errors
           (env:ensure-directory environment into)
           (env:rename-path environment from to)
           t)
      (make-retirement :name name :kind kind :uses (or uses 0)
                       :idle-days (or idle-days 0) :from from :to to))))

(defun describe-retirement (retirement)
  (format nil "retired ~a ~a: ~[never used~:;used ~:*~d time~:p~] ~
and untouched for ~d days. It is in ~a, not deleted."
          (string-downcase (symbol-name (retirement-kind retirement)))
          (retirement-name retirement)
          (retirement-uses retirement)
          (retirement-idle-days retirement)
          (retirement-to retirement)))

(defun sweep-skills (environment skills &key (now (get-universal-time))
                                             (window *window-days*)
                                             (keep *keep-above-uses*))
  "Retire the skills that have stopped earning their place. Returns a list of
RETIREMENTs, which the caller shows -- a retirement nobody is told about is
indistinguishable from a bug."
  (loop for skill in skills
        for uses = (skill:uses-of environment skill)
        for last-used = (skill:last-used-of environment skill)
        when (retire-p uses last-used now :window window :keep keep)
          append (a:when-let
                     ((done (retire environment :skill (skill:skill-name skill)
                                    (env:parent-path (skill:skill-path skill))
                                    :uses uses :idle-days (idle-days last-used now))))
                   (list done))))
