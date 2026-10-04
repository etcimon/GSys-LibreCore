#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Venus/Vulkan reply builder (g6lc_apu_vnrep + g6lc_apu_vndec
# integration) — Verilator sim vs generated reply vectors;
# VNREP_SYNTH=1 adds the yosys Enable=0/1 screens.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
export CVA6_REPO_DIR="$ROOT"
OUT="${APU_VNREP_OUT:-/tmp/g6lc-apu-vnrep}"
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
  -f "$ROOT/corev_apu/apu/Flist.apu_vnrep" \
  "$ROOT/verif/tb/apu/tb_g6lc_apu_vndec_rep.sv" \
  --top-module tb_g6lc_apu_vndec_rep \
  -Mdir "$OUT/sim" -o tb_g6lc_apu_vndec_rep \
  > "$OUT/build.log" 2>&1; then
  echo "VERILATOR BUILD FAILED"
  tail -n 80 "$OUT/build.log"
  exit 1
fi
echo "VERILATOR BUILD OK"
set +e
(cd "$ROOT/verif/tb/apu" && stdbuf -o0 -e0 "$OUT/sim/tb_g6lc_apu_vndec_rep") \
  > "$OUT/sim.log" 2>&1
rc=$?
set -e
echo "SIM rc=$rc"
cat "$OUT/sim.log"
if ! grep -q '^PASS tb_g6lc_apu_vndec_rep ' "$OUT/sim.log"; then
  echo "SIM FAILED"
  exit 1
fi
if [ "$rc" -ne 0 ]; then
  echo "SIM rc=$rc despite PASS"
  exit 1
fi
if [ "${VNREP_SYNTH:-0}" != 1 ]; then
  exit 0
fi
for en in 0 1; do
  yp="read_slang -f $ROOT/corev_apu/apu/Flist.apu_vnrep --top g6lc_apu_vnrep_fixture -GEnable=$en; hierarchy -top g6lc_apu_vnrep_fixture; flatten; proc; opt; memory_collect; check -assert; stat; synth -top g6lc_apu_vnrep_fixture -noabc; check -assert; stat; select -assert-none t:\$dlatch t:\$_DLATCH_*"
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
    gate = stats[-1]
    cells = re.search(r"Number of cells:\s+(\d+)", gate) or             re.search(r"^\s+(\d+) cells\b", gate, re.M)
    ffs = sum(int(n) for n, _ in re.findall(r"^\s+(\d+)\s+(\$_DFF\w*)", gate, re.M))
    mem = re.findall(r"^\s+(\d+)\s+(\$mem\S*)", stats[1] if len(stats) > 2 else "", re.M)
    probs = re.findall(r"Found and reported (\d+) problems\.", text)
    print(f"SYNTH Enable={en} cells={cells.group(1) if cells else '?'} "
          f"ffs={ffs} mem={';'.join(f'{n} {k}' for n,k in mem) or 'none'} "
          f"problems={','.join(probs) or '0'} latch=none")
PY
rom=$(grep -o 'APU_VN_REPLY_ROM_WORDS = [0-9]*' \
  "$ROOT/corev_apu/apu/include/g6lc_apu_vn_pkg.sv" | grep -o '[0-9]*')
echo "VNREP_REPLY_ROM_WORDS=$rom"
echo "VNREP_SUMMARY_DONE"
