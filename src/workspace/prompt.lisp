;;;; The system prompt, assembled from what is actually present.
;;;;
;;;; Nothing here is a constant string with everything in it. The tool list is
;;;; generated from the tool set, the skills block only appears when skills
;;;; exist, and the instructions block only appears when instruction files do.
;;;;
;;;; That is a correctness property, not tidiness. B14's Gate 1 failed 0 of 5
;;;; because the image harness's prompt still described a world of reading
;;;; source while the tool set had gained an inspection primitive -- five runs
;;;; used it 0, 0, 1, 0 and 1 times. A prompt maintained by hand beside a tool
;;;; set maintained in code will drift, and the drift is invisible from inside.

(in-package #:vivarium.workspace)

(defvar *base-prompt*
  "You are a capable software engineer working in a real codebase. You read
files, search the repository, run commands, and change code.

Work from evidence. Read a file before you edit it, and check what a change did
rather than assuming it took. When something fails, find out why -- your first
guess should be that your own change or your own command is wrong, not that the
tool or the codebase is broken.

Finish what you were asked. If part of it turns out to be blocked, do the rest
and say plainly what you left and why."
  "Kept short deliberately. Vivarium is compared against other harnesses on the
same model, and a prompt that carries the answer moves the result without
telling anyone which part did it.")

(defun sentence-end (text)
  "The first period that actually ends a sentence: one followed by a space and a
capital, or by nothing at all.

A plain (position #\. text) cuts `e.g.` in half, which is not hypothetical --
every system prompt this harness has ever sent advertised the FIND tool as
\"Find files by glob pattern, e.\" and nobody read one to notice."
  (loop for index = (position #\. text) then (position #\. text :start (1+ index))
        while index
        do (let ((next (find-if-not (lambda (character) (char= #\Space character))
                                    text :start (1+ index))))
             (when (or (null next) (upper-case-p next))
               (return index)))))

(defun first-sentence (text)
  (let* ((flat (substitute #\Space #\Newline text))
         (stop (sentence-end flat)))
    (string-trim '(#\Space) (subseq flat 0 (if stop (1+ stop) (min 110 (length flat)))))))

(defun tool-summaries (tools)
  (format nil "~{~a~%~}"
          (mapcar (lambda (each)
                    (format nil "- ~a: ~a" (tool:tool-name each)
                            (first-sentence (tool:tool-description each))))
                  tools)))

(defun sections (&rest parts)
  (format nil "~{~a~^~%~%~}"
          (remove-if (lambda (part) (or (null part) (zerop (length part))))
                     parts)))

(defun build-system-prompt (&key tools skills-block instructions-block (base *base-prompt*)
                              extra (cwd (env:env-cwd (environment))))
  "Assemble the prompt for the next request.

Called at request time rather than at startup, because a run that installs a
skill or writes a memory has changed what the next request should say."
  (sections base
            (when tools (format nil "Tools available to you:~%~a" (tool-summaries tools)))
            instructions-block
            skills-block
            extra
            (format nil "Working directory: ~a" cwd)))
