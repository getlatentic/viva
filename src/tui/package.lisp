(defpackage #:vivarium.tui
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria))
  (:export #:supported-p #:with-kitty-keyboard
           #:*query* #:*push-flags* #:*pop-flags* #:*reply-timeout*
           #:decode #:describe-key #:read-key #:*sequence-timeout*
           #:with-raw-terminal #:terminal-p
           #:make-blank-screen #:put #:flush #:clear-back
           #:screen #:screen-width #:screen-height
           #:key #:key-value #:key-control #:key-alt #:key-shift))
