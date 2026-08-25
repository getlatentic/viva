;;;; skillsmith -- let the agent write a skill, and use it in the same session.
;;;;
;;;; This is the smallest complete instance of the thing the project is about.
;;;; The agent notices that a piece of work has a procedure, writes the
;;;; procedure down as a skill, and the skill is in its own system prompt on the
;;;; very next request -- no restart, no human, no edit to the harness.
;;;;
;;;; Copy this file to .viva/extensions/ in a project you have trusted, or
;;;; to ~/.viva/extensions/ to have it everywhere.

(in-package #:viva.extension)

(defun skillsmith-directory ()
  (env:project-path (env:env-cwd (viva.workspace:environment)) "skills"))

(defun skillsmith-valid-name-p (name)
  (and (plusp (length name))
       (every (lambda (character)
                (or (char<= #\a character #\z) (char<= #\0 character #\9) (char= #\- character)))
              name)
       (not (a:starts-with #\- name))
       (not (a:ends-with #\- name))))

(tool:define-tool skillsmith-write (args context)
  :name "write_skill"
  :description "Write down a reusable procedure as a skill, so you are reminded
of it whenever a matching task comes up -- in this session and in every future
one.

Use it when you have worked out HOW to do something in this project that you
would otherwise work out again: a build-and-verify sequence, the steps a
migration needs, what to check before claiming a fix works. The description is
what you will see next time when deciding whether to open it, so write it as the
situation it applies to, not as a title."
  :parameters (("name" :string "Lowercase letters, digits and hyphens, e.g. \"run-the-tests\"" :required-p t)
               ("description" :string "When to use this skill. One or two sentences." :required-p t)
               ("content" :string "The procedure itself, in Markdown." :required-p t))
  (let ((name (string-downcase (string-trim '(#\Space) (gethash "name" args)))))
    (unless (skillsmith-valid-name-p name)
      (return-from skillsmith-write
        (tool:make-tool-result
         :output (format nil "~s is not a usable skill name. Use lowercase ~
letters, digits and hyphens, e.g. \"run-the-tests\"." name)
         :error-p t)))
    (let ((path (env:join-path (skillsmith-directory) name "SKILL.md")))
      (env:write-text (viva.workspace:environment) path
                      (format nil "---~%name: ~a~%description: ~a~%---~%~%~a~%"
                              name (gethash "description" args) (gethash "content" args)))
      ;; Reloading here is the whole point: the skill has to be usable now, not
      ;; after a restart. A skill that only takes effect next process is a note
      ;; to a future agent, which is a weaker claim than the one being tested.
      (a:when-let ((agent viva.harness:*agent*))
        (viva.harness:refresh-resources agent))
      (format nil "Wrote the skill ~a to ~a. It is available from your next ~
request onward; invoke it by reading that file when the situation matches."
              name path))))

(defextension "skillsmith"
  :description "Lets the agent write skills that take effect immediately."
  (register-tool skillsmith-write)
  (register-command "skills-dir"
                    :description "Where skills written in this project land."
                    :handler (lambda (agent argument)
                               (declare (ignore agent argument))
                               (skillsmith-directory))))
