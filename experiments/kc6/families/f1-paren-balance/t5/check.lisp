(defun read-forms (path)
  (with-open-file (in path)
    (loop for form = (read in nil in) until (eq form in) collect form)))

(defun fail (why) (format t "FAIL: ~a~%" why) (sb-ext:exit :code 1))

(let* ((forms (handler-case (read-forms "gate.lisp")
                (error (c) (fail (format nil "gate.lisp does not read: ~a" c)))))
       (owner (find-if (lambda (f) (and (consp f) (eq (first f) 'define-owner)
                                        (eq (second f) 'gate)))
                       forms))
       (clauses (cddr owner)))
  (unless owner (fail "the define-owner gate form is gone"))
  (unless (= 5 (length clauses)) (fail (format nil "~d clauses, want 5" (length clauses))))
  (unless (equal (first clauses) '(:states (:closed) (:open ?count))) (fail ":states changed"))
  ;; The three existing transitions, byte-for-byte in structure. Expected
  ;; trees are READ here, so backquote compares as the same reader produced it.
  ;; PRIN1 both sides and compare strings: SBCL reads unquote as a COMMA
  ;; STRUCTURE, and EQUAL on two separately-read commas is identity, so a
  ;; tree comparison of backquoted clauses can never succeed. One printer,
  ;; one image, same text -- caught by this family's own authoring gate,
  ;; which is the friction the family exists to measure.
  (flet ((want (n text)
           (unless (string= (prin1-to-string (nth n clauses))
                            (prin1-to-string (read-from-string text)))
             (fail (format nil "clause ~d changed: ~s" n (nth n clauses))))))
    (want 1 "(:transition ((:closed) (:open-request)) => '(:open 1) (list :publish :gate.opened 1))")
    (want 2 "(:transition ((:open ?count) (:open-request)) => `(:open ,(1+ ?count)) (list :publish :gate.opened (1+ ?count)))")
    (want 3 "(:transition ((:open ?count) (:close)) :when (= ?count 1) => '(:closed) (list :publish :gate.closed))")
    (want 4 "(:transition ((:open ?count) (:close)) :when (> ?count 1) => `(:open ,(1- ?count)) (list :publish :gate.stepped (1- ?count)))")))
(format t "ok~%")
