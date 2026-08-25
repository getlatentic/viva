;;;; Search packages: scored trials and the archive over them.

(defpackage #:viva.trial
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria)
                    (#:jzon #:com.inuoe.jzon)
                    (#:ledger #:viva.ledger)
                    (#:image #:viva.image))
  (:export #:candidate #:make-candidate #:candidate-id #:candidate-definitions
           #:candidate-parent #:candidate-from-entries
           #:result #:make-result #:result-candidate #:result-scores #:result-status
           #:result-detail #:result-elapsed-ms #:result-total
           #:run-trial #:run-trials #:check-zygote #:not-a-zygote #:apply-candidate))

(defpackage #:viva.arena
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria)
                    (#:trial #:viva.trial))
  (:export #:archive #:make-archive #:admit #:archive-results #:scored
           #:frontier #:best-by-total #:dominated-p #:winners-on #:case-names
           #:score-on #:select-parent #:report
           #:merge-candidates #:conflicts-between #:complementary-pair
           #:definition-table))

