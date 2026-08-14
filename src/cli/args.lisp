;;;; Flag parsing, deliberately boring.
;;;;
;;;; Long flags only, `--name value` or `--name=value`, plus bare positionals.
;;;; No abbreviations and no clustering: a research run is reproduced from its
;;;; command line months later, and a clever parser makes that harder to read.

(in-package #:vivarium.cli)

(defstruct (arguments (:conc-name args-))
  (positional '() :type list)
  (flags (make-hash-table :test #'equal) :type hash-table))

(defun flag-name (token)
  (let* ((body (subseq token 2))
         (equals (position #\= body)))
    (if equals
        (values (subseq body 0 equals) (subseq body (1+ equals)))
        (values body nil))))

(defun parse-arguments (tokens)
  (let ((parsed (make-arguments)))
    (loop while tokens
          for token = (pop tokens)
          do (if (a:starts-with-subseq "--" token)
                 (multiple-value-bind (name inline) (flag-name token)
                   (setf (gethash name (args-flags parsed))
                         (or inline
                             ;; A flag whose next token is another flag is a
                             ;; switch, not a missing value.
                             (if (and tokens (not (a:starts-with-subseq "--" (first tokens))))
                                 (pop tokens)
                                 "true"))))
                 (push token (args-positional parsed))))
    (setf (args-positional parsed) (nreverse (args-positional parsed)))
    parsed))

(defun flag (parsed name &optional default)
  (or (gethash name (args-flags parsed)) default))

(defun flag-integer (parsed name default)
  (let ((raw (flag parsed name)))
    (if raw
        (or (parse-integer raw :junk-allowed t)
            (error "--~a wants a number, got ~s" name raw))
        default)))

(defun flag-list (parsed name)
  "Comma-separated, empty means unset rather than one empty string."
  (let ((raw (flag parsed name)))
    (when (and raw (plusp (length raw)))
      (loop for start = 0 then (1+ comma)
            for comma = (position #\, raw :start start)
            collect (string-trim " " (subseq raw start comma))
            while comma))))
