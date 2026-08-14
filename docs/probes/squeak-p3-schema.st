"B7 probe 3, on native ARM64 Squeak -- the control for the Pharo run.

The Pharo result was that argument names and the method comment are not in the
image: they are read through a sourcePointer into the .changes file, and moving
that file aside degrades a live method to #(#arg1 #arg2) with a nil comment while
it still runs. This checks whether that is a Pharo packaging choice or the
Smalltalk source model. Run twice: once with .changes present, once without.

The file is opened before anything is reflected on, and every fact is guarded
separately, so a selector this Squeak does not have costs one line rather than
the whole run."

| f say cls method |

f := FileStream forceNewFileNamed: 'p3s-out.txt'.
say := [ :k :block |
	f nextPutAll: k; nextPutAll: ' : '.
	f nextPutAll: ([ block value printString ] on: Error do: [ :e | 'ERROR ' , e class name , ' ' , e messageText printString ]).
	f lf ].

cls := Smalltalk at: #ShopProbe.
method := cls compiledMethodAt: #orderTotal:tax:.

say value: 'changesFile' value: [ (Smalltalk imageName copyReplaceAll: '.image' with: '.changes') ].
say value: 'changesFileExists' value: [ (FileDirectory default
	fileExists: (Smalltalk imageName copyReplaceAll: '.image' with: '.changes')) ].
say value: 'selector' value: [ method selector ].
say value: 'numArgs' value: [ method numArgs ].
say value: 'selectorKeywords' value: [ method selector keywords collect: [ :k | k allButLast ] ].
say value: 'argumentNames' value: [ method methodNode argumentNames ].
say value: 'argumentNames2' value: [ method methodNode arguments collect: [ :a | a name ] ].
say value: 'comment' value: [ method methodNode comment ].
say value: 'sourcePointer' value: [ method sourcePointer ].
say value: 'getSource' value: [ method getSource asString ].
say value: 'runs' value: [ cls new orderTotal: #(10 20 5) tax: 0.2 ].

f close.
Smalltalk snapshot: false andQuit: true.
