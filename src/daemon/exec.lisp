;;;; Replacing this process's image with another program, in the same process.
;;;;
;;;; An exec keeps the pid, the children and every descriptor not marked
;;;; close-on-exec, and discards everything else: memory, threads, handlers.
;;;; That is the whole of an upgrade that restarts nothing -- the listening
;;;; socket, each client's connection and each background job's pipe survive
;;;; into the new image, which reads what it was handed and carries on.

(in-package #:viva.daemon)

(defconstant +fd-cloexec+ 1
  "FD_CLOEXEC, the same value on Darwin and Linux, and absent from SB-POSIX.")

(defparameter +descriptor-ceiling+ 65536
  "Descriptors scanned at most. A soft limit reported as unlimited would
otherwise make marking every descriptor a loop without end.")

(defun descriptor-limit ()
  (min +descriptor-ceiling+
       (sb-alien:alien-funcall
        (sb-alien:extern-alien "getdtablesize" (function sb-alien:int)))))

(defun close-on-exec (fd closes)
  "Mark FD to close on exec when CLOSES, and to survive it otherwise."
  (let ((flags (sb-posix:fcntl fd sb-posix:f-getfd)))
    (sb-posix:fcntl fd sb-posix:f-setfd
                    (if closes
                        (logior flags +fd-cloexec+)
                        (logandc2 flags +fd-cloexec+)))))

(defun keep-only-descriptors (keep)
  "Let exactly KEEP, and the standard three, survive the exec.

EVERY OTHER DESCRIPTOR CLOSES. The image being replaced holds transcripts,
journals, the core file and whatever a tool opened; a new image inheriting them
would hold descriptors nothing in it knows about, for as long as it runs."
  (loop for fd from 3 below (descriptor-limit)
        do (handler-case (close-on-exec fd (not (member fd keep)))
             ;; EBADF: not open, which is most of them.
             (sb-posix:syscall-error () nil))))

(defun unblock-all-signals ()
  "Clear this thread's signal mask. An exec keeps the mask, and SBCL runs with
signals blocked around its own critical sections; a new image born with them
blocked would miss its interrupts until something happened to unblock them."
  (let ((empty (sb-alien:make-alien (sb-alien:unsigned 8) 256)))
    (unwind-protect
         (progn
           ;; Larger than either platform's sigset_t: 4 bytes on Darwin, 128
           ;; with glibc.
           (dotimes (i 256) (setf (sb-alien:deref empty i) 0))
           (sb-alien:alien-funcall
            (sb-alien:extern-alien "pthread_sigmask"
                                   (function sb-alien:int sb-alien:int
                                             (* (sb-alien:unsigned 8))
                                             sb-alien:unsigned-long))
            ;; SIG_SETMASK.
            #+darwin 3 #-darwin 2
            empty 0))
      (sb-alien:free-alien empty))))

(defun replace-image (program arguments)
  "Exec PROGRAM with ARGUMENTS (ARGV[0] first) in this process. Returns only
when the exec failed, by signalling.

WITHOUT GC. A collection stops every thread with a signal, and a stop signal
pending at the exec would reach a new image that has no handler for it."
  (let* ((count (length arguments))
         (argv (sb-alien:make-alien sb-alien:c-string (1+ count))))
    (loop for argument in arguments
          for i from 0
          do (setf (sb-alien:deref argv i) argument))
    (setf (sb-alien:deref argv count) nil)
    (sb-sys:without-gcing
      (unblock-all-signals)
      (sb-alien:alien-funcall
       (sb-alien:extern-alien "execv" (function sb-alien:int sb-alien:c-string
                                                (* sb-alien:c-string)))
       program argv))
    (error 'daemon-error
           :detail (format nil "exec ~a failed: ~a" program
                           (sb-int:strerror (sb-alien:get-errno))))))
