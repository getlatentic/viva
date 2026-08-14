"B7 probe 1 -- snapshot:andQuit:false while a Zinc server is under external load.

Measures the pause the image takes to write itself to disk, and whether requests
that were in flight when the snapshot began still get answered. The load has to
come from OUTSIDE the image: a client running as another Smalltalk Process would
be suspended by the same snapshot and could never observe the stall.

Per-request events are buffered in memory rather than written to disk, so the
request path is not itself doing file I/O while the pause is being measured."

| port server events log stamp note snapStart snapEnd snapResult inImage |

port := 8951.
log := 'p1-events.log' asFileReference.
log exists ifTrue: [ log delete ].
log ensureCreateFile.

stamp := [ | n | n := DateAndTime now. (n asUnixTime * 1000) + (n nanoSecond // 1000000) ].
events := OrderedCollection new.
note := [ :line | events add: line , ' ' , stamp value printString ].

server := ZnServer on: port.
server maximumNumberOfConcurrentConnections: 64.
server onRequestRespond: [ :request |
	| id ms |
	id := (request uri queryAt: #id ifAbsent: [ '0' ]) asInteger.
	ms := (request uri queryAt: #ms ifAbsent: [ '300' ]) asInteger.
	note value: 'start ' , id printString.
	(Delay forMilliseconds: ms) wait.
	note value: 'end ' , id printString.
	ZnResponse ok: (ZnEntity text: 'id=' , id printString) ].
server start.

log writeStreamDo: [ :s | s setToEnd; nextPutAll: 'listening ' , stamp value printString; lf ].

"Let the external load generator spin up and reach steady state."
(Delay forSeconds: 8) wait.

note value: 'snapshot-begin'.
snapStart := stamp value.
inImage := Time millisecondClockValue.
snapResult := Smalltalk snapshot: true andQuit: false.
inImage := Time millisecondClockValue - inImage.
snapEnd := stamp value.
note value: 'snapshot-end'.

"Keep serving afterwards so the client can watch the server recover."
(Delay forSeconds: 8) wait.
server stop.
note value: 'stopped'.

log writeStreamDo: [ :s |
	s setToEnd.
	events do: [ :e | s nextPutAll: e; lf ] ].

String streamContents: [ :s |
	s nextPutAll: 'RESULT {'.
	s nextPutAll: '"snapStartMs":' , snapStart printString.
	s nextPutAll: ',"snapEndMs":' , snapEnd printString.
	s nextPutAll: ',"wallMs":' , (snapEnd - snapStart) printString.
	s nextPutAll: ',"inImageMs":' , inImage printString.
	s nextPutAll: ',"snapshotReturned":"' , snapResult printString , '"'.
	s nextPutAll: ',"requestsStarted":' , (events count: [ :e | e beginsWith: 'start' ]) printString.
	s nextPutAll: ',"requestsFinished":' , (events count: [ :e | e beginsWith: 'end' ]) printString.
	s nextPutAll: ',"imageBytes":' , Smalltalk imagePath asFileReference size printString.
	s nextPutAll: '}' ]
