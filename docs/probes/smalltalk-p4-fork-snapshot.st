"B7 probe 4 -- can a Smalltalk image fork and let the CHILD write the snapshot,
the way SBCL does, so the serving parent never stops?

M1 established that the gap is fork versus stop-the-world rather than Lisp versus
Smalltalk: per megabyte Squeak writes its heap faster than SBCL's child does.
If a Smalltalk image can fork safely, the availability argument disappears and
Smalltalk keeps its continuation-preserving checkpoint.

The danger is not the green Processes -- those are objects in the heap. It is the
VM underneath them: a heartbeat thread, a kqueue-based aio loop, sockets, a JIT
code zone. fork() from a multithreaded process leaves the child holding locks
whose owner threads no longer exist. So this does not test fork once while idle.
It forks repeatedly while the image is doing all the things that could break it:
serving real traffic, churning the heap, ping-ponging semaphores, writing files,
and compiling methods.

Run under an external load generator; the client's log is the ground truth for
whether the parent kept serving."

| cls note stamp events server iterations forkResults restored childMark |

cls := Object subclass: #B7Fork.
cls class compile: 'forkNow ^ self ffiCall: #( long fork ( void ) ) module: LibC'.
cls class compile: 'getpid ^ self ffiCall: #( long getpid ( void ) ) module: LibC'.

stamp := [ | n | n := DateAndTime now. (n asUnixTime * 1000) + (n nanoSecond // 1000000) ].
events := OrderedCollection new.
note := [ :line | events add: line , ' ' , stamp value printString ].
forkResults := OrderedCollection new.
restored := false.
iterations := 10.

"--- the server whose availability is the whole point ----------------------"
server := ZnServer startDefaultOn: 8971.
server maximumNumberOfConcurrentConnections: 64.
server onRequestRespond: [ :request |
	| id ms |
	id := (request uri queryAt: #id ifAbsent: [ '0' ]) asInteger.
	ms := (request uri queryAt: #ms ifAbsent: [ '300' ]) asInteger.
	note value: 'start ' , id printString.
	(Delay forMilliseconds: ms) wait.
	note value: 'end ' , id printString.
	ZnResponse ok: (ZnEntity text: 'id=' , id printString
		, ' churn=' , (Smalltalk at: #P4Churn) printString
		, ' compiles=' , (Smalltalk at: #P4Compiles) printString) ].

"--- hostile runtime activity, running throughout --------------------------"
Smalltalk at: #P4Churn put: 0.
[ [ true ] whileTrue: [
	Array new: 20000.
	OrderedCollection new addAll: (1 to: 500); yourself.
	Smalltalk at: #P4Churn put: (Smalltalk at: #P4Churn) + 1.
	(Delay forMilliseconds: 5) wait ] ] fork.

Smalltalk at: #P4Ping put: 0.
Smalltalk at: #P4Sem put: Semaphore new.
[ [ true ] whileTrue: [ (Delay forMilliseconds: 7) wait. (Smalltalk at: #P4Sem) signal ] ] fork.
[ [ true ] whileTrue: [
	(Smalltalk at: #P4Sem) wait.
	Smalltalk at: #P4Ping put: (Smalltalk at: #P4Ping) + 1 ] ] fork.

Smalltalk at: #P4Writes put: 0.
[ [ true ] whileTrue: [
	'p4-churn.txt' asFileReference writeStreamDo: [ :s |
		s setToEnd; nextPutAll: (Smalltalk at: #P4Writes) printString; lf ].
	Smalltalk at: #P4Writes put: (Smalltalk at: #P4Writes) + 1.
	(Delay forMilliseconds: 11) wait ] ] fork.

"Method compilation forces new code through the JIT while forks are happening."
Smalltalk at: #P4Compiles put: 0.
[ [ true ] whileTrue: [ | n |
	n := Smalltalk at: #P4Compiles.
	cls class compile: 'churn' , n printString , ' ^ ' , n printString.
	cls perform: ('churn' , n printString) asSymbol.
	Smalltalk at: #P4Compiles put: n + 1.
	(Delay forMilliseconds: 13) wait ] ] fork.

('p4-events.log' asFileReference) ensureCreateFile; writeStreamDo: [ :s |
	s setToEnd; nextPutAll: 'listening ' , stamp value printString; lf ].

"--- let the load generator reach steady state -----------------------------"
(Delay forSeconds: 8) wait.

1 to: iterations do: [ :i |
	restored ifFalse: [ | before after pid |
		i = 1 ifTrue: [ note value: 'snapshot-begin' ].
		before := stamp value.
		pid := cls forkNow.
		pid = 0
			ifTrue: [
				"Child. Save, then decide whether we are the child that just saved
				 or this same image being restarted much later: the pid tells us."
				childMark := cls getpid.
				Smalltalk saveAs: 'p4-fork-', i printString.
				cls getpid = childMark
					ifTrue: [ Smalltalk quitPrimitive ]
					ifFalse: [ restored := true. note value: 'RESTORED-IMAGE-RESUMED' ] ]
			ifFalse: [
				after := stamp value.
				i = 1 ifTrue: [ note value: 'snapshot-end' ].
				forkResults add: (Array with: i with: after - before with: pid).
				note value: 'fork ' , i printString , ' parentStallMs=' , (after - before) printString.
				(Delay forSeconds: 3) wait ] ] ].

restored ifFalse: [
	(Delay forSeconds: 6) wait.
	server stop.
	note value: 'stopped'.

	('p4-events.log' asFileReference) writeStreamDo: [ :s |
		s setToEnd.
		events do: [ :e | s nextPutAll: e; lf ] ].

	('p4-result.json' asFileReference) ensureCreateFile; writeStreamDo: [ :s |
		s setToEnd; nextPutAll: (String streamContents: [ :o |
			o nextPutAll: '{"parentStallsMs":['.
			forkResults doWithIndex: [ :r :n |
				o nextPutAll: (r at: 2) printString.
				n < forkResults size ifTrue: [ o nextPutAll: ',' ] ].
			o nextPutAll: '],"forks":' , forkResults size printString.
			o nextPutAll: ',"churnIterations":' , (Smalltalk at: #P4Churn) printString.
			o nextPutAll: ',"semaphoreHandoffs":' , (Smalltalk at: #P4Ping) printString.
			o nextPutAll: ',"fileWrites":' , (Smalltalk at: #P4Writes) printString.
			o nextPutAll: ',"methodsCompiled":' , (Smalltalk at: #P4Compiles) printString.
			o nextPutAll: ',"requestsStarted":' , (events count: [ :e | e beginsWith: 'start' ]) printString.
			o nextPutAll: ',"requestsFinished":' , (events count: [ :e | e beginsWith: 'end' ]) printString.
			o nextPutAll: '}' ]) ] ].

'p4 done'
