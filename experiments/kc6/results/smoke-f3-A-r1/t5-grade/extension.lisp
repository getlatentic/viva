(when (flag-enabled-p :audit)
  (register (make-tool :name "audit-log")))
(when (flag-enabled-p :trace)
  (register (make-tool :name "trace")))
