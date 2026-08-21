(defpackage #:vivarium.tui
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria))
  (:export #:supported-p #:with-kitty-keyboard
           #:*query* #:*push-flags* #:*pop-flags* #:*reply-timeout*
           #:decode #:describe-key #:read-key #:*sequence-timeout*
           #:with-raw-terminal #:terminal-p
           #:make-blank-screen #:screen-rows #:put #:flush #:clear-back
           #:screen #:screen-width #:screen-height
           #:paint #:layout-for #:wrap #:cursor-for #:visible-rows
           #:view #:make-view #:absorb #:type-key #:take-input
           #:view-lines #:view-partial #:view-input #:view-status #:view-busy
           #:view-sessions #:view-current #:view-tasks #:view-scroll
           #:terminal-size #:with-resize-notice #:take-resize #:*fallback-size*
           #:divide #:region-of #:draw-in #:region
           #:region-row #:region-column #:region-width #:region-height
           #:key #:key-value #:key-control #:key-alt #:key-shift))
