;;;; A tree of panes, and moving around it.
;;;;
;;;; The shape tmux settled on, for the reason tmux settled on it: a layout
;;;; people can build by splitting what they are looking at is a tree, and any
;;;; other structure makes `split this pane in half` into a special case.
;;;;
;;;; WHAT A PANE HOLDS IS THE WHOLE DIFFERENCE. In tmux a pane holds a process,
;;;; so the multiplexer must emulate a terminal to know what is in it. Here a
;;;; pane holds a VIEW onto something the daemon already reports -- a session, a
;;;; task tree, a job's output -- and those arrive as typed events. No pty, no
;;;; emulator, and the vocabulary of what a pane can be is closed and small.
;;;;
;;;; The tree is data and every operation returns a new one. A layout that
;;;; mutates in place cannot be tested by comparing before and after, and
;;;; splitting a pane is exactly the operation you want to read as a value.

(in-package #:viva.tui)

(defstruct (pane (:conc-name pane-))
  (kind :session :type keyword)
  (target nil)
  (id 0 :type fixnum))   ; stable identity, so focus survives a resize or split

(defstruct (branch (:conc-name branch-))
  (direction :beside :type keyword)   ; :beside or :stack
  (children '() :type list)
  (weights '() :type list))

(defvar *next-pane-id* 0)

(defun fresh-pane (kind &optional target)
  (make-pane :kind kind :target target :id (incf *next-pane-id*)))

(defun pane-tree-panes (node)
  "Every pane in NODE, left to right, depth first -- which is the order the eye
travels and therefore the order `next pane` should use."
  (etypecase node
    (pane (list node))
    (branch (loop for child in (branch-children node)
                  append (pane-tree-panes child)))))

(defun find-pane (node id)
  (find id (pane-tree-panes node) :key #'pane-id))

(defun replace-pane (node id replacement)
  "NODE with the pane identified by ID swapped for REPLACEMENT.

Returns a new tree. The old one is untouched, so a caller holding the previous
layout still has it -- which is what makes undo a matter of keeping a value
rather than of writing an inverse for every operation."
  (etypecase node
    (pane (if (= (pane-id node) id) replacement node))
    (branch (make-branch :direction (branch-direction node)
                         :weights (copy-list (branch-weights node))
                         :children (loop for child in (branch-children node)
                                         collect (replace-pane child id replacement))))))

(defun split-pane (node id direction new-pane)
  "Split the pane identified by ID, putting NEW-PANE beside or below it.

Splitting a pane that is already a child of a branch in the SAME direction
extends that branch rather than nesting a second one inside it. Nesting would
be correct and would make three side-by-side panes a tree two deep, whose
resize behaviour nobody can predict from looking at the screen."
  (let ((target (find-pane node id)))
    (if (null target)
        node
        (let ((extended (extend-in-place node id direction new-pane)))
          (or extended
              (replace-pane node id
                            (make-branch :direction direction
                                         :children (list target new-pane)
                                         :weights (list 1 1))))))))

(defun extend-in-place (node id direction new-pane)
  "NODE with NEW-PANE added to the branch already holding ID, or NIL."
  (when (branch-p node)
    (if (and (eq direction (branch-direction node))
             (find id (branch-children node) :key (lambda (child)
                                                    (and (pane-p child) (pane-id child)))))
        (let ((position (position id (branch-children node)
                                  :key (lambda (child)
                                         (and (pane-p child) (pane-id child))))))
          (make-branch
           :direction direction
           :children (append (subseq (branch-children node) 0 (1+ position))
                             (list new-pane)
                             (subseq (branch-children node) (1+ position)))
           :weights (append (subseq (branch-weights node) 0 (1+ position))
                            (list 1)
                            (subseq (branch-weights node) (1+ position)))))
        (loop for child in (branch-children node)
              for index from 0
              for extended = (extend-in-place child id direction new-pane)
              when extended
                return (make-branch
                        :direction (branch-direction node)
                        :weights (copy-list (branch-weights node))
                        :children (append (subseq (branch-children node) 0 index)
                                          (list extended)
                                          (subseq (branch-children node) (1+ index))))))))

(defun close-pane (node id)
  "NODE without the pane identified by ID, or NIL if that was the last one.

A branch left holding one child COLLAPSES into that child. Without this a
layout accumulates branches of one for every pane ever closed, and their
weights go on dividing space that has nothing in it."
  (etypecase node
    (pane (if (= (pane-id node) id) nil node))
    (branch
     (let* ((kept (loop for child in (branch-children node)
                        for weight in (branch-weights node)
                        for survivor = (close-pane child id)
                        when survivor collect (cons survivor weight))))
       (cond ((null kept) nil)
             ((null (rest kept)) (car (first kept)))
             (t (make-branch :direction (branch-direction node)
                             :children (mapcar #'car kept)
                             :weights (mapcar #'cdr kept))))))))

(defun neighbour-pane (node id step)
  "The pane STEP places from ID in reading order, wrapping. NIL if alone."
  (let* ((panes (pane-tree-panes node))
         (position (position id panes :key #'pane-id)))
    (when (and position (rest panes))
      (nth (mod (+ position step) (length panes)) panes))))

(defun layout-form (node)
  "NODE as the form DIVIDE takes, naming each region by its pane id.

The layout engine already tiles a nested tree exactly, so panes get that for
free -- including the remainder handling, which is the part a hand-rolled pane
splitter gets wrong on the third pane."
  (etypecase node
    (pane (pane-id node))
    (branch (list* (branch-direction node)
                   (loop for child in (branch-children node)
                         for weight in (branch-weights node)
                         collect (list :weight weight (layout-form child)))))))

(defun resize-pane (node id amount)
  "NODE with ID's share of its branch changed by AMOUNT, never below one."
  (etypecase node
    (pane node)
    (branch
     (let ((position (position id (branch-children node)
                               :key (lambda (child)
                                      (and (pane-p child) (pane-id child))))))
       (make-branch
        :direction (branch-direction node)
        :children (loop for child in (branch-children node)
                        collect (if (pane-p child) child (resize-pane child id amount)))
        :weights (loop for weight in (branch-weights node)
                       for index from 0
                       collect (if (eql index position)
                                   (max 1 (+ weight amount))
                                   weight)))))))
