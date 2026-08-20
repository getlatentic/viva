;;;; MCP: the registry, served to anybody.
;;;;
;;;; What the organism retains is worth more if it is not trapped inside the
;;;; organism. A tool it wrote should be callable from whatever the person is
;;;; actually sitting in front of -- Claude Code, an editor, a multiplexer
;;;; pane -- and MCP is the format that already crosses those boundaries.
;;;; This is the plug, and it is why the manifest was JSON from the start:
;;;; PARAMETER-SCHEMA emits exactly the `inputSchema` a tool description
;;;; needs, so `tools/list` is a projection of the registry rather than a
;;;; translation of it.
;;;;
;;;; Shapes verified against the specification schema, not recalled:
;;;;
;;;;   initialize   -> protocolVersion, capabilities, serverInfo
;;;;   tools/list   -> {tools: [{name, description, inputSchema}]}
;;;;   tools/call   -> {content: [{type: "text", text}], isError}
;;;;
;;;; THE ERROR RULE IS NORMATIVE AND SPLITS TWO WAYS. A tool that ran and
;;;; failed is a RESULT with isError true -- the model is meant to read it
;;;; and try something else. Failing to FIND the tool, or a malformed
;;;; request, is a protocol error object. Collapsing them either way is a
;;;; real bug: protocol errors as results hide breakage from the client, and
;;;; tool failures as protocol errors deny the model its chance to recover.
;;;;
;;;; Transport is stdio, one JSON object per line, which is why nothing here
;;;; may ever print to standard output except a reply.

(in-package #:vivarium.mcp)

(defparameter *protocol-version* "2025-11-25"
  "The version this server speaks. A client asking for another gets this one
back and decides for itself whether to continue -- the specification puts
that choice on the client, and guessing agreement would be worse.")

(defparameter *server-name* "vivarium-tools")

(defparameter *server-version* "0.1.0"
  "Stated, not derived. ASDF:COMPONENT-VERSION returns NIL for a system that
declares none, and NIL is JSON false -- so the first draft advertised
\"version\": false to every client. A literal cannot do that.")

;;; JSON booleans and null, probed rather than assumed. jzon maps NIL to
;;; FALSE, T to TRUE, the symbol NULL to null -- and any KEYWORD to a
;;; STRING. The first draft wrote :FALSE and shipped "isError":"FALSE", a
;;; truthy string that would have told every client each successful call had
;;; failed. Caught by driving the real wire, invisible to any in-process test.

(defconstant +true+ t)
(defparameter +false+ nil)
(defparameter +null+ 'null)

(defun object (&rest pairs)
  (let ((table (make-hash-table :test #'equal)))
    (loop for (key value) on pairs by #'cddr do (setf (gethash key table) value))
    table))

(defun reply (id result)
  (object "jsonrpc" "2.0" "id" id "result" result))

(defun fail (id code message)
  (object "jsonrpc" "2.0" "id" id
          "error" (object "code" code "message" message)))

;;; The registry, as tool descriptions

(defun tool-description (entry)
  (object "name" (registry:entry-name entry)
          "description" (registry:entry-description entry)
          "inputSchema" (schema:parameter-schema (registry:entry-parameters entry))))

(defun describe-tools (entries)
  (object "tools" (map 'vector #'tool-description entries)))

(defun text-content (text)
  (vector (object "type" "text" "text" text)))

(defun call-tool (entries arguments cwd name)
  "Run one registry tool. Returns a CallToolResult, or NIL when no such tool
exists -- which is the caller's signal to answer with a protocol error
rather than a result, per the specification's split."
  (a:when-let ((entry (find name entries :key #'registry:entry-name :test #'string=)))
    (handler-case
        (multiple-value-bind (exit output)
            (registry:run-entry entry arguments cwd)
          (object "content" (text-content output)
                  "isError" (if (zerop exit) +false+ +true+)))
      (error (condition)
        (object "content" (text-content (format nil "~a could not run: ~a" name condition))
                "isError" +true+)))))

;;; The loop

(defun handle (message entries cwd)
  "One request to one reply, or NIL for a notification.

Notifications carry no id and MUST NOT be answered; `notifications/
initialized` is the ordinary one and arrives after every handshake."
  (let ((method (gethash "method" message))
        (id (gethash "id" message))
        (params (gethash "params" message)))
    (cond
      ((null method) (fail id -32600 "not a request"))
      ((null id) nil)
      ((string= method "initialize")
       (reply id (object "protocolVersion" *protocol-version*
                         "capabilities" (object "tools" (object "listChanged" +false+))
                         "serverInfo" (object "name" *server-name*
                                              "version" *server-version*))))
      ((string= method "ping") (reply id (object)))
      ((string= method "tools/list") (reply id (describe-tools entries)))
      ((string= method "tools/call")
       (let ((name (and params (gethash "name" params)))
             (arguments (and params (gethash "arguments" params))))
         (cond ((not (stringp name)) (fail id -32602 "tools/call needs a name"))
               (t (a:if-let ((result (call-tool entries arguments cwd name)))
                    (reply id result)
                    ;; Not a result with isError: failing to FIND a tool is a
                    ;; protocol error by the specification, and a client that
                    ;; cannot tell "your tool broke" from "there is no such
                    ;; tool" cannot report either one honestly.
                    (fail id -32602 (format nil "no such tool: ~a" name)))))))
      (t (fail id -32601 (format nil "unsupported method: ~a" method))))))

(defun serve (&key (input *standard-input*) (output *standard-output*)
                   environment directories cwd)
  "Serve the registry over stdio until end of input.

Entries are read ONCE, at startup: a served surface that changed under a
client mid-session would be lying about what it advertised, and the protocol
has a listChanged notification for that which this server does not claim."
  (let* ((entries (registry:load-entries environment directories))
         (where (or cwd (env:env-cwd environment))))
    (loop for line = (read-line input nil nil)
          while line
          do (a:when-let
                 ((response
                   (handler-case
                       (handle (com.inuoe.jzon:parse line) entries where)
                     (error (condition)
                       (fail +null+ -32700 (format nil "could not parse: ~a" condition))))))
               (write-string (com.inuoe.jzon:stringify response) output)
               (terpri output)
               (finish-output output)))))
