#!/bin/sh
# Times `--tools rules` of cchecker on the C VM of Agentica at a pinned commit, and prints the wall time and the peak
# RSS. Usage: bench/run.sh COMMIT [JOBS], from the root of the repository (`make bench` passes AGENTICA_BENCH_COMMIT
# and BENCH_JOBS); JOBS defaults to cchecker's own default, the number of cores.
#
# It fetches Agentica into _build/bench/agentica (ignored): that commit only, with only the submodules whose headers
# the VM reads in its default Linux build (yyjson, libuv, picohttpparser, libffi), each at depth 1. libgc, OpenSSL and
# zlib are the system's, as in that build (Debian: libgc-dev libssl-dev zlib1g-dev pkg-config). Agentica's own
# Makefile gives the compile flags of its release build and generates the headers of libffi. It needs git, make,
# agentica, clang and GNU time (/usr/bin/time). The compile database and the report go under _build/bench/.
set -eu

commit=$1
jobs=${2:-}
root=$(pwd)
out=$root/_build/bench
vm=$out/agentica
submodules="vm/third_party/yyjson vm/third_party/libuv vm/third_party/picohttpparser vm/third_party/libffi"

if [ ! -d "$vm/.git" ]; then
  mkdir -p "$vm"
  git -C "$vm" init -q
  git -C "$vm" remote add origin https://github.com/agentica-lang/agentica.git
fi
if [ "$(git -C "$vm" rev-parse -q --verify HEAD 2>/dev/null || true)" != "$commit" ]; then
  git -C "$vm" fetch -q --depth 1 origin "$commit"
  git -C "$vm" checkout -q --force "$commit"
fi
# shellcheck disable=SC2086 # the list of paths is split on purpose
git -C "$vm" submodule update -q --init --depth 1 --force $submodules

# The flags as agentica's Makefile writes them, shell quoted, and the headers of libffi that it generates.
make -s -C "$vm" --eval 'bench-headers: $(FFI_HEADERS)' bench-headers < /dev/null
flags=$(make -s -C "$vm" --eval "bench-flags: ; @printf '%s\n' '\$(subst ','\\'',\$(VM_CFLAGS))'" bench-flags < /dev/null)
# The annotations of the bench (marks.h) come in with -include, as a project would write them in its own headers.
flags="$flags -I $root/include -include $root/bench/marks.h"

mkdir -p "$out"
(cd "$vm" && ls vm/*.c) | grep -v '^vm/fuzz' | awk -v dir="$vm" -v flags="$flags" '
  function quote(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return "\"" s "\"" }
  BEGIN { print "[" }
  {
    if (NR > 1) print ","
    printf "{\"directory\": %s, \"file\": %s, \"command\": %s}", quote(dir), quote($0), quote("cc " flags " -c " $0)
  }
  END { print "\n]" }
' > "$out/compile_commands.json"

agentica compile "$root/cchecker.agc" -o "$out/cchecker.agcb" < /dev/null
files=$(grep -c '"file"' "$out/compile_commands.json")
echo "bench: $files files of agentica $(cat "$vm/VERSION") ($commit), -j ${jobs:-cores}"
status=0
cd "$vm"
/usr/bin/time -o "$out/time.txt" -f "%e s, peak RSS %M KB" agentica run -- "$out/cchecker.agcb" --tools rules \
  ${jobs:+-j "$jobs"} --json -p "$out/compile_commands.json" < /dev/null > "$out/report.json" || status=$?
# 1 is new findings, which the VM has: only 2 is a failure of the run.
if [ "$status" -gt 1 ]; then
  echo "bench: cchecker failed ($status); see $out/report.json" >&2
  exit "$status"
fi
# A file that was not checked would make the numbers smaller than they are.
if ! grep -q '"unchecked_files":\[\]' "$out/report.json"; then
  echo "bench: some files were not checked (unchecked_files of $out/report.json)" >&2
  exit 2
fi
echo "bench: $(tail -n 1 "$out/time.txt")"
