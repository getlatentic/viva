"B7 probe 4b -- fork-snapshot as a candidate architectural PRIMITIVE, not a benchmark.

M4 showed 15 forks survive. That is experimental evidence, not a runtime guarantee,
and the claim it supports is narrow: fork-and-IMMEDIATELY-checkpoint appears viable.
It says nothing about forked images being safe general-purpose runtime clones.

Two things change here. First the child runs as little as possible between fork()
and death: it writes the image and then calls _exit directly, so the VM's normal
shutdown machinery never gets to tidy up resources it inherited but does not own.
Second the sample is large enough to catch a rare failure: hundreds of forks, all
under the same hostile activity, with the parent's stall recorded for every one.

saveAs: is deliberately kept rather than dropping to the raw snapshot primitive:
the session shutdown/startup hooks it runs are what re-create sockets on resume,
and an image that cannot restore is worth nothing however fast it was written."

| cls note stamp events server iterations stalls restored childMark failures spacing |

cls := Object subclass: #B7Fork2.
cls class compile: 'forkNow ^ self ffiCall: #( long fork ( void ) ) module: LibC'.
cls class compile: 'getpid ^ self ffiCall: #( long getpid ( void ) ) module: LibC'.
cls class compile: 'exitNow: code ^ self ffiCall: #( void _exit ( long code ) ) module: LibC'.
cls class compile: 'reapAny ^ self ffiCall: #( long waitpid ( long pid, void* status, long options ) ) module: LibC'.

stamp := [ | n | n := DateAndTime now. (n asUnixTime * 1000) + (n nanoSecond // 1000000) ].
events := OrderedCollection new.
note := [ :line | events add: line , ' ' , stamp value printString ].
stalls := OrderedCollection new.
failures := 0.
restored := false.
"Read 'iterations spacing' from p4b-config.txt so the driver can sweep the
 checkpoint rate without editing this file."
iterations := 250.
spacing := 200.
Smalltalk at: #P4bGCEvery put: 900.
[ | parts |
  parts := ('p4b-config.txt' asFileReference contents substrings: ' ') collect: [ :e | e asNumber ].
  parts size >= 2 ifTrue: [ iterations := parts first. spacing := parts second ].
  parts size >= 3 ifTrue: [ Smalltalk at: #P4bGCEvery put: (parts at: 3) ] ]
	on: Error do: [ :e | nil ].

server := ZnServer startDefaultOn: 8973.
server maximumNumberOfConcurrentConnections: 64.
server onRequestRespond: [ :request |
	| id ms |
	id := (request uri queryAt: #id ifAbsent: [ '0' ]) asInteger.
	ms := (request uri queryAt: #ms ifAbsent: [ '300' ]) asInteger.
	note value: 'start ' , id printString.
	(Delay forMilliseconds: ms) wait.
	note value: 'end ' , id printString.
	ZnResponse ok: (ZnEntity text: 'id=' , id printString
		, ' churn=' , (Smalltalk at: #P4bChurn) printString) ].

"--- the same hostile activity M4 used, running throughout -----------------"
Smalltalk at: #P4bChurn put: 0.
[ [ true ] whileTrue: [
	Array new: 20000.
	OrderedCollection new addAll: (1 to: 500); yourself.
	Smalltalk at: #P4bChurn put: (Smalltalk at: #P4bChurn) + 1.
	(Delay forMilliseconds: 5) wait ] ] fork.

Smalltalk at: #P4bSem put: Semaphore new.
Smalltalk at: #P4bPing put: 0.
[ [ true ] whileTrue: [ (Delay forMilliseconds: 7) wait. (Smalltalk at: #P4bSem) signal ] ] fork.
[ [ true ] whileTrue: [
	(Smalltalk at: #P4bSem) wait.
	Smalltalk at: #P4bPing put: (Smalltalk at: #P4bPing) + 1 ] ] fork.

Smalltalk at: #P4bWrites put: 0.
[ [ true ] whileTrue: [
	'p4b-churn.txt' asFileReference writeStreamDo: [ :s |
		s setToEnd; nextPutAll: (Smalltalk at: #P4bWrites) printString; lf ].
	Smalltalk at: #P4bWrites put: (Smalltalk at: #P4bWrites) + 1.
	(Delay forMilliseconds: 11) wait ] ] fork.

Smalltalk at: #P4bCompiles put: 0.
[ [ true ] whileTrue: [ | n |
	n := Smalltalk at: #P4bCompiles.
	cls class compile: 'soak' , n printString , ' ^ ' , n printString.
	cls perform: ('soak' , n printString) asSymbol.
	Smalltalk at: #P4bCompiles put: n + 1.
	(Delay forMilliseconds: 13) wait ] ] fork.

"A forced full GC every so often, so forks land during collection too."
Smalltalk at: #P4bGCs put: 0.
(Smalltalk at: #P4bGCEvery) > 0 ifTrue: [
	[ [ true ] whileTrue: [
		(Delay forMilliseconds: (Smalltalk at: #P4bGCEvery)) wait.
		Smalltalk garbageCollect.
		Smalltalk at: #P4bGCs put: (Smalltalk at: #P4bGCs) + 1 ] ] fork ].

('p4b-events.log' asFileReference) ensureCreateFile; writeStreamDo: [ :s |
	s setToEnd; nextPutAll: 'listening ' , stamp value printString; lf ].

(Delay forSeconds: 6) wait.

1 to: iterations do: [ :i |
	restored ifFalse: [ | before after pid |
		i = 1 ifTrue: [ note value: 'snapshot-begin' ].
		before := stamp value.
		pid := cls forkNow.
		pid = 0
			ifTrue: [
				childMark := cls getpid.
				"Rotate over 8 names so disk stays bounded and no two live children
				 ever write the same file."
				Smalltalk saveAs: 'p4b-fork-', (i \\ 8) printString.
				cls getpid = childMark
					ifTrue: [ cls exitNow: 0 ]
					ifFalse: [ restored := true. note value: 'RESTORED-IMAGE-RESUMED' ] ]
			ifFalse: [
				after := stamp value.
				i = 1 ifTrue: [ note value: 'snapshot-end' ].
				pid < 0
					ifTrue: [ failures := failures + 1 ]
					ifFalse: [
						stalls add: after - before.
						note value: 'forkstall ' , i printString , ' ' , (after - before) printString ].
				[ cls reapAny ] on: Error do: [ :e | nil ].
				(Delay forMilliseconds: spacing) wait ] ] ].

restored ifFalse: [
	(Delay forSeconds: 3) wait.
	server stop.
	note value: 'stopped'.

	('p4b-events.log' asFileReference) writeStreamDo: [ :s |
		s setToEnd.
		events do: [ :e | s nextPutAll: e; lf ] ].

	('p4b-result.json' asFileReference) ensureCreateFile; writeStreamDo: [ :s |
		| sorted |
		sorted := stalls asSortedCollection asArray.
		s setToEnd; nextPutAll: (String streamContents: [ :o |
			o nextPutAll: '{"forks":' , stalls size printString.
			o nextPutAll: ',"forkFailures":' , failures printString.
			o nextPutAll: ',"stallMinMs":' , (sorted isEmpty ifTrue: [ 0 ] ifFalse: [ sorted first ]) printString.
			o nextPutAll: ',"stallMedianMs":' , (sorted isEmpty ifTrue: [ 0 ] ifFalse: [ sorted at: ((sorted size // 2 + 1) min: sorted size) ]) printString.
			o nextPutAll: ',"stallP95Ms":' , (sorted isEmpty ifTrue: [ 0 ] ifFalse: [ sorted at: (((sorted size * 95 // 100) max: 1) min: sorted size) ]) printString.
			o nextPutAll: ',"stallMaxMs":' , (sorted isEmpty ifTrue: [ 0 ] ifFalse: [ sorted last ]) printString.
			o nextPutAll: ',"stallOver200ms":' , (stalls count: [ :x | x > 200 ]) printString.
			o nextPutAll: ',"churnIterations":' , (Smalltalk at: #P4bChurn) printString.
			o nextPutAll: ',"forcedFullGCs":' , (Smalltalk at: #P4bGCs) printString.
			o nextPutAll: ',"semaphoreHandoffs":' , (Smalltalk at: #P4bPing) printString.
			o nextPutAll: ',"fileWrites":' , (Smalltalk at: #P4bWrites) printString.
			o nextPutAll: ',"methodsCompiled":' , (Smalltalk at: #P4bCompiles) printString.
			o nextPutAll: ',"requestsStarted":' , (events count: [ :e | e beginsWith: 'start' ]) printString.
			o nextPutAll: ',"requestsFinished":' , (events count: [ :e | e beginsWith: 'end' ]) printString.
			o nextPutAll: '}' ]) ] ].

'p4b done'
