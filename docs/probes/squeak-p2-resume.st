"B7 probe 2, on native ARM64 Squeak -- the control for the Pharo run.

Same five subjects as smalltalk-p2-resume.st: a stack-local accumulator driven by
a Delay, a deep call chain with a marker pinned in each frame, a semaphore-blocked
process, a listening server, and the script's own process. Every line is stamped
and appended, the original is killed before the saved image is restarted, so any
line with a later stamp came from the restored image."

| log stamp note ticket descend |

log := 'p2s-trace.log'.
stamp := [ | n | n := DateAndTime now. (n asUnixTime * 1000) + (n nanoSecond // 1000000) ].
note := [ :line |
	(FileStream fileNamed: log) setToEnd;
		nextPutAll: stamp value printString , ' ' , line; lf; close ].

note value: 'boot image=' , Smalltalk imageName.

"--- A: stack-local accumulator, driven by a Delay -------------------------"
[ | sum |
  sum := 0.
  1 to: 2000 do: [ :i |
     sum := sum + i.
     note value: 'A step=' , i printString , ' sum=' , sum printString.
     (Delay forMilliseconds: 150) wait ].
  note value: 'A finished sum=' , sum printString ] fork.

"--- E: deep call chain, a marker pinned in each frame ---------------------"
descend := nil.
descend := [ :depth |
	| marker |
	marker := depth * 7.
	note value: 'E enter depth=' , depth printString , ' marker=' , marker printString.
	(Delay forMilliseconds: 400) wait.
	depth > 0 ifTrue: [ descend value: depth - 1 ].
	note value: 'E leave depth=' , depth printString , ' marker=' , marker printString ].
[ descend value: 12. note value: 'E unwound' ] fork.

"--- B: blocked on a Semaphore another process signals ---------------------"
ticket := Semaphore new.
[ 1 to: 500 do: [ :i | (Delay forMilliseconds: 900) wait. ticket signal ] ] fork.
[ | taken |
  taken := 0.
  [ true ] whileTrue: [
     ticket wait.
     taken := taken + 1.
     note value: 'B took=' , taken printString ] ] fork.

"--- S: a listening socket and a counter in the image ----------------------"
Smalltalk at: #P2sHits put: 0.
Smalltalk at: #P2sServer put: WebServer new.
(Smalltalk at: #P2sServer) addService: '/' action: [ :request |
	Smalltalk at: #P2sHits put: (Smalltalk at: #P2sHits) + 1.
	request send200Response: 'hits=' , (Smalltalk at: #P2sHits) printString ].
(Smalltalk at: #P2sServer) listenOn: 8962.

"--- let the processes get well into their work, then snapshot -------------"
(Delay forSeconds: 5) wait.
note value: 'snapshot-begin'.
Smalltalk snapshot: true andQuit: false.
note value: 'snapshot-end'.

"The main process is itself mid-computation here -- the fifth subject."
1 to: 120 do: [ :tick |
	note value: 'MAIN tick=' , tick printString.
	(Delay forSeconds: 1) wait ].
