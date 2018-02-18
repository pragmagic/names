# Copyright 2018 Xored Software Inc.

## This module implements ``Name`` type, which is an interned string, allowing
## fast comparison and hash retrieval. It also reduces the amount of memory
## used if there are many equal names created during the application lifetime.
##
## Consider using this type when:
## 1) You would like to use ``string`` as a key of a hash table.
## 2) Many equal strings can be created in different parts of your application.

import hashes

type
  NameTableElement = object
    val*: string
      # This is public for now for ``template $`` to work within other
      # templates. Will be made private after Nim bug is fixed:
      # https://github.com/nim-lang/Nim/issues/3770
    idx: int
    refcount: int
    next: ptr NameTableElement
    prev: ptr NameTableElement

  Name* = ref object
    ## Represents an interned string allowing fast equality and hash operations.
    element*: ptr NameTableElement
      # This is public for now for ``template $`` to work within other
      # templates. Will be made private after Nim bug is fixed:
      # https://github.com/nim-lang/Nim/issues/3770

var nameTable {.threadvar.}: ptr ptr NameTableElement
var nameTableMask {.threadvar.}: int
var nameCount {.threadvar.}: int

const initialNameTableCapacity = 4096
const loadFactor = 0.75

proc offset[T](p: ptr T, offset: int): ptr T {.inline.} =
  cast[ptr T](cast[ByteAddress](p) +% (offset * sizeof(T)))

# Has to be forward-declared, because otherwise deepCopy has to be moved
# below it, but then it doesn't work anymore, because `toName` calls `new`.
proc toName*(s: cstring): Name {.inline.}

proc nameFinalizer(name: Name) =
  let element = name.element
  if element.isNil: return
  assert(element[].refcount > 0)
  dec element[].refcount
  if element[].refcount == 0:
    if not element[].prev.isNil:
      element[].prev.next = element[].next
    else:
      nameTable.offset(element[].idx)[] = element[].next
    if not element[].next.isNil:
      element[].next.prev = element[].prev

    GC_unref(element[].val)
    dealloc(element)
    dec nameCount
    assert nameCount >= 0
    if nameCount == 0:
      # ensures clean exit
      dealloc(nameTable)
      nameTable = nil

proc addToTable(table: ptr ptr NameTableElement, elem: ptr NameTableElement,
                idx: int) {.inline.} =
  elem[].idx = idx
  let tablePtr = table.offset(idx)
  elem[].prev = nil
  if not tablePtr[].isNil:
    elem[].next = tablePtr[]
    tablePtr[].prev = elem
  else:
    elem[].next = nil
  tablePtr[] = elem

proc rehash() =
  let newMask = nameTableMask * 2 + 1
  let newTable = cast[type(nameTable)](
                          alloc0((newMask + 1) * sizeof(nameTable[])))
  for i in 0..nameTableMask:
    var elem = nameTable.offset(i)[]
    while not elem.isNil:
      let h = elem[].val.hash()
      let elemCopy = elem
      elem = elem[].next
      addToTable(newTable, elemCopy, h and newMask)
  dealloc(nameTable)
  nameTable = newTable
  nameTableMask = newMask

proc `=deepCopy`(name: Name): Name =
  ## Ensures correct copying of name when using deepCopy or sending the name
  ## via channel to another thread.
  if name.isNil: return nil
  if name.element.isNil:
    new(result)
    result.element = nil
  else:
    let idx = name.element[].idx
    if idx <= nameTableMask and not nameTable.isNil:
      var leftmost = name.element
      while not leftmost.prev.isNil:
        leftmost = leftmost.prev
      if nameTable.offset(idx)[] == leftmost:
        # Copy is performed on the same thread. Just return the name - it's
        # immutable and doesn't need to be copied.
        return name
    # use cstring as it seems safer when moving to another thread
    result = toName(name.element[].val.cstring)

proc toName[T:string|cstring](s: T, existingOnly: bool): Name =
  if s.isNil: return nil
  if nameTable.isNil:
    nameTable = cast[type(nameTable)](
                        alloc0(initialNameTableCapacity * sizeof(nameTable[])))
    nameTableMask = initialNameTableCapacity - 1
    nameCount = 0
  let h = s.hash()
  var elem = nameTable.offset(h and nameTableMask)[]
  while not elem.isNil and elem[].val != s:
    elem = elem.next
  if elem.isNil and not existingOnly:
    if unlikely((nameCount + 1) > int(loadFactor * (nameTableMask + 1).float)) and
       likely(nameTableMask < (high(int) shr 1)):
      rehash()
    elem = cast[type(elem)](alloc0(sizeof(elem[])))
    addToTable(nameTable, elem, h and nameTableMask)
    elem[].val = $s
    GC_ref(elem[].val)
    inc nameCount
  if not elem.isNil:
    inc elem[].refcount
    new(result, nameFinalizer)
    result.element = elem

proc toName*(s: string): Name {.inline.} =
  ## Converts the ``string`` to ``Name``.
  ## Returns ``nil`` if ``s`` is ``nil``.
  toName(s, existingOnly = false)

proc toName*(s: cstring): Name {.inline.} =
  ## Converts the null-terminated ``cstring`` to ``Name``.
  ## Returns ``nil`` if ``s`` is ``nil``.
  toName(s, existingOnly = false)

proc toExistingName*(s: string): Name {.inline.} =
  ## Returns ``Name`` corresponding to the string, but only if the name
  ## is already registered. Otherwise returns ``nil``.
  ## This is useful when you don't want to pollute the name table with
  ## unverified user input.
  toName(s, existingOnly = true)

proc toExistingName*(s: cstring): Name {.inline.} =
  ## Returns ``Name`` corresponding to the string, but only if the name
  ## is already registered. Otherwise returns ``nil``.
  ## This is useful when you don't want to pollute the name table with
  ## unverified user input.
  toName(s, existingOnly = true)

proc isValid*(name: Name): bool {.inline.} =
  ## Returns ``true`` if the ``name`` is initialized, ``false`` otherwise.
  not name.isNil and not name.element.isNil

proc `==`*(n1, n2: Name): bool {.inline.} =
  ## Returns ``true`` if the names are equal, ``false`` otherwise.
  if n1.isNil != n2.isNil: return false
  if n1.isNil: return true
  n1.element == n2.element

proc cmp*(n1, n2: Name): int {.procvar.} =
  ## Returns 0 if the names are equal, a value < 0 if n1 < n2, and
  ## a value > 0 otherwise.
  ## The comparison is lexicographic.
  if n1 == n2: return 0
  if not n1.isValid:
    return -1
  if not n2.isValid:
    return 1
  result = system.cmp(n1.element[].val, n2.element[].val)

proc `<`*(n1, n2: Name): bool {.inline.} =
  ## Returns ``true`` if ``n1`` < ``n2``, ``false`` otherwise.
  ## The comparison is lexicographic.
  cmp(n1, n2) < 0

proc hash*(name: Name): Hash {.inline.} =
  ## Returns hash of the ``name``. The hash may not be equal to the hash
  ## of the string the name represents.
  result = if name.isNil: 0
           else: cast[Hash](name.element)

template `$`*(name: Name): string =
  ## Returns string representation of the ``name`` or ``nil``, if
  ## the ``name`` is not valid.
  ## Implemented as a template to avoid redundant string copies - the
  ## underlying string is always immutable, so it gets copied only if you
  ## assign the result to a mutable (``var``) variable.
  if not name.isValid:
    nil
  else:
    name.element[].val

when isMainModule:
  import strutils

  proc test() =
    let firstPart = "Some"
    let secondPart = "Name"

    let n1 = toName(cstring"SomeName")
    let n2 = toName("SomeName")
    let n3 = toName(firstPart & secondPart)

    var preservedNames = newSeq[Name]()
    proc ensureRehash() =
      let prevMask = nameTableMask
      for i in 1..prevMask:
        preservedNames.add(toName("a".repeat(i)))
      assert nameTableMask == prevMask * 2 + 1
      for i in 1..prevMask:
        assert toName("a".repeat(i)) == preservedNames[i - 1]
        assert toExistingName("a".repeat(i)) == preservedNames[i - 1]

    template doTest(firstTime) =
      assert(n1.isValid)
      assert(n2.isValid)
      assert(n3.isValid)

      assert(n1 == n2)
      assert(n1 == n3)
      assert(n2 == n3)

      assert(n1.hash() == n2.hash())
      assert(n1.hash() == n3.hash())
      assert(n2.hash() == n3.hash())

      assert(cmp(n1, n2) == 0)
      assert(cmp(n1, n3) == 0)
      assert(cmp(n2, n3) == 0)

      assert($n1 == "SomeName")
      assert($n2 == "SomeName")
      assert($n3 == "SomeName")
      assert(n1.element.refcount == 3)

      when firstTime:
        assert(nameCount == 1)

      let a = toName("A")
      when firstTime:
        assert(a.element.refcount == 1)
      assert(a < n1)
      assert(cmp(a, n1) < 0)
      assert(cmp(n1, a) > 0)

      when firstTime:
        assert(nameCount == 2)

    doTest(firstTime = true)
    ensureRehash()
    doTest(firstTime = false)

    var uninitialized: Name
    assert(not uninitialized.isValid)
    assert(not Name().isValid)
    assert(Name().element.isNil)

    assert(toName(cstring(nil)).isNil)
    assert(toName(string(nil)).isNil)

    assert(toExistingName("SomeName") == n1)
    assert(toExistingName("NotExisting").isNil)

    var newName: Name
    deepCopy(newName, n1)
    assert(newName == n1)

    # ensures GC frees these on fullCollect
    preservedNames.setLen(0)
    preservedNames = nil

  test()
  GC_fullCollect()
  assert(nameCount == 0)
  assert(nameTable.isNil)
