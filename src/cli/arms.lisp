;;;; Which model an arm reaches, and how.
;;;;
;;;; One place, because every experiment needs the same three lines and each
;;;; copy is another thing to update when an endpoint or a model id moves. An
;;;; arm whose credentials are absent is simply not offered -- a missing key
;;;; should be a missing column, never a row of zeros that reads as a model
;;;; failing the task.

(in-package #:viva.cli)

(defstruct (arm (:conc-name arm-))
  (label "" :type string)
  (provider nil)
  (model "" :type string)
  (effort nil))

(defun env (name)
  (let ((value (sb-posix:getenv name)))
    (and value (plusp (length value)) value)))

(defun listening-p (endpoint)
  "Is anything answering at ENDPOINT? Cheap TCP connect, no request."
  (when endpoint
    (let* ((after (search "//" endpoint))
           (rest (subseq endpoint (+ after 2)))
           (host-port (subseq rest 0 (position #\/ rest)))
           (colon (position #\: host-port)))
      (ignore-errors
       (let ((socket (usocket:socket-connect (subseq host-port 0 colon)
                                             (parse-integer (subseq host-port (1+ colon)))
                                             :timeout 1)))
         (usocket:socket-close socket)
         t)))))

(defparameter +arm-labels+
  '(("openrouter" . "gpt-oss-120b") ("deepseek" . "deepseek-flash"))
  "Experiment-facing names for catalogue entries. The results files and the
write-ups already say `gpt-oss-120b`, and renaming a column silently is how two
sweeps stop being comparable.")

(defun arm-for (choice)
  (make-arm :label (or (cdr (assoc (models:choice-label choice) +arm-labels+ :test #'string=))
                       (models:choice-label choice))
            :provider (models:choice-provider choice)
            :model (models:choice-model choice)
            :effort (models:choice-effort choice)))

(defun available-arms ()
  "The catalogue, minus a local server that is configured but not answering.

Endpoints and keys live in VIVA.MODELS so the shell, the IPC server and a
scored sweep cannot drift apart on which endpoint `deepseek` means. The liveness
probe stays here: a configured endpoint with nothing behind it produced a whole
column of `err` in one sweep, which costs an attempt per cell and reads like a
model failing rather than a missing one."
  (remove nil (mapcar (lambda (choice)
                        (if (and (string= "local" (models:choice-label choice))
                                 (not (listening-p (env "VIVA_LOCAL_ENDPOINT"))))
                            nil
                            (arm-for choice)))
                      (models:available-models))))

(defun arms-named (names)
  "NAMES is NIL for every available arm, or a list of labels."
  (let ((available (available-arms)))
    (if (null names)
        available
        (mapcar (lambda (name)
                  (or (find name available :key #'arm-label :test #'string-equal)
                      (error "No arm called ~s. Available: ~{~a~^, ~}"
                             name (mapcar #'arm-label available))))
                names))))
