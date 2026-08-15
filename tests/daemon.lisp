;;;; The organism's front door.
;;;;
;;;; These encode a bug that shipped and very nearly hid. `vivarium daemon
;;;; status` opened three connections for one answer, two of them dropped the
;;;; instant they were made, and four invocations killed the daemon outright.
;;;; The cause was one line: LOOP's iteration variable is a single binding
;;;; updated in place, so the closure handed to each client thread read whatever
;;;; the *next* accept had put there. Two threads then built streams from one
;;;; socket -- SBCL hands back the same stream -- and wrote interleaved JSON
;;;; onto one descriptor while the first to finish closed it under the other.
;;;;
;;;; That produced two symptoms which looked unrelated: a greeting the client
;;;; could not parse, and `Bad file descriptor`, which under `sbcl --script`
;;;; quits the whole process. A daemon whose entire premise is outliving its
;;;; clients was being killed by them.
;;;;
;;;; So these tests drive real sockets rather than mocks. The defect lived
;;;; precisely in the arrangement of threads and descriptors, and nothing that
;;;; stands in for those would have shown it.

(in-package #:vivarium.tests)

(defun daemon-test-path ()
  (format nil "/tmp/vivarium-daemond-~36r.sock" (random (expt 2 48) (make-random-state t))))

(defmacro with-daemon ((path) &body body)
  "A daemon of our own, on its own socket, stopped afterwards whatever happens."
  `(let ((,path (daemon-test-path)))
     (unwind-protect
          (progn (daemon:serve :path ,path :background t)
                 (loop repeat 100 until (daemon:running-p ,path) do (sleep 0.01))
                 ,@body)
       (daemon:stop))))

(defun daemon-greeting (path)
  "Connect, read the greeting, and return the pid in it -- or why there was none.

A symbol rather than a signalled error, so a thread can report what happened to
it instead of dying with the answer."
  (handler-case
      (let ((stream (daemon:connect path)))
        (unwind-protect
             (let ((line (read-line stream nil nil)))
               (cond ((null line) :no-greeting)
                     (t (handler-case (gethash "pid" (com.inuoe.jzon:parse line))
                          (error () :unparseable)))))
          (ignore-errors (close stream))))
    (error () :refused)))

(defun daemon-drop (path)
  "Connect and hang up at once: what a liveness probe does, and the exact
traffic that put two client threads on one descriptor."
  (handler-case (close (daemon:connect path)) (error () nil))
  t)

(defun daemon-ask (path &rest plist)
  (daemon:with-connection (stream path)
    (read-line stream nil nil)
    (apply #'daemon:request stream plist)))

(define-test "clients arriving and leaving at once each get their own connection"
  (with-daemon (path)
    (let ((greetings '())
          (lock (bt:make-lock "daemon-test")))
      (mapc #'bt:join-thread
            (loop for index below 24
                  collect (bt:make-thread
                           ;; INDEX is bound afresh here on purpose. Closing over
                           ;; the loop variable directly is the bug under test.
                           (let ((mine index))
                             (lambda ()
                               (if (oddp mine)
                                   (daemon-drop path)
                                   (let ((got (daemon-greeting path)))
                                     (bt:with-lock-held (lock) (push got greetings)))))))))
      (is = 12 (length greetings))
      (true (every #'integerp greetings)
            "every greeting parsed, got ~a" (remove-if #'integerp greetings))
      ;; And the listener is still there. Leaving the accept loop on one refused
      ;; connection unwinds into STOP, which leaves a process alive and
      ;; unreachable -- the worst of both.
      (true (integerp (daemon-greeting path))))))

(define-test "a client that hangs up mid-request does not take the daemon with it"
  (with-daemon (path)
    (dotimes (i 8)
      (handler-case
          (let ((stream (daemon:connect path)))
            (write-string "{\"id\":\"x\",\"type\":\"pi" stream)
            (force-output stream)
            (close stream))
        (error () nil)))
    (let ((reply (daemon-ask path "type" "ping")))
      (true (gethash "success" reply)))))

(define-test "unparseable input is answered rather than fatal"
  (with-daemon (path)
    (daemon:with-connection (stream path)
      (read-line stream nil nil)
      (write-line "not json at all" stream)
      (force-output stream)
      (let ((reply (com.inuoe.jzon:parse (read-line stream))))
        (false (gethash "success" reply))
        (true (gethash "error" reply))))
    (true (gethash "success" (daemon-ask path "type" "ping")))))

(define-test "a live daemon's socket survives being asked whether it is alive"
  (with-daemon (path)
    ;; RUNNING-P deleted the file whenever a connection failed for any reason,
    ;; on the theory that only a stale file can refuse. A busy one refuses too.
    (dotimes (i 20) (daemon:running-p path))
    (true (probe-file path))
    (true (daemon:running-p path))))

(define-test "stopping unlinks the socket it bound, not the default one"
  ;; STOP deleted (SOCKET-PATH) whatever it had actually been told to listen on,
  ;; so a daemon on a second socket deleted the first one's file on its way out
  ;; and left its own behind. VIVARIUM_SOCKET is what SOCKET-PATH reads, which
  ;; makes the wrong file nameable from here.
  (let ((decoy (daemon-test-path))
        (before (sb-posix:getenv "VIVARIUM_SOCKET")))
    (unwind-protect
         (progn
           (with-open-file (out decoy :direction :output :if-does-not-exist :create))
           (sb-posix:setenv "VIVARIUM_SOCKET" decoy 1)
           (with-daemon (path)
             (true (probe-file path))
             (daemon:stop)
             (false (probe-file path)))
           (true (probe-file decoy)))
      (if before
          (sb-posix:setenv "VIVARIUM_SOCKET" before 1)
          (sb-posix:unsetenv "VIVARIUM_SOCKET"))
      (ignore-errors (delete-file decoy)))))
