#!/bin/sh
# A gcc that finds nothing and adds a line to runs.log in its folder for each file it is run on, to count the runs.
[ "$1" = "--version" ] && exit 0
echo ran >> runs.log
