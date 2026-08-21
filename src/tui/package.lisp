(defpackage #:vivarium.tui
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria))
  (:export #:supported-p #:with-kitty-keyboard
           #:*query* #:*push-flags* #:*pop-flags* #:*reply-timeout*
           #:mouse #:mouse-p #:mouse-action #:mouse-button #:mouse-row #:mouse-column
           #:mouse-control #:mouse-alt #:mouse-shift #:decode-mouse
           #:with-mouse-reporting #:*enable-mouse* #:*disable-mouse*
           #:decode #:describe-key #:read-key #:*sequence-timeout*
           #:with-raw-terminal #:terminal-p
           #:make-blank-screen #:screen-rows #:put #:flush #:clear-back
           #:screen #:screen-width #:screen-height
           #:pane #:make-pane #:fresh-pane #:pane-kind #:pane-target #:pane-id #:pane-p
           #:branch #:make-branch #:branch-p #:branch-direction #:branch-children
           #:branch-weights #:pane-tree-panes #:find-pane #:split-pane #:close-pane
           #:neighbour-pane #:layout-form #:resize-pane #:replace-pane
           #:paint #:layout-for #:wrap #:cursor-for #:visible-rows
           #:view #:make-view #:absorb #:type-key #:take-input
           #:view-lines #:view-partial #:view-input #:view-status #:view-busy
           #:view-sessions #:view-current #:view-tasks #:view-scroll
           #:terminal-size #:with-resize-notice #:take-resize #:*fallback-size*
           #:divide #:region-at #:within-p #:region-of #:draw-in #:region
           #:region-row #:region-column #:region-width #:region-height
           #:key #:key-value #:key-control #:key-alt #:key-shift))
