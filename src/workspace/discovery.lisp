;;;; Asking a server what it serves.
;;;;
;;;; A LIST WRITTEN DOWN GOES STALE. Ollama serves whatever somebody pulled
;;;; onto the machine this morning, and llama.cpp serves the one model it was
;;;; started with. Either list is wrong by lunchtime, and a catalogue that
;;;; shipped a guess would be wrong immediately -- so the honest list is the one
;;;; the server gives when asked. This is Pi's dynamic provider: a static
;;;; provider returns its catalogue, a dynamic one returns what it last saw.
;;;;
;;;; LOCAL SERVERS ONLY, and deliberately. A hosted provider's /v1/models is
;;;; long and includes ids nobody should reach for by accident -- every
;;;; `anthropic.*` on Bedrock is sold through AWS Marketplace, so promotional
;;;; credits never pay for it. Discovering those would put a model on the menu
;;;; whose bill arrives a month later. What a hosted provider offers stays
;;;; something a person wrote down.
;;;;
;;;; CACHED, BECAUSE THIS IS ON THE PATH. Resolving a model happens at every
;;;; session start. A server that has stopped answering must cost one bounded
;;;; wait rather than one per session, so a failure is remembered for as long as
;;;; a success would be.

(in-package #:viva.discovery)

(defparameter +timeout+ 2
  "Seconds to wait on a local server. Long enough for a loaded one to answer,
short enough that a dead one does not hold up a session.")

(defparameter +ttl+ 60
  "Seconds a list is trusted. Pulling a model is a deliberate act and a person
who has just done one will wait a minute, or ask for a refresh.")

(defvar *seen* (make-hash-table :test #'equal)
  "Endpoint -> (WHEN . IDS).

NO LOCK. Two threads racing here both fetch and both write the same answer,
which costs one extra request and corrupts nothing -- and a lock on the path
every session start takes would be the more expensive mistake.")

(defun models-url (chat-endpoint)
  "The /v1/models URL beside a chat-completions one."
  (let ((tail (search "/chat/completions" chat-endpoint :from-end t)))
    (if tail
        (concatenate 'string (subseq chat-endpoint 0 tail) "/models")
        chat-endpoint)))

(defun models-at-openai (endpoint)
  "The ids this server reports, or NIL. Never signals: a server that is not
running is an ordinary state, not a fault to propagate into a session start."
  (handler-case
      (let* ((body (dex:get (models-url endpoint)
                            :connect-timeout +timeout+
                            :read-timeout +timeout+
                            :force-string t))
             (parsed (jzon:parse body))
             (data (and (hash-table-p parsed) (gethash "data" parsed))))
        (loop for each across (if (vectorp data) data #())
              for id = (and (hash-table-p each) (gethash "id" each))
              when (and (stringp id) (plusp (length id)))
                collect id))
    (error () nil)))

(defun base-of (chat-endpoint)
  "The server root, from a chat-completions URL."
  (let ((tail (search "/v1/" chat-endpoint :from-end t)))
    (if tail (subseq chat-endpoint 0 tail) chat-endpoint)))

(defun ollama-capabilities (base id)
  "What Ollama says a model can do, as a list of strings, or NIL.

ITS OWN API, not the OpenAI-compatible one, because /v1/models says only that
a model exists. /api/show says whether it can hold a conversation at all:
an embedding model answers (\"embedding\") and a chat model (\"completion\"
\"tools\"). Offering an embedder as a chat model is a choice that cannot work,
and a name heuristic would misclassify the next one somebody pulls."
  (handler-case
      (let* ((body (dex:post (concatenate 'string base "/api/show")
                             :content (jzon:stringify
                                       (let ((h (make-hash-table :test #'equal)))
                                         (setf (gethash "model" h) id) h))
                             :headers '(("content-type" . "application/json"))
                             :connect-timeout +timeout+ :read-timeout +timeout+
                             :force-string t))
             (parsed (jzon:parse body))
             (found (and (hash-table-p parsed) (gethash "capabilities" parsed))))
        (loop for each across (if (vectorp found) found #())
              when (stringp each) collect each))
    (error () nil)))

(defun ollama-chat-models (endpoint)
  "The ids on this Ollama that can hold a conversation, newest first.

A MODEL WITH NO CAPABILITIES REPORTED IS KEPT. The narrowing exists to drop
what is certainly unusable, and a server that will not answer /api/show has
told us nothing -- dropping everything then would turn one silent API change
into an empty menu."
  (let ((base (base-of endpoint)))
    (loop for id in (models-at-openai endpoint)
          for capabilities = (ollama-capabilities base id)
          unless (and capabilities
                      (not (member "completion" capabilities :test #'string=)))
            collect id)))

(defun models-at (endpoint &key refresh (how #'models-at-openai))
  "What ENDPOINT serves, from cache unless REFRESH or the cache is stale.

HOW is the way to ask. Generic by default: an OpenAI-compatible /v1/models. A
provider whose own API says more passes its own."
  (let ((remembered (gethash endpoint *seen*)))
    (if (and (not refresh)
             remembered
             (< (- (get-universal-time) (car remembered)) +ttl+))
        (cdr remembered)
        (let ((found (funcall how endpoint)))
          (setf (gethash endpoint *seen*) (cons (get-universal-time) found))
          found))))

(defun forget ()
  "Drop every remembered list, so the next ask reaches the servers."
  (clrhash *seen*))
