(defvar *flags* '(:audit))
(defun flag-enabled-p (flag) (and (member flag *flags*) t))
