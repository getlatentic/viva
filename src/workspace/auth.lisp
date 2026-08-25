;;;; Where a provider key comes from, and in what order.
;;;;
;;;; Three places, tried in this order:
;;;;
;;;;   1. what the caller passed on the command line
;;;;   2. `~/.viva/auth.json`
;;;;   3. the environment
;;;;
;;;; THE FILE BEATS THE ENVIRONMENT because the environment is where a shell
;;;; leaves whatever it happened to export, and the file is where somebody put
;;;; a key on purpose. A flag beats both: it names one key for one run and
;;;; cannot have been meant for anything else.
;;;;
;;;; A KEY IS NOT A SETTING. Settings live in `config`, which is a file people
;;;; copy into projects and commit. Keeping keys in their own file, read by
;;;; this process rather than sourced by a shell, is what lets a build that is
;;;; one executable on a PATH have credentials at all.

(in-package #:viva.auth)

(defparameter *file-shape*
  "{
  \"deepseek\":   { \"apiKey\": \"sk-...\" },
  \"openrouter\": { \"apiKey\": \"sk-or-...\" }
}"
  "What auth.json holds. One object per provider, keyed by its catalogue name.")

(defun read-auth (&optional (path (env:auth-path)))
  "The parsed auth file, or NIL.

A malformed file returns NIL rather than signalling. It is edited by hand, it
holds secrets, and the failure a person needs is `no key for deepseek` when
they run something -- not a JSON parse error thrown from inside startup, whose
message would be the first thing to quote a line of the file."
  (when (probe-file path)
    (ignore-errors
     (with-open-file (in path :external-format :utf-8)
       (let ((parsed (jzon:parse in)))
         (when (hash-table-p parsed) parsed))))))

(defun entry-key (entry)
  "The key out of one provider's entry, whichever spelling it uses."
  (etypecase entry
    (string entry)
    (hash-table (loop for name in '("apiKey" "api_key" "key" "token")
                      for found = (gethash name entry)
                      when (and (stringp found) (plusp (length found)))
                        return found))
    (t nil)))

(defun key-from-file (provider &optional (auth (read-auth)))
  (when auth
    (a:when-let ((entry (gethash provider auth)))
      (entry-key entry))))

(defun key-for (provider variable &key given (auth (read-auth)))
  "PROVIDER's key: GIVEN, then the auth file, then VARIABLE in the environment."
  (flet ((usable (value) (and (stringp value) (plusp (length value)) value)))
    (or (usable given)
        (usable (key-from-file provider auth))
        (usable (sb-posix:getenv variable)))))

(defun configured-providers (&optional (auth (read-auth)))
  "Which providers the file carries a key for. Names only -- never the keys."
  (when auth
    (sort (loop for provider being the hash-keys of auth
                when (entry-key (gethash provider auth)) collect provider)
          #'string<)))
