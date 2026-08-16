;;;; Loaded by the instrumented constructor; registers conditionally.
(when (flag-enabled-p :metrics)
  (register (make-tool :name "metrics")))
(when (flag-enabled-p :trace)
  (register (make-tool :name "trace")))
(when (flag-enabled-p :color)
  (register (make-tool :name "color-log")))
