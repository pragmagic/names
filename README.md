# names

This module implements `Name` type, which is an interned string, allowing
fast comparison and hash retrieval.

Consider using this type when:
1) You would like to use `string` as a key of a hash table.
2) Many equal strings can be created in different parts of your application.

API:
```nim
type Name* = ref object
  ## Represents an interned string allowing fast equality and hash operations.

proc toName*(s: string): Name
  ## Converts the ``string`` to ``Name``.
  ## Returns ``nil`` if ``s`` is ``nil``.

proc toName*(s: cstring): Name
  ## Converts the null-terminated ``cstring`` to ``Name``.
  ## Returns ``nil`` if ``s`` is ``nil``.

proc toExistingName*(s: string): Name
  ## Returns ``Name`` corresponding to the string, but only if the name
  ## is already registered. Otherwise returns ``nil``.
  ## This is useful when you don't want to pollute the name table with
  ## unverified user input.

proc toExistingName*(s: cstring): Name
  ## Returns ``Name`` corresponding to the string, but only if the name
  ## is already registered. Otherwise returns ``nil``.
  ## This is useful when you don't want to pollute the name table with
  ## unverified user input.

proc isValid*(name: Name): bool
  ## Returns ``true`` if the ``name`` is initialized, ``false`` otherwise.
  ## A name returned from ``toName`` call with a non-nil argument is always
  ## valid.

proc `==`*(n1, n2: Name): bool
  ## Returns ``true`` if the names are equal, ``false`` otherwise.

proc hash*(name: Name): Hash
  ## Returns hash of the ``name``. The hash may not be equal to the hash
  ## of the string the name represents.

proc cmp*(n1, n2: Name): int
  ## Returns 0 if the names are equal, a value < 0 if n1 < n2, and
  ## a value > 0 otherwise.
  ## The comparison is lexicographic.

proc `<`*(n1, n2: Name): bool
  ## Returns ``true`` if ``n1`` < ``n2``, ``false`` otherwise.
  ## The comparison is lexicographic.

template `$`*(name: Name): string
  ## Returns string representation of the ``name`` or ``nil``, if
  ## the ``name`` is not valid.
  ## Implemented as a template to avoid redundant string copies - the
  ## underlying string is always immutable, so it gets copied only if you
  ## assign the result to a mutable (``var``) variable.
```

## License

This library is licensed under the MIT license.
Read [LICENSE](LICENSE) file for details.

Copyright (c) 2018 Xored Software, Inc.
