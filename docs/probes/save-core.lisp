;;;; Build a saved core with genera-lab fully loaded, for trial-startup timing.
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(funcall (find-symbol "QUICKLOAD" "QL") :genera-lab :silent t)
(format t "~&loaded; threads=~d~%" (length (sb-thread:list-all-threads)))
(sb-ext:save-lisp-and-die
 (or (sb-posix:getenv "CORE_OUT") "/tmp/genera-lab.core")
 :executable nil
 :compression nil)
