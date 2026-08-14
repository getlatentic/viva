"B7 probe 2 -- does a computation snapshotted from the middle of itself CONTINUE
when the saved image is restarted, or restart from the top?

SBCL provably cannot do this: a core saved mid-loop at step 5 restores with the
counter at 5 and then enters :toplevel. The test here is not whether Pharo can
in principle, but whether it does in practice, for the kinds of suspended state
a harness actually holds: stack-local accumulators, a deep call chain, a delay,
a semaphore, and a listening socket.

Every trace line carries a wall-clock stamp and is appended, so the original
image's lines and the restored image's lines land in one file in time order.
The original is killed before the restored image is started, so any line with a
later stamp was written by the restored image."

| log stamp note ticket |

log := 'p2-trace.log' asFileReference.
log ensureCreateFile.
stamp := [ | n | n := DateAndTime now. (n asUnixTime * 1000) + (n nanoSecond // 1000000) ].
note := [ :line |
	log writeStreamDo: [ :s |
		s setToEnd; nextPutAll: stamp value printString , ' ' , line; lf ] ].

note value: 'boot image=' , Smalltalk imagePath.

"--- A: stack-local accumulator, driven by a Delay -------------------------
 sum and i live only on this process's stack. Nothing reads them from a global,
 so a restarted-from-scratch process would necessarily show sum back at 0."
[ | sum |
  sum := 0.
  1 to: 2000 do: [ :i |
     sum := sum + i.
     note value: 'A step=' , i printString , ' sum=' , sum printString.
     (Delay forMilliseconds: 150) wait ].
  note value: 'A finished sum=' , sum printString ] fork.

"--- E: deep call chain ----------------------------------------------------
 Each level pins a marker in its own frame and prints it on the way out. If the
 restored image rebuilt the process instead of resuming it, the unwind could not
 report the markers of frames that were entered before the snapshot."
Smalltalk at: #P2Descend put: [ :depth :levelBlock |
	| marker |
	marker := depth * 7.
	note value: 'E enter depth=' , depth printString , ' marker=' , marker printString.
	(Delay forMilliseconds: 400) wait.
	depth > 0 ifTrue: [ levelBlock value: depth - 1 value: levelBlock ].
	note value: 'E leave depth=' , depth printString , ' marker=' , marker printString ].
[ (Smalltalk at: #P2Descend) value: 12 value: (Smalltalk at: #P2Descend).
  note value: 'E unwound' ] fork.

"--- B: blocked on a Semaphore another process signals ---------------------"
ticket := Semaphore new.
[ 1 to: 500 do: [ :i |
    (Delay forMilliseconds: 900) wait.
    ticket signal ] ] fork.
[ | taken |
  taken := 0.
  [ true ] whileTrue: [
     ticket wait.
     taken := taken + 1.
     note value: 'B took=' , taken printString ] ] fork.

"--- S: a listening socket and a counter in the image ----------------------"
Smalltalk at: #P2Hits put: 0.
Smalltalk at: #P2Server put: (ZnServer on: 8952).
(Smalltalk at: #P2Server) onRequestRespond: [ :request |
	Smalltalk at: #P2Hits put: (Smalltalk at: #P2Hits) + 1.
	ZnResponse ok: (ZnEntity text: 'hits=' , (Smalltalk at: #P2Hits) printString) ].
(Smalltalk at: #P2Server) start.

"--- let the processes get well into their work, then snapshot -------------"
(Delay forSeconds: 5) wait.
note value: 'snapshot-begin'.
Smalltalk snapshot: true andQuit: false.
note value: 'snapshot-end'.

"The main process is itself mid-computation here: this counted loop is the
 fifth subject. A restored image that restarts rather than resumes would show
 tick=1 again."
1 to: 120 do: [ :tick |
	note value: 'MAIN tick=' , tick printString.
	(Delay forSeconds: 1) wait ].
'p2 done'
