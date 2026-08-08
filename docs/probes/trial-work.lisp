;;;; One trial's worth of work: install a definition into the image and call it.
;;;; Timed from process start so the number includes image startup.
(let ((sym (or (find-symbol "ORDER-TOTAL" "GENERA-LAB.APP") 'order-total-missing)))
  (eval `(defun ,sym (order) (declare (ignore order)) 42))
  (format t "~&trial-ok ~a~%" (funcall sym nil)))
(sb-ext:exit :code 0 :abort t)
