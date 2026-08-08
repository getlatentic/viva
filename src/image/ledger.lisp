;;;; An append-only record of every definition installed into the image.
;;;;
;;;; A live image an agent edits is only trustworthy if every change is
;;;; recoverable from something other than the image itself. The ledger holds the
;;;; source text of every version installed, so a definition can be rolled back
;;;; and a run can be replayed into a fresh image from source alone.
;;;;
;;;; It is also the unit of search: a candidate produced by a trial is exactly a
;;;; set of entries, so promoting a winner is replaying them rather than merging
;;;; text.

(in-package #:vivarium.ledger)

(defstruct (entry (:conc-name entry-))
  (id 0 :type integer)
  (timestamp 0 :type integer)
  (target "" :type string)
  (source "" :type string)
  (previous-source nil)
  (note nil)
  (outcome nil))

(defclass ledger ()
  ((lock :initform (bt:make-lock "vivarium.ledger") :reader ledger-lock)
   (entries :initform (make-array 0 :adjustable t :fill-pointer t) :reader %entries)
   (counter :initform 0 :accessor %counter)
   (path :initarg :path :initform nil :accessor ledger-path
         :documentation "When set, each entry is also appended as one JSON line.")))

(defun make-ledger (&key path)
  (make-instance 'ledger :path path))

(defun entry-json (entry)
  (let ((object (make-hash-table :test #'equal)))
    (setf (gethash "id" object) (entry-id entry)
          (gethash "timestamp" object) (entry-timestamp entry)
          (gethash "target" object) (entry-target entry)
          (gethash "source" object) (entry-source entry)
          (gethash "previousSource" object) (entry-previous-source entry)
          (gethash "note" object) (entry-note entry)
          (gethash "outcome" object) (entry-outcome entry))
    object))

(defun persist (ledger entry)
  (a:when-let ((path (ledger-path ledger)))
    (with-open-file (out path :direction :output :if-exists :append
                              :if-does-not-exist :create :external-format :utf-8)
      (write-string (jzon:stringify (entry-json entry)) out)
      (terpri out))))

(defun record (ledger target source &key note outcome)
  "Append an installation of TARGET, capturing whatever version it replaces."
  (bt:with-lock-held ((ledger-lock ledger))
    (let ((entry (make-entry :id (incf (%counter ledger))
                             :timestamp (get-universal-time)
                             :target target
                             :source source
                             :previous-source (%latest-source ledger target)
                             :note note
                             :outcome outcome)))
      (vector-push-extend entry (%entries ledger))
      (persist ledger entry)
      entry)))

(defun %latest-source (ledger target)
  "Most recent source for TARGET. Caller holds the lock."
  (let ((entries (%entries ledger)))
    (loop for i from (1- (fill-pointer entries)) downto 0
          for entry = (aref entries i)
          when (string= target (entry-target entry))
            return (entry-source entry))))

(defun latest-source (ledger target)
  (bt:with-lock-held ((ledger-lock ledger)) (%latest-source ledger target)))

(defun previous-source (ledger target)
  "The source TARGET had before its most recent installation, or NIL if this
ledger installed it for the first time."
  (bt:with-lock-held ((ledger-lock ledger))
    (let ((entries (%entries ledger)))
      (loop for i from (1- (fill-pointer entries)) downto 0
            for entry = (aref entries i)
            when (string= target (entry-target entry))
              return (entry-previous-source entry)))))

(defun entries (ledger &key target)
  (bt:with-lock-held ((ledger-lock ledger))
    (let ((all (coerce (%entries ledger) 'list)))
      (if target
          (remove target all :key #'entry-target :test-not #'string=)
          all))))

(defun reset (ledger)
  (bt:with-lock-held ((ledger-lock ledger))
    (setf (fill-pointer (%entries ledger)) 0
          (%counter ledger) 0)))
