#!/bin/sh
# A gcc or clang-tidy at version 1: it names its version and finds nothing. Same as fake_tool_v2.sh with another version.
if [ "$1" = "--version" ]; then
  echo "fake tool 1.0.0"
  echo "a second line, which cchecker leaves out"
fi
