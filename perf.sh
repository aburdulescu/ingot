#!/bin/sh

set -xe

rm -f *.perf *.ruse
rm -f opt.ingot opt.tar

perf stat -r5 -e instructions,cycles,cache-references,cache-misses,branches,branch-misses ./tar.sh 1>/dev/null 2>tar.perf
perf stat -r5 -e instructions,cycles,cache-references,cache-misses,branches,branch-misses ./ingot.sh 1>/dev/null 2>ingot.perf

perf stat -r5 -e instructions,cycles,cache-references,cache-misses,branches,branch-misses --all-user ./tar.sh 1>/dev/null 2>tar.user.perf
perf stat -r5 -e instructions,cycles,cache-references,cache-misses,branches,branch-misses --all-user ./ingot.sh 1>/dev/null 2>ingot.user.perf

ruse ./tar.sh 1>/dev/null 2>tar.ruse
ruse ./ingot.sh 1>/dev/null 2>ingot.ruse

diff -y tar.perf ingot.perf | colordiff
diff -y tar.user.perf ingot.user.perf | colordiff
diff -y tar.ruse ingot.ruse | colordiff
