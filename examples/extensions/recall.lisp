;;;; recall -- make memory worth having.
;;;;
;;;; MEMORY.md is loaded whole into every system prompt, which works until it is
;;;; four hundred lines long and most of it has nothing to do with the question
;;;; being asked. This extension changes the retrieval rather than the storage:
;;;; before each request it scores the remembered lines against the words in the
;;;; prompt and injects the few that match, and it registers a tool for asking
;;;; deliberately.
;;;;
;;;; It is here because "an extension that improves memory" should be a file
;;;; someone writes, not a change to the harness. If this needed the harness to
;;;; move, the extension API would be the wrong shape.

(in-package #:vivarium.extension)

(defparameter +recall-limit+ 5)

(defparameter +recall-stopwords+
  '("the" "a" "an" "and" "or" "but" "for" "with" "that" "this" "what" "why" "how"
    "when" "where" "which" "who" "does" "did" "was" "are" "is" "it" "of" "to" "in"
    "on" "at" "by" "from" "as" "be" "can" "you" "i" "we" "my" "me" "not" "do")
  "Dropped before scoring. Without them every line matches every question,
because every line contains `the`.")

(defun recall-words (text)
  (remove-if (lambda (word)
               (or (< (length word) 3) (member word +recall-stopwords+ :test #'string=)))
             (uiop:split-string (string-downcase (substitute-if
                                                  #\Space
                                                  (lambda (character)
                                                    (not (or (alphanumericp character)
                                                             (find character "-_./"))))
                                                  text))
                                :separator " ")))

(defun recall-lines ()
  (remove-if (lambda (line) (< (length (string-trim '(#\Space #\-) line)) 8))
             (uiop:split-string (vivarium.memory:read-memory (vivarium.workspace:environment))
                                :separator (string #\Newline))))

(defun recall-score (line words)
  (let ((haystack (string-downcase line)))
    (count-if (lambda (word) (search word haystack)) words)))

(defun recall-matching (query &key (limit +recall-limit+))
  "Remembered lines that share vocabulary with QUERY, best first."
  (let ((words (remove-duplicates (recall-words query) :test #'string=)))
    (when words
      (let ((scored (remove-if (lambda (pair) (zerop (car pair)))
                               (mapcar (lambda (line) (cons (recall-score line words) line))
                                       (recall-lines)))))
        (mapcar #'cdr (subseq (sort scored #'> :key #'car)
                              0 (min limit (length scored))))))))

(tool:define-tool recall-search (args context)
  :name "recall"
  :description "Search what you have written down about this project for
anything bearing on a topic. Useful when you suspect you have been here before
and the relevant note is not in front of you."
  :parameters (("topic" :string "What you are trying to remember about" :required-p t))
  (a:if-let ((found (recall-matching (gethash "topic" args) :limit 10)))
    (format nil "~{~a~%~}" found)
    (format nil "Nothing remembered about ~a." (gethash "topic" args))))

(defun recall-inject (message)
  "Prepend the relevant notes to the user's message, as context rather than
instruction. Returns NIL when nothing matches, which leaves the message alone."
  (let ((text (vivarium.message:text-of message)))
    (a:when-let ((found (recall-matching text)))
      (vivarium.message:make-user-message
       :content (list (vivarium.message:make-text
                       (format nil "<recalled>~%You have worked here before and noted:~%~{~a~%~}</recalled>~%~%~a"
                               found text)))))))

(defextension "recall"
  :description "Injects relevant past notes before each request, and searches them on demand."
  (register-tool recall-search)
  (on :before-request #'recall-inject))
