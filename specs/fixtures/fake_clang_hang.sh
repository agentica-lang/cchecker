#!/bin/sh
# A clang that never ends and leaves a child behind, as gcc does with cc1. The scenario reads the pid of the child.
mkdir -p scratch
sleep 27 &
echo $! > scratch/clang_hang.pid
wait
