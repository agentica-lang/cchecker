#!/bin/sh
# A tool that ends well only when cchecker runs it with the C locale, so that the messages (and a baseline) do not
# change from one machine to the next.
if [ "$LC_ALL" != "C" ]; then
  echo "LC_ALL is '$LC_ALL'" >&2
  exit 3
fi
