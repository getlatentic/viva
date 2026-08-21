;;;; What has accumulated for a directory: notes, skills, tools.
;;;;
;;;; A pure function of a working directory, touching no live agent. That is
;;;; not a convenience, it is the architecture: KC6 killed retention that lived
;;;; inside the process, and what replaced it is files. So "what does this
;;;; project's agent know" is answered by reading the same folders any other
;;;; agent -- or any person with `ls` -- would read.
;;;;
;;;; It has to be an agent-free reading for a second reason. The daemon's
;;;; sessions hold a live agent owned by a worker thread, and reading that
;;;; agent's slots from a client thread is the exact ownership violation
;;;; ACTOR:SNAPSHOT exists to prevent. Answering from disk means an attached
;;;; session can be asked what it knows WHILE it is working, rather than
;;;; queueing behind a turn that may run for minutes.
;;;;
;;;; Two scopes, and they are kept apart on purpose. ~/.vivarium is the
;;;; machine's, carried into every project; .vivarium/ is this project's. A
;;;; reader who cannot tell which is which cannot tell what travels.

(in-package #:vivarium.germline)

(defstruct (item (:conc-name item-))
  (name "" :type string)
  (detail "" :type string)
  (scope :project :type keyword)
  (path "" :type string))

(defstruct (view (:conc-name view-))
  (cwd "" :type string)
  (notes '() :type list)
  (skills '() :type list)
  (tools '() :type list)
  ;; Tools that exist here and will not run: on disk, refused at load.
  (refused '() :type list)
  ;; The fourth shape: something that should be RUNNING while work happens
  ;; here, as opposed to knowledge, a transformation, or a callable.
  (services '() :type list)
  (warnings '() :type list)
  (trusted-p nil))

(defun scope-of (environment path)
  "Whose is this -- the machine's, or this project's?"
  (if (trust:within-p (trust:canonical environment (trust:home-directory))
                      (trust:canonical environment path))
      :machine
      :project))

(defun note-lines (text)
  "The notes in a memory file: its bullet lines, headings dropped.

The heading is furniture the file is born with; a memory holding only that has
nothing in it, and reporting it as one note would make an empty germline look
populated."
  (remove-if-not (lambda (line) (a:starts-with-subseq "- " line))
                 (mapcar (lambda (line) (string-trim " " line))
                         (uiop:split-string (or text "") :separator '(#\Newline)))))

(defun memory-files (environment)
  "The two files the agent writes into: the machine's and this project's.

Deliberately NOT MEMORY:CONTEXT-FILES, which also gathers the instruction files
a PERSON wrote in this directory and its ancestors. Those matter to a run and
are not what the organism retained, and showing them here would credit the
agent with everything it was told."
  (list (env:join-path (uiop:native-namestring (user-homedir-pathname))
                       ".vivarium" "MEMORY.md")
        (env:join-path (env:env-cwd environment) memory:*memory-file*)))

(defun notes-for (environment)
  (loop for path in (memory-files environment)
        when (env:path-exists-p environment path)
          append (loop for line in (note-lines (ignore-errors (env:read-text environment path)))
                       collect (make-item :name (subseq line 2)
                                          :scope (scope-of environment path)
                                          :path path))))

(defun skills-for (environment)
  (multiple-value-bind (skills warnings)
      (skill:load-skills environment (harness:skill-directories environment))
    (values (mapcar (lambda (each)
                      (make-item :name (skill:skill-name each)
                                 :detail (skill:skill-description each)
                                 ;; A skill knows the file it came from, which
                                 ;; is what decides whose it is.
                                 :scope (scope-of environment (skill:skill-path each))
                                 :path (skill:skill-path each)))
                    skills)
            (mapcar #'princ-to-string warnings))))

(defun manifests-on-disk (environment directory)
  "Tool directories present under DIRECTORY, whatever trust says about them.

Needed because LOAD-ENTRIES returns nothing for an untrusted project, which
makes `there are no tools here` and `there are tools and they are refused`
produce identical output. Those are opposite situations: one is an empty
germline, the other is a germline the agent cannot reach."
  (loop for info in (or (ignore-errors (env:list-directory environment directory)) '())
        when (and (eq :directory (env:info-kind info))
                  (env:path-exists-p environment
                                     (env:join-path (env:info-path info) "tool.json")))
          collect (make-item :name (env:info-name info)
                             :scope (scope-of environment (env:info-path info))
                             :path (env:info-path info))))

(defun tools-for (environment project)
  "Returns (values LOADED REFUSED WARNINGS)."
  (multiple-value-bind (entries warnings)
      (registry:load-entries environment (harness:registry-directories environment)
                             :project project)
    (let* ((loaded (mapcar (lambda (each)
                             (make-item :name (registry:entry-name each)
                                        :detail (registry:entry-description each)
                                        :scope (scope-of environment (registry:entry-directory each))
                                        :path (registry:entry-directory each)))
                           entries))
           (refused (remove-if (lambda (item)
                                 (find (item-name item) loaded
                                       :key #'item-name :test #'string=))
                               (loop for directory in (harness:registry-directories environment)
                                     append (manifests-on-disk environment directory)))))
      (values loaded refused warnings))))

(defun services-for (environment cwd)
  (loop for (name . command) in (jobs:declared environment cwd)
        collect (make-item :name name :detail command :scope :project
                           :path (env:join-path (jobs:services-directory cwd) name))))

(defun inspect-directory (cwd)
  "Everything that has accumulated for CWD. No model request, no live agent."
  (let* ((environment (env:make-local-environment :cwd cwd))
         (project (trust:canonical environment cwd)))
    (multiple-value-bind (skills skill-warnings) (skills-for environment)
      (multiple-value-bind (tools refused tool-warnings) (tools-for environment project)
        (make-view :cwd cwd
                   :notes (notes-for environment)
                   :skills skills
                   :tools tools
                   :refused refused
                   :services (services-for environment cwd)
                   :warnings (append skill-warnings tool-warnings)
                   :trusted-p (trust:trusted-p environment project))))))
