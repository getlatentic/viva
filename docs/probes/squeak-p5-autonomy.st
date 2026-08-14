"B7 probe 5 -- does the image assume a human is sitting in it?

The author-initials hang found in M2 is not really about author initials. It is
evidence that a Smalltalk development image blurs application, runtime, IDE and
user in a way that is wonderful interactively and hostile to an autonomous agent:
the runtime decides human input is required, puts up a modal dialog, and the agent
hangs forever with no exception to catch and nothing to log.

The criterion is not 'does it support headless'. It is: EVERY RUNTIME FAILURE MUST
BECOME DATA OR CONTROL FLOW THE AGENT CAN REACH. So each operation below is
classified as one of

  OK      completed, agent carries on
  RAISED  signalled an exception the agent caught -- also fine, it is data
  BLOCKED never returned -- the runtime is waiting for a human

BLOCKED is detected from outside, by the driver's watchdog, because from inside
the image there is by definition nothing left to run.

Reads the index of the first operation to attempt from p5-start.txt, so the driver
can restart past whatever blocked and keep auditing."

| f log ops start outcome record cls |

log := 'p5-log.txt'.
record := [ :name :verdict |
	(FileStream fileNamed: log) setToEnd; nextPutAll: name , ' = ' , verdict; lf; close ].

start := [ ((FileStream fileNamed: 'p5-start.txt') contentsOfEntireFile asString asInteger)
	ifNil: [ 0 ] ] on: Error do: [ :e | 0 ].

ops := OrderedCollection new.

"Each round runs a fresh image, so an operation that needs the probe class makes
 it rather than depending on an earlier round having survived."
cls := [ Object subclass: #P5Probe
		instanceVariableNames: ''
		classVariableNames: ''
		poolDictionaries: ''
		category: 'B7P5' ].

ops add: 'createClass' -> [ cls value. 'OK' ].

"Attempted with the image exactly as it ships -- no author set. Separating this
 from the compiles below is the point: one hazard is the identity prompt, the
 other would be the compiler's own dialogs."
ops add: 'compileValidMethod_noAuthorSet' -> [
	cls value compile: 'foo ^ 1'.
	'OK' ].

ops add: 'setAuthorInitials' -> [
	Utilities authorInitials: 'B7'.
	'OK' ].

ops add: 'compileValidMethod_authorSet' -> [
	Utilities authorInitials: 'B7'.
	cls value compile: 'foo ^ 1'.
	'OK' ].

ops add: 'compileMalformedMethod' -> [
	Utilities authorInitials: 'B7'.
	cls value compile: 'foo ^ 1 +'.
	'OK (accepted silently)' ].

ops add: 'compileReferencingUndeclared' -> [
	Utilities authorInitials: 'B7'.
	cls value compile: 'bar ^ zorkUndeclared + 1'.
	'OK' ].

ops add: 'renameClass' -> [
	Utilities authorInitials: 'B7'.
	cls value rename: 'P5Renamed'.
	'OK' ].

ops add: 'changeSuperclass' -> [
	OrderedCollection subclass: #P5Renamed
		instanceVariableNames: ''
		classVariableNames: ''
		poolDictionaries: ''
		category: 'B7P5'.
	'OK' ].

ops add: 'removeClass' -> [
	(Smalltalk at: #P5Renamed) removeFromSystem.
	'OK' ].

ops add: 'unhandledExceptionInForkedProcess' -> [
	[ Error signal: 'B7 deliberate' ] fork.
	(Delay forSeconds: 3) wait.
	'OK (main process still scheduling)' ].

ops add: 'haltInForkedProcess' -> [
	[ Object new halt ] fork.
	(Delay forSeconds: 3) wait.
	'OK (main process still scheduling)' ].

ops add: 'evaluateUndeclaredVariable' -> [
	Compiler evaluate: 'zorkAlsoUndeclared + 1'.
	'OK' ].

ops add: 'connectToClosedPort' -> [
	| sock |
	sock := Socket newTCP.
	sock connectTo: (NetNameResolver addressFromString: '127.0.0.1') port: 9.
	(Delay forSeconds: 2) wait.
	sock destroy.
	'OK (no dialog)' ].

ops add: 'bindPortTwice' -> [
	| a b |
	a := Socket newTCP.
	a listenOn: 8977 backlogSize: 4.
	b := Socket newTCP.
	b listenOn: 8977 backlogSize: 4.
	a destroy. b destroy.
	'OK (no dialog)' ].

ops add: 'hugeAllocation' -> [
	| big |
	big := Array new: 400000000.
	big size printString , ' allocated' ].

start to: ops size - 1 do: [ :i |
	| pair |
	pair := ops at: i + 1.
	record value: pair key value: 'ATTEMPTING'.
	outcome := [ pair value value ]
		on: Error
		do: [ :e | 'RAISED ' , e class name , ' ' , (e messageText ifNil: [ '' ]) ].
	record value: pair key value: outcome printString ].

record value: 'SUITE' value: 'FINISHED'.
Smalltalk snapshot: false andQuit: true.
