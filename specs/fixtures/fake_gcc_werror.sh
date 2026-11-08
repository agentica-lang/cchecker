#!/bin/sh
# A gcc that ran to the end with an analyzer warning that -Werror made an error.
file=""
for arg in "$@"; do
  case "$arg" in *.c) file="$arg" ;; esac
done
echo "$file:1:1: error: leak of 'p' [CWE-401] [-Werror=analyzer-malloc-leak]" >&2
echo "cc1: some warnings being treated as errors" >&2
exit 1
