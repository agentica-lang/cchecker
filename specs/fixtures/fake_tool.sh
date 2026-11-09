#!/bin/sh
# A gcc or clang-tidy that finds nothing. What `--version` does depends on the name it is run by (the others are links
# to this file): fake_tool_vN.sh prints "fake tool N.0.0" and a second line, fake_tool_vN_other.sh the same number in
# another text (another build of the version), fake_tool_no_version.sh prints nothing, fake_tool_version_fails.sh
# exits 1.
if [ "$1" = "--version" ]; then
  name=$(basename "$0" .sh)
  case "$name" in
    fake_tool_version_fails) exit 1 ;;
    fake_tool_v*_other)
      number=${name#fake_tool_v}
      echo "another build of fake tool ${number%_other}.0.0"
      ;;
    fake_tool_v*)
      echo "fake tool ${name#fake_tool_v}.0.0"
      echo "a second line, which cchecker leaves out"
      ;;
  esac
fi
