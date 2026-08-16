(defvar *flags* '(:metrics :color))
(defun flag-enabled-p (flag) (and (member flag *flags*) t))
