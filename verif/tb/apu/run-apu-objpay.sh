#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Object-payload store (g6lc_apu_objpay) — directed + seeded-random
# Verilator sim; OBJPAY_SYNTH=1 adds yosys Enable=0/1 screens at a small
# geometry (-GPayWords=512) plus the retained-memory assertion.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
export CVA6_REPO_DIR="$ROOT"
OUT="${APU_OBJPAY_OUT:-/tmp/g6lc-apu-objpay}"
VERILATOR="${VERILATOR:-verilator}"
YOSYS="${YOSYS:-yosys}"
if ! command -v "$VERILATOR" >/dev/null 2>&1 && \
   [ -x /opt/testharness/toolchains/verilator-v5.008/bin/verilator ]; then
  VERILATOR=/opt/testharness/toolchains/verilator-v5.008/bin/verilator
fi
if ! command -v "$YOSYS" >/dev/null 2>&1 && \
   [ -x /opt/testharness/toolchains/formal/bin/yosys ]; then
  YOSYS=/opt/testharness/toolchains/formal/bin/yosys
fi
rm -rf "$OUT"
mkdir -p "$OUT"
# GENUNNAMED does not exist before Verilator 5.016; gate the waiver.
VLTS=("$ROOT/verif/tb/apu/apu_axi.vlt")
vver="$("$VERILATOR" --version | grep -o '[0-9][0-9.]*' | head -1)"
if awk -v v="$vver" 'BEGIN{split(v,a,"."); exit !(a[1]>5||(a[1]==5&&a[2]>=16))}'; then
  VLTS+=("$ROOT/verif/tb/apu/apu_vn.vlt")
fi
if ! "$VERILATOR" --binary --timing --assert -Wall \
  -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-WIDTHEXPAND -Wno-BLKSEQ \
  -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
  "${VLTS[@]}" \
  -f "$ROOT/corev_apu/apu/Flist.apu_objpay" \
  "$ROOT/verif/tb/apu/tb_g6lc_apu_objpay.sv" \
  --top-module tb_g6lc_apu_objpay \
  -Mdir "$OUT/sim" -o tb_g6lc_apu_objpay \
  > "$OUT/build.log" 2>&1; then
  echo "VERILATOR BUILD FAILED"
  tail -n 80 "$OUT/build.log"
  exit 1
fi
echo "VERILATOR BUILD OK"
set +e
stdbuf -o0 -e0 "$OUT/sim/tb_g6lc_apu_objpay" > "$OUT/sim.log" 2>&1
rc=$?
set -e
echo "SIM rc=$rc"
cat "$OUT/sim.log"
if ! grep -q '^PASS tb_g6lc_apu_objpay ' "$OUT/sim.log"; then
  echo "SIM FAILED"
  exit 1
fi
if [ "$rc" -ne 0 ]; then
  echo "SIM rc=$rc despite PASS"
  exit 1
fi
if [ "${OBJPAY_SYNTH:-0}" != 1 ]; then
  exit 0
fi
# Enable=0 at default geometry; Enable=1 at the small screen so the
# allocator logic is visible apart from the payload SRAM.
for en in 0 1; do
  gp=""
  if [ "$en" = 1 ]; then gp="-GPayWords=512"; fi
  yp="read_slang -f $ROOT/corev_apu/apu/Flist.apu_objpay --top g6lc_apu_objpay_fixture -GEnable=$en $gp; hierarchy -top g6lc_apu_objpay_fixture; flatten; proc; opt; memory_collect; check -assert; stat; synth -top g6lc_apu_objpay_fixture -noabc; check -assert; stat; select -assert-none t:\$dlatch t:\$_DLATCH_*"
  if ! "$YOSYS" -Q -T -p "$yp" > "$OUT/synth-$en.log" 2>&1; then
    echo "SYNTH FAILED Enable=$en"
    tail -n 40 "$OUT/synth-$en.log"
    exit 1
  fi
  echo "SYNTH OK Enable=$en"
done
python3 - "$OUT" <<'PY'
import re, sys, pathlib
out = pathlib.Path(sys.argv[1])
ok = True
for en in (0, 1):
    text = pathlib.Path(f"{out}/synth-{en}.log").read_text(errors="replace")
    stats = re.split(r"\d+\. Printing statistics\.", text)
    memblk = stats[1] if len(stats) > 2 else ""
    gate = stats[-1]
    mem = re.findall(r"^\s+(\d+)\s+(\$mem\S*)", memblk, re.M)
    mem_n = sum(int(n) for n, _ in mem)
    cells = re.search(r"Number of cells:\s+(\d+)", gate) or \
            re.search(r"^\s+(\d+) cells\b", gate, re.M)
    ffs = sum(int(n) for n, _ in re.findall(r"^\s+(\d+)\s+(\$_DFF\w*)", gate, re.M))
    probs = re.findall(r"Found and reported (\d+) problems\.", text)
    need = 1 if en == 1 else 0
    tag = "OK" if mem_n == need else "FAIL"
    if mem_n != need:
        ok = False
    print(f"SYNTH Enable={en} cells={cells.group(1) if cells else '?'} "
          f"ffs={ffs} problems={','.join(probs) or '0'} latch=none "
          f"retained_mem={mem_n} ({';'.join(f'{n} {k}' for n,k in mem) or 'none'}) {tag}")
print("RETAINED_MEM_ASSERT " + ("PASS" if ok else "FAIL"))
sys.exit(0 if ok else 1)
PY
echo "OBJPAY_SUMMARY_DONE"
