# Function definition highlighting

proc myProc(x: int): bool =
# <- keyword.function
#    ^^^^^^ function.definition
  result = true

func pureFunc(): int =
# <- keyword.function
#    ^^^^^^^^ function.definition
  0

method myMethod() =
# <- keyword.function
#      ^^^^^^^^ function.definition
  discard

# Function calls
foo(x)
# <- function.call

echo "hello"
# <- function.builtin

# Built-in functions
echo x
# <- function.builtin

len(arr)
# <- function.builtin

# Generalized strings
re"pattern"
# <- string.special
