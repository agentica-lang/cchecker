#!/bin/sh
# A gcc that prints more than cchecker keeps (1 MiB), so the run is an error of the tool and not an outcome.
head -c 2000000 /dev/zero | tr '\0' 'x'
echo
