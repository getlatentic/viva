;;;; Prompt templates: a phrasing worth keeping, kept.
;;;;
;;;; A file under .viva/prompts/ becomes a command. `/review src/parser.lisp`
;;;; runs prompts/review.md with the path substituted, and the model sees an
;;;; ordinary user message -- there is no template at the provider boundary,
;;;; only expanded text.
;;;;
;;;; Small, and worth having for a reason beyond convenience. This project's
;;;; question is whether an agent can retain something that makes later work go
;;;; better, and the surfaces for that were a helper function, a tool, a skill
;;;; and a memory note. A template is a fifth, and the cheapest: it is the
;;;; sentence you found yourself typing three times, written down once.
;;;;
;;;; Distinct from a SKILL, which is instructions the model chooses to read when
;;;; a description matches. A template is invoked by a person, by name, and its
;;;; content is the prompt rather than a reference the model may follow.

(in-package #:viva.template)

(defstruct (template (:conc-name template-))
  (name "" :type string)
  (description "" :type string)
  (content "" :type string)
  (path "" :type string))

(defun load-templates (environment directories)
  "Every .md under DIRECTORIES, named after its file.

Flat on purpose: a template is one file and a directory of them is the whole
feature. Skills earn their nesting by carrying references alongside SKILL.md;
these carry nothing."
  (let ((templates '()))
    (dolist (directory (a:ensure-list directories) (sort templates #'string< :key #'template-name))
      (when (env:path-exists-p environment directory)
        (dolist (info (or (ignore-errors (env:list-directory environment directory)) '()))
          (let ((name (env:info-name info)))
            (when (and (a:ends-with-subseq ".md" name) (not (a:starts-with #\. name)))
              (a:when-let ((text (ignore-errors (env:read-text environment (env:info-path info)))))
                (multiple-value-bind (frontmatter body) (skill:parse-frontmatter text)
                  (push (make-template
                         :name (string-downcase (subseq name 0 (- (length name) 3)))
                         :description (or (cdr (assoc "description" frontmatter :test #'string-equal))
                                          "")
                         :content body
                         :path (env:info-path info))
                        templates))))))))))

(defun find-template (templates name)
  (find name templates :key #'template-name :test #'string-equal))

;;; Expansion

(defun split-arguments (text)
  (remove "" (uiop:split-string (string-trim '(#\Space #\Tab) (or text ""))
                                :separator " ")
          :test #'string=))

(defun expand (template arguments)
  "Substitute $1..$9 and $ARGUMENTS into the template's body.

A template that names no placeholder still gets the arguments, appended -- the
common case is a fixed instruction plus a path, and requiring a placeholder for
that would make the simplest template the fiddliest to write."
  (let* ((text (template-content template))
         (words (split-arguments arguments))
         (whole (format nil "~{~a~^ ~}" words))
         (used nil))
    (flet ((substitute-into (body)
             (let ((result body))
               (when (search "$ARGUMENTS" result)
                 (setf used t result (replace-all result "$ARGUMENTS" whole)))
               (loop for index from 1 to 9
                     for marker = (format nil "$~d" index)
                     when (search marker result)
                       do (setf used t
                                result (replace-all result marker
                                                    (or (nth (1- index) words) ""))))
               result)))
      (let ((expanded (substitute-into text)))
        (if (or used (zerop (length whole)))
            expanded
            (format nil "~a~%~%~a" expanded whole))))))

(defun replace-all (text needle replacement)
  (with-output-to-string (out)
    (loop with start = 0
          for found = (search needle text :start2 start)
          while found
          do (write-string text out :start start :end found)
             (write-string replacement out)
             (setf start (+ found (length needle)))
          finally (write-string text out :start start))))
