(defpackage #:vivarium.tui
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria))
  (:export #:supported-p #:with-kitty-keyboard
           #:*query* #:*push-flags* #:*pop-flags* #:*reply-timeout*
           #:decode #:describe-key #:read-key #:*sequence-timeout*
           #:key #:key-value #:key-control #:key-alt #:key-shift))
