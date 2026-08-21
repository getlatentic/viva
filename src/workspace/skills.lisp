;;;; Skills: instructions that live on disk and load themselves when relevant.
;;;;
;;;; A skill is the cheapest durable improvement there is -- a file the agent
;;;; can write during one task and be reminded of during the next -- which is
;;;; why Level 1 has to carry them before Level 3 can claim anything about
;;;; retention.
;;;;
;;;; Only the NAME, DESCRIPTION and LOCATION enter the system prompt. The body
;;;; is read with the READ tool when the model decides the description matches,
;;;; so a directory of forty skills costs forty lines of context rather than
;;;; forty files of it.

(in-package #:vivarium.skill)

(defstruct (skill (:conc-name skill-))
  (name "" :type string)
  (description "" :type string)
  (content "" :type string)
  (path "" :type string)
  (hidden-p nil :type boolean))

(defstruct (skill-warning (:conc-name warning-))
  (message "" :type string)
  (path "" :type string))

;;; Frontmatter
;;;
;;; A deliberate subset of YAML: `key: value` on one line, optionally quoted.
;;; SKILL.md defines exactly three keys and none of them is a list or a nested
;;; map, so a YAML dependency would buy nothing and cost a parser whose failure
;;; modes nobody here would know.

(defun strip-quotes (text)
  (let ((trimmed (string-trim '(#\Space #\Tab) text)))
    (if (and (> (length trimmed) 1)
             (member (char trimmed 0) '(#\" #\'))
             (char= (char trimmed 0) (char trimmed (1- (length trimmed)))))
        (subseq trimmed 1 (1- (length trimmed)))
        trimmed)))

(defun parse-frontmatter (text)
  "Returns (values ALIST BODY). Text without a leading `---` is all body."
  (let ((lines (uiop:split-string (remove #\Return text) :separator (string #\Newline))))
    (if (not (string= "---" (string-trim '(#\Space) (or (first lines) ""))))
        (values '() text)
        (let ((end (position "---" (rest lines) :test #'string= :key (lambda (line) (string-trim '(#\Space) line)))))
          (if (null end)
              (values '() text)
              (values (loop for line in (subseq (rest lines) 0 end)
                            for colon = (position #\: line)
                            when colon
                              collect (cons (string-trim '(#\Space #\Tab) (subseq line 0 colon))
                                            (strip-quotes (subseq line (1+ colon)))))
                      (format nil "~{~a~^~%~}" (nthcdr (+ end 2) lines))))))))

(defun field (alist key)
  (cdr (assoc key alist :test #'string-equal)))

(defun read-skill (environment path parent-name warnings)
  (let ((text (ignore-errors (env:read-text environment path))))
    (cond ((null text)
           (push (make-skill-warning :message "could not be read" :path path) (cdr warnings))
           nil)
          (t
           (multiple-value-bind (frontmatter body) (parse-frontmatter text)
             (let ((description (field frontmatter "description"))
                   (name (or (field frontmatter "name") parent-name)))
               (cond ((or (null description) (zerop (length (string-trim '(#\Space) description))))
                      ;; Silently skipping is worse than it sounds: the file is
                      ;; sitting in a skills directory, so someone meant it to
                      ;; be one, and the reason it is invisible has to be said.
                      (push (make-skill-warning :message "has no description, so it was not loaded"
                                                :path path)
                            (cdr warnings))
                      nil)
                     (t (make-skill :name name :description description
                                    :content body :path path
                                    :hidden-p (string-equal "true" (or (field frontmatter "disable-model-invocation") "")))))))))))

(defun load-skills (environment directories)
  "Load every SKILL.md under DIRECTORIES. Returns (values SKILLS WARNINGS).

A directory containing SKILL.md is one skill and is not descended into; anything
else is descended into looking for more. Loose `.md` files directly in a root
directory are skills too, which is what makes a single flat folder work."
  (let ((skills '()) (warnings (list :warnings)))
    (labels ((skill-file (directory)
               (let ((candidate (env:join-path directory "SKILL.md")))
                 (and (env:path-exists-p environment candidate) candidate)))
             (descend (directory root-p)
               (a:if-let ((file (skill-file directory)))
                 (a:when-let ((skill (read-skill environment file (env:base-name directory) warnings)))
                   (push skill skills))
                 (dolist (info (sort (or (ignore-errors (env:list-directory environment directory)) '())
                                     #'string< :key #'env:info-name))
                   (let ((name (env:info-name info)))
                     (cond ((a:starts-with #\. name))
                           ((eq :directory (env:info-kind info)) (descend (env:info-path info) nil))
                           ((and root-p (a:ends-with-subseq ".md" name))
                            (a:when-let ((skill (read-skill environment (env:info-path info)
                                                            (pathname-name name) warnings)))
                              (push skill skills)))))))))
      (dolist (directory (a:ensure-list directories))
        (when (env:path-exists-p environment directory)
          (descend (env:absolute-path environment directory) t))))
    (values (sort skills #'string< :key #'skill-name) (rest warnings))))

(defun find-skill (skills name)
  (find name skills :key #'skill-name :test #'string-equal))

;;; What the model sees

(defun escape-xml (text)
  (with-output-to-string (out)
    (loop for character across text
          do (case character
               (#\& (write-string "&amp;" out))
               (#\< (write-string "&lt;" out))
               (#\> (write-string "&gt;" out))
               (t (write-char character out))))))

(defun prompt-block (skills)
  "The skills section of the system prompt, or \"\" when there is nothing to say."
  (let ((visible (remove-if #'skill-hidden-p skills)))
    (if (null visible)
        ""
        (with-output-to-string (out)
          (format out "These skills hold detailed instructions for particular kinds of ~
work. When a task matches one, read the whole file at its location before ~
starting. Paths inside a skill are relative to the directory the skill lives in.~%~%")
          (format out "<available_skills>~%")
          (dolist (skill visible)
            (format out "  <skill>~%    <name>~a</name>~%    <description>~a</description>~%    <location>~a</location>~%  </skill>~%"
                    (escape-xml (skill-name skill))
                    (escape-xml (skill-description skill))
                    (escape-xml (skill-path skill))))
          (format out "</available_skills>")))))

(defun invocation (skill &optional instructions)
  "The message that runs SKILL explicitly, with its body already inlined."
  (format nil "<skill name=\"~a\" location=\"~a\">~%Paths inside are relative to ~a.~%~%~a~%</skill>~@[~%~%~a~]"
          (skill-name skill) (skill-path skill)
          (env:parent-path (skill-path skill))
          (skill-content skill)
          instructions))

;;; Running a tier-2 skill, and counting the runs
;;;
;;; The reuse signal (docs/tier-2-reuse-signal.md). A skill is injected into the
;;; prompt and read, so there is no use event to count -- and without a count,
;;; graduation has nothing to threshold on and tier 3 is unreachable, which
;;; three runs of experiments/tier3 demonstrated.
;;;
;;; So the snippet a tier-2 skill already carries gains an ENTRY POINT. Not a
;;; new kind of artifact: our format already demands one fenced block that runs,
;;; and Codex lays its skills out with `scripts/<tool>.* # executed, not loaded`.
;;; The file stays a file -- readable, editable, committable. It gains a way to
;;; be called, and calling it is the fact the router wanted.

(defparameter +interpreters+
  '(("python" . "python3") ("python3" . "python3") ("bash" . "bash")
    ("sh" . "sh") ("node" . "node") ("ruby" . "ruby"))
  "Languages a skill may declare, and what runs them. A language not here is
refused by name rather than guessed at -- running somebody's code through the
wrong interpreter is a worse answer than saying no.")

(defun snippet-of (skill)
  "The first fenced block in SKILL's body, or NIL.

The FIRST, because the format asks for one. A skill carrying three blocks has
not said which is the procedure, and picking one for it would be a guess that
looks like a feature."
  (let* ((lines (uiop:split-string (skill-content skill) :separator '(#\Newline)))
         (start (position-if (lambda (line) (a:starts-with-subseq "```" (string-left-trim " " line)))
                             lines)))
    (when start
      (let ((end (position-if (lambda (line) (a:starts-with-subseq "```" (string-left-trim " " line)))
                              lines :start (1+ start))))
        (when end
          (format nil "~{~a~^~%~}" (subseq lines (1+ start) end)))))))

(defun uses-path (skill)
  (env:join-path (env:parent-path (skill-path skill)) "uses"))

(defun uses-of (environment skill)
  "How many times this skill has been run. The number graduation thresholds on."
  (or (ignore-errors
       (parse-integer (env:read-text environment (uses-path skill)) :junk-allowed t))
      0))

(defun note-use (environment skill)
  (let ((next (1+ (uses-of environment skill))))
    (ignore-errors (env:write-text environment (uses-path skill) (format nil "~d~%" next)))
    next))
