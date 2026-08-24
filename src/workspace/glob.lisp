;;;; Glob matching and ignore rules.
;;;;
;;;; Both exist for one reason: a repository search that does not honour
;;;; .gitignore returns forty thousand paths out of node_modules and .git, which
;;;; is not a slow answer but a wrong one -- it fills the context window with
;;;; material the agent did not ask for and cannot use.
;;;;
;;;; Globs compile to regular expressions rather than a bespoke matcher. The
;;;; translation is small enough to read in one sitting, and the alternative is
;;;; reimplementing backtracking for `**`.

(in-package #:vivarium.glob)

(defun quoted (character)
  (if (find character "\\^$.|?*+()[]{}")
      (format nil "\\~a" character)
      (string character)))

(defun bracket-expression (pattern start)
  "Translate the [...] beginning at START. Returns (values regex next-index)."
  (let ((end (position #\] pattern :start (if (and (< (1+ start) (length pattern))
                                                   (find (char pattern (1+ start)) "!^"))
                                              (+ start 2)
                                              (1+ start)))))
    (if (null end)
        (values "\\[" (1+ start))
        (let ((body (subseq pattern (1+ start) end)))
          (values (format nil "[~a]" (if (a:starts-with #\! body)
                                         (format nil "^~a" (subseq body 1))
                                         body))
                  (1+ end))))))

(defun glob-regex (pattern)
  "PATTERN as an anchored regular expression.

`*` and `?` stop at a separator, `**` crosses them, and `**/` also matches
nothing at all so that `**/*.lisp` finds a file in the root directory."
  (let ((length (length pattern)))
    (with-output-to-string (out)
      (write-char #\^ out)
      (loop with index = 0
            while (< index length)
            for character = (char pattern index)
            do (case character
                 (#\* (cond ((and (< (1+ index) length) (char= #\* (char pattern (1+ index))))
                             (cond ((and (< (+ index 2) length) (char= #\/ (char pattern (+ index 2))))
                                    (write-string "(?:.*/)?" out)
                                    (incf index 3))
                                   (t (write-string ".*" out)
                                      (incf index 2))))
                            (t (write-string "[^/]*" out)
                               (incf index))))
                 (#\? (write-string "[^/]" out) (incf index))
                 (#\[ (multiple-value-bind (regex next) (bracket-expression pattern index)
                        (write-string regex out)
                        (setf index next)))
                 (t (write-string (quoted character) out)
                    (incf index))))
      (write-char #\$ out))))

(defun compile-glob (pattern)
  (cl-ppcre:create-scanner (glob-regex pattern)))

(defun matches-p (pattern path)
  "Does PATH match PATTERN?

A pattern naming no directory matches on the base name, so `*.lisp` finds
`src/core/tool.lisp`. This is what `fd` does and what a model means by it; the
alternative silently returns nothing for the most common query there is."
  (let ((scanner (compile-glob pattern)))
    (or (and (cl-ppcre:scan scanner path) t)
        (and (not (find #\/ pattern))
             (a:when-let ((slash (position #\/ path :from-end t)))
               (and (cl-ppcre:scan scanner (subseq path (1+ slash))) t))))))

;;; Ignore rules
;;;
;;; A useful subset of gitignore: comments, negation, anchoring, directory-only
;;; patterns and depth-independent names. What is deliberately absent is the
;;; rule that a negation cannot resurrect a file whose parent directory was
;;; excluded -- traversal skips ignored directories before descending, so the
;;; case cannot arise here.

(defstruct (rule (:conc-name rule-))
  (scanner nil)
  (negated-p nil :type boolean)
  (directory-only-p nil :type boolean))

(defstruct (ignore-set (:conc-name ignore-set-) (:constructor %make-ignore-set))
  (rules '() :type list))

(defparameter +default-ignores+ '(".git/" ".viva/" ".vivarium/")
  "Always excluded from a recursive walk. Not configurable.

.git because an agent that greps its way into it finds every version of every
file it was just shown, which is a context-window denial of service rather than
a search result.

.viva because it is the harness's own state -- sessions, memory, skills --
and a search that returns the transcript of the search is worse than noise: it
has been observed sending a worker off to investigate its own conversation.
Both spellings, because a machine installed before the rename still keeps its
state under the former name. Nothing is hidden by this: LS still lists it and
READ still opens it. Only the recursive walk declines to wander in.")

(defun make-ignore-set (&optional (patterns +default-ignores+))
  (let ((set (%make-ignore-set)))
    (add-patterns set patterns "")
    set))

(defun add-patterns (set patterns prefix)
  "Add PATTERNS, anchored under PREFIX -- the directory the rules came from,
relative to the traversal root."
  (dolist (pattern patterns set)
    (a:when-let ((rule (parse-rule pattern prefix)))
      (push rule (ignore-set-rules set)))))

(defun parse-rule (line prefix)
  (let ((text (string-trim '(#\Space #\Tab #\Return) line)))
    (when (or (zerop (length text)) (a:starts-with #\# text))
      (return-from parse-rule nil))
    (let* ((negated (a:starts-with #\! text))
           (body (if negated (subseq text 1) text))
           (directory-only (a:ends-with #\/ body))
           (trimmed (string-right-trim "/" body))
           (anchored (find #\/ trimmed))
           (pattern (format nil "~a~a" prefix (string-left-trim "/" trimmed))))
      (when (plusp (length trimmed))
        (make-rule :scanner (compile-glob (if anchored pattern (format nil "**/~a" pattern)))
                   :negated-p negated
                   :directory-only-p directory-only)))))

(defun add-ignore-file (set text prefix)
  (add-patterns set (uiop:split-string text :separator (string #\Newline)) prefix))

(defun ignored-p (set path directory-p)
  "Is PATH -- relative to the traversal root -- excluded?
Later rules win, which is how a negation later in a .gitignore re-includes."
  (let ((verdict nil))
    (dolist (rule (reverse (ignore-set-rules set)) verdict)
      (when (and (or directory-p (not (rule-directory-only-p rule)))
                 (or (cl-ppcre:scan (rule-scanner rule) path)
                     (cl-ppcre:scan (rule-scanner rule) (format nil "~a/" path))))
        (setf verdict (not (rule-negated-p rule)))))))
