#!/bin/sh
# A gcc that finds a leak and then dies, as cc1 does when the OOM killer takes it.
echo "clean.c:1:1: warning: leak of 'p' [CWE-401] [-Wanalyzer-malloc-leak]" >&2
echo "gcc: fatal error: Killed signal terminated program cc1" >&2
echo "compilation terminated." >&2
exit 4
