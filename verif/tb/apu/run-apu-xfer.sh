#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Xfer engine (g6lc_apu_xfer: vkCmdCopyBuffer/FillBuffer/UpdateBuffer
# through the checked DMA pair, §12.3 C/5a) — Verilator sim;
# XFER_SYNTH=1 adds the yosys Enable=0/1 screens.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
export CVA6_REPO_DIR="$ROOT"
OUT="${APU_XFER_OUT:-/tmp/g6lc-apu-xfer}"
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
  -f "$ROOT/corev_apu/apu/Flist.apu_xfer" \
  "$ROOT/verif/tb/apu/tb_g6lc_apu_xfer.sv" \
  --top-module tb_g6lc_apu_xfer \
  -Mdir "$OUT/sim" -o tb_g6lc_apu_xfer \
  > "$OUT/build.log" 2>&1; then
  echo "VERILATOR BUILD FAILED"
  tail -n 80 "$OUT/build.log"
  exit 1
fi
echo "VERILATOR BUILD OK"
set +e
(cd "$ROOT/verif/tb/apu" && stdbuf -o0 -e0 "$OUT/sim/tb_g6lc_apu_xfer") \
  > "$OUT/sim.log" 2>&1
rc=$?
set -e
echo "SIM rc=$rc"
cat "$OUT/sim.log"
if ! grep -q '^PASS tb_g6lc_apu_xfer ' "$OUT/sim.log"; then
  echo "SIM FAILED"
  exit 1
fi
if [ "$rc" -ne 0 ]; then
  echo "SIM rc=$rc despite PASS"
  exit 1
fi
if [ "${XFER_SYNTH:-0}" != 1 ]; then
  exit 0
fi
for en in 0 1; do
  yp="read_slang -f $ROOT/corev_apu/apu/Flist.apu_xfer --top g6lc_apu_xfer_fixture -GEnable=$en; hierarchy -top g6lc_apu_xfer_fixture; flatten; proc; opt; memory_collect; check -assert; stat; synth -top g6lc_apu_xfer_fixture -noabc; check -assert; stat; select -assert-none t:\$dlatch t:\$_DLATCH_*"
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
for en in (0, 1):
    text = pathlib.Path(f"{out}/synth-{en}.log").read_text(errors="replace")
    stats = re.split(r"\d+\. Printing statistics\.", text)
    memblk = stats[1] if len(stats) > 2 else ""
    gate = stats[-1]
    mem = re.findall(r"^\s+(\d+)\s+(\$mem\S*)", memblk, re.M)
    mem_n = sum(int(n) for n, _ in mem)
    cells = re.search(r"Number of cells:\s+(\d+)", gate) or \
            re.search(r"^\s+(\d+) cells\b", gate, re.M)
    ffs = sum(int(n) for n, _ in
              re.findall(r"^\s+(\d+)\s+(\$_DFF\w*)", gate, re.M))
    probs = re.findall(r"Found and reported (\d+) problems\.", text)
    print(f"SYNTH Enable={en} cells={cells.group(1) if cells else '?'} "
          f"ffs={ffs} problems={','.join(probs) or '0'} latch=none "
          f"retained_mem={mem_n} "
          f"({';'.join(f'{n} {k}' for n, k in mem) or 'none'})")
print("XFER_SUMMARY_DONE")
PY
