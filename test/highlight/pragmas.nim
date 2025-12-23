# Pragma highlighting tests

proc foo() {.inline.} =
# <- keyword.function
  discard

proc bar() {.noSideEffect.} =
# <- keyword.function
  discard

# Export marker
proc exported*() =
# <- keyword.function
  discard
