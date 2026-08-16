;;;; Report summaries.

(defpackage #:kc6.report (:use #:cl))
(in-package #:kc6.report)

(defun summarise (path)
  (with-open-file (stream path)
    (let* ((title (read-line stream))
           (header (read-line stream))
           (width (length header))
           (count (parse-integer (read-line stream))))
      (list :title title :count count))))
