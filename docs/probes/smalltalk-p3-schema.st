"B7 probe 3 -- derive a tool schema from a LIVE method, the way vivarium derives
one from a live function.

vivarium's derive.lisp reads four things off the running function:
  argument names   sb-introspect:function-lambda-list
  arity kinds      the lambda list's &optional / &key structure
  argument types   sb-introspect:function-type, which SBCL DERIVES with no
                   declarations written by anyone
  description      the docstring

This asks what the Smalltalk image can hand back for the same four, and what it
costs. The subject method is installed at runtime, because that is the case that
matters: an agent that defines a method has thereby written a tool."

| cls source schema keywordNames sourceNames method typeSelectors |

cls := Object subclass: #ShopProbe.

cls compile: 'orderTotal: lineItems tax: taxRate
	"Total a list of line items and apply a tax rate."
	| subtotal |
	subtotal := lineItems inject: 0 into: [ :sum :each | sum + each ].
	^ subtotal * (1 + taxRate)'.

method := cls >> #orderTotal:tax:.

"1. Names. Two sources, and they do not agree."
keywordNames := method selector keywords collect: [ :k | k allButLast ].
sourceNames := [ method argumentNames ] on: Error do: [ :e | #('<unavailable>') ].

"3. Types. Look for anything in the image that claims to know one."
typeSelectors := (CompiledMethod allSelectors
	select: [ :s | (s asString asLowercase includesSubstring: 'type')
		and: [ (s asString asLowercase includesSubstring: 'prototype') not ] ]) asSortedCollection asArray.

schema := String streamContents: [ :s |
	s nextPutAll: '{'; cr.
	s tab; nextPutAll: '"name": "' , (method selector copyReplaceAll: ':' with: '_') , '",'; cr.
	s tab; nextPutAll: '"description": "' , (method comment ifNil: [ '' ]) , '",'; cr.
	s tab; nextPutAll: '"parameters": {"type": "object", "properties": {'; cr.
	sourceNames doWithIndex: [ :n :i |
		s tab; tab; nextPutAll: '"' , n , '": {"type": null}'.
		i < sourceNames size ifTrue: [ s nextPutAll: ',' ].
		s cr ].
	s tab; nextPutAll: '}, "required": ' , sourceNames printString , '}'; cr.
	s nextPutAll: '}' ].

String streamContents: [ :s |
	s nextPutAll: '=== SUBJECT ==='; cr.
	s nextPutAll: method sourceCode; cr; cr.

	s nextPutAll: '=== 1. ARGUMENT NAMES ==='; cr.
	s nextPutAll: 'selector          : ' , method selector printString; cr.
	s nextPutAll: 'numArgs           : ' , method numArgs printString; cr.
	s nextPutAll: 'selector keywords : ' , keywordNames printString; cr.
	s nextPutAll: 'argumentNames     : ' , sourceNames printString; cr;
	  nextPutAll: '  (argumentNames comes from the SOURCE, not the bytecode)'; cr; cr.

	s nextPutAll: '=== 2. ARITY KINDS ==='; cr.
	s nextPutAll: 'optional args     : none -- Smalltalk has no optional or keyword parameters'; cr.
	s nextPutAll: 'every argument is required and positional; arity is fixed at ' , method numArgs printString; cr; cr.

	s nextPutAll: '=== 3. TYPES ==='; cr.
	s nextPutAll: 'pragmas           : ' , method pragmas printString; cr.
	s nextPutAll: 'literals          : ' , method literals printString; cr.
	s nextPutAll: 'CompiledMethod selectors mentioning "type": ' , typeSelectors printString; cr; cr.

	s nextPutAll: '=== 4. DESCRIPTION ==='; cr.
	s nextPutAll: 'method comment    : ' , method comment printString; cr;
	  nextPutAll: '  (also source-derived: the comment is parsed out of the method body)'; cr; cr.

	s nextPutAll: '=== DERIVED SCHEMA ==='; cr.
	s nextPutAll: schema; cr; cr.

	s nextPutAll: '=== IS THE IMAGE SELF-DESCRIBING? ==='; cr.
	s nextPutAll: 'sourcePointer     : ' , method sourcePointer printString; cr.
	s nextPutAll: 'changes file      : ' , (Smalltalk image changesFile ifNil: [ 'nil' ]
		ifNotNil: [ :f | f fullName , ' (' , f size printString , ' bytes)' ]); cr.
	s nextPutAll: 'sources file      : ' , (Smalltalk image sourcesFile ifNil: [ 'nil' ]
		ifNotNil: [ :f | f fullName ]); cr ]
