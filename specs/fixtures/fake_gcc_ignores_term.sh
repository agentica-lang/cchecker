#!/bin/sh
# A gcc that ignores SIGTERM, with a child that ignores it too: only SIGKILL stops them.
trap '' TERM
mkdir -p scratch
sleep 27 &
echo $! > scratch/ignores_term.pid
wait
