#!/bin/sh
# A gcc that fails when another one runs at the same time, to show that --jobs bounds the runs.
mkdir -p scratch
mkdir scratch/serial.lock 2>/dev/null || { echo "another run is in progress" >&2; exit 9; }
sleep 1
rmdir scratch/serial.lock
