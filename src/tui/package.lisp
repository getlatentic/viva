(defpackage #:vivarium.tui
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria))
  (:export #:supported-p #:with-kitty-keyboard
           #:*query* #:*push-flags* #:*pop-flags* #:*reply-timeout*
           #:decode #:describe-key #:read-key #:*sequence-timeout*
           #:with-raw-terminal #:terminal-p
           #:make-blank-screen #:put #:flush #:clear-back
           #:screen #:screen-width #:screen-height
           #:terminal-size #:with-resize-notice #:take-resize #:*fallback-size*
           #:divide #:region-of #:draw-in #:region
           #:region-row #:region-column #:region-width #:region-height
           #:key #:key-value #:key-control #:key-alt #:key-shift))
