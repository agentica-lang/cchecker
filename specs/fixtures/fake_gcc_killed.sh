#!/bin/sh
# A gcc whose cc1 is killed after the analyzer printed an error that -Werror made: gcc prints "Killed" and exits 1,
# and not the line that ends a run with promoted warnings.
file=""
for arg in "$@"; do
  case "$arg" in *.c) file="$arg" ;; esac
done
echo "$file:1:1: error: leak of 'p' [CWE-401] [-Werror=analyzer-malloc-leak]" >&2
echo "gcc: Killed" >&2
exit 1
