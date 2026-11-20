#!/bin/bash
# Prereq check + launch simperf_bench on baseline and dev hyp8 models.
set -u
TH=/opt/testharness
BENCH_REPO=$TH/verif/regress/remote/simperf_bench.sh
BENCH=/tmp/simperf_bench.sh
[ -f "$BENCH_REPO" ] || cp /tmp/simperf_bench.sh "$BENCH" 2>/dev/null || true
VG=$TH/toolchains/valgrind/bin
S11=$TH/runs/ooocoh-t21i-ooo-s11/output/ooo_fp_ooo.elf
WPRP=$TH/runs/ooocoh-t21i-ooo-wprp/output/negative0/directed.elf
B=$TH/runs/hyp8-rfix131a-phantomprobe-aggregate-t2/output/model
D=$TH/runs/devcase-ab/model

echo "=== prereqs ==="
for f in "$VG/valgrind" "$S11" "$WPRP" "$B/Variane_testharness" "$D/Variane_testharness" "$BENCH_REPO"; do
  if [ -e "$f" ]; then echo "OK       $f"; else echo "MISSING  $f"; fi
done
ls "$B"/*__stats.txt "$D"/*__stats.txt 2>/dev/null

# ensure bench script exists locally too
if [ ! -f "$BENCH" ]; then cp "$BENCH_REPO" "$BENCH"; fi
chmod +x "$BENCH"

echo "=== launching benches ==="
rm -rf /tmp/simperf-base /tmp/simperf-dev
nohup bash "$BENCH" "$B" /tmp/simperf-base > /tmp/simperf-base.log 2>&1 &
echo "base pid $!"
nohup bash "$BENCH" "$D" /tmp/simperf-dev  > /tmp/simperf-dev.log  2>&1 &
echo "dev  pid $!"
echo "LAUNCHED"
