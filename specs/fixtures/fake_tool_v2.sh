#!/bin/sh
# A gcc or clang-tidy at version 2: it names its version and finds nothing. Same as fake_tool_v1.sh with another version.
if [ "$1" = "--version" ]; then
  echo "fake tool 2.0.0"
  echo "a second line, which cchecker leaves out"
fi
