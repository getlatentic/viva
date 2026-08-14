"B7 probe 1, on native ARM64 Squeak -- the control for the Pharo run.

Same shape as smalltalk-p1-snapshot-under-load.st: a green-threaded server under
external load, snapshotting itself mid-traffic. Squeak's WebServer stands in for
Zinc; the load still has to come from outside the image, for the same reason."

| port server events log stamp note snapStart snapEnd inImage |

port := 8961.
log := 'p1s-events.log'.
stamp := [ | n | n := DateAndTime now. (n asUnixTime * 1000) + (n nanoSecond // 1000000) ].
events := OrderedCollection new.
note := [ :line | events add: line , ' ' , stamp value printString ].

server := WebServer new.
server addService: '/work' action: [ :request |
	| id ms |
	id := (request fields at: 'id' ifAbsent: [ '0' ]) asNumber.
	ms := (request fields at: 'ms' ifAbsent: [ '300' ]) asNumber.
	note value: 'start ' , id printString.
	(Delay forMilliseconds: ms) wait.
	note value: 'end ' , id printString.
	request send200Response: 'id=' , id printString ].
server listenOn: port.

(FileStream forceNewFileNamed: log)
	nextPutAll: 'listening ' , stamp value printString; lf; close.

(Delay forSeconds: 8) wait.

note value: 'snapshot-begin'.
snapStart := stamp value.
inImage := Time millisecondClockValue.
Smalltalk snapshot: true andQuit: false.
inImage := Time millisecondClockValue - inImage.
snapEnd := stamp value.
note value: 'snapshot-end'.

(Delay forSeconds: 8) wait.
server destroy.
note value: 'stopped'.

(FileStream fileNamed: log) setToEnd;
	nextPutAll: (String streamContents: [ :s |
		events do: [ :e | s nextPutAll: e; lf ] ]);
	close.

(FileStream forceNewFileNamed: 'p1s-result.json')
	nextPutAll: (String streamContents: [ :s |
		s nextPutAll: '{"snapStartMs":' , snapStart printString.
		s nextPutAll: ',"snapEndMs":' , snapEnd printString.
		s nextPutAll: ',"wallMs":' , (snapEnd - snapStart) printString.
		s nextPutAll: ',"inImageMs":' , inImage printString.
		s nextPutAll: ',"requestsStarted":' , (events count: [ :e | e beginsWith: 'start' ]) printString.
		s nextPutAll: ',"requestsFinished":' , (events count: [ :e | e beginsWith: 'end' ]) printString.
		s nextPutAll: '}' ]);
	close.

Smalltalk snapshot: false andQuit: true.
