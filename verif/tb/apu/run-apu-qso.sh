#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Scene OK_NODATA WRITE after the named scene chain.
# TEX is not the compiler opcode. This is not the screenshot.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
export CVA6_REPO_DIR="$ROOT"
OUT="${APU_QSO_OUT:-/tmp/g6lc-apu-qso}"
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
if ! "$VERILATOR" --binary --timing --assert -Wall \
  -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-WIDTHEXPAND -Wno-BLKSEQ \
  -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
  -f "$ROOT/corev_apu/apu/Flist.apu_qso" \
  "$ROOT/verif/tb/apu/tb_g6lc_apu_vgpu_qso.sv" \
  --top-module tb_g6lc_apu_vgpu_qso \
  -Mdir "$OUT/sim" -o tb_g6lc_apu_vgpu_qso \
  > "$OUT/build.log" 2>&1; then
  echo "VERILATOR BUILD FAILED"
  tail -n 80 "$OUT/build.log"
  exit 1
fi
echo "VERILATOR BUILD OK"
set +e
stdbuf -o0 -e0 "$OUT/sim/tb_g6lc_apu_vgpu_qso" > "$OUT/sim.log" 2>&1
rc=$?
set -e
echo "SIM rc=$rc"
cat "$OUT/sim.log"
if ! grep -q '^PASS tb_g6lc_apu_vgpu_qso ' "$OUT/sim.log"; then
  echo "SIM FAILED"
  exit 1
fi
if [ "$rc" -ne 0 ]; then
  echo "SIM rc=$rc despite PASS"
  exit 1
fi
if [ "${QSO_SYNTH:-0}" != 1 ]; then
  exit 0
fi
for unit in qso qsp qsq; do
  for en in 0 1; do
    top="g6lc_apu_vgpu_${unit}_fixture"
    yp="read_slang -f $ROOT/corev_apu/apu/Flist.apu_qso --top $top -GEnable=$en; hierarchy -top $top; flatten; proc; opt; memory_collect; check -assert; stat; synth -top $top -noabc; check -assert; stat; select -assert-none t:\$dlatch t:\$_DLATCH_*"
    if ! "$YOSYS" -Q -T -p "$yp" > "$OUT/synth-$unit-$en.log" 2>&1; then
      echo "SYNTH FAILED $unit Enable=$en"
      tail -n 40 "$OUT/synth-$unit-$en.log"
      exit 1
    fi
    echo "SYNTH OK $unit Enable=$en"
  done
done
python3 - << 'PY'
import os, re, pathlib
out = pathlib.Path(os.environ.get("APU_QSO_OUT", "/tmp/g6lc-apu-qso"))
def last_stat(text):
    parts = text.split("11. Printing statistics.")
    return parts[-1]
for unit in ("qso", "qsp", "qsq"):
  for en in (0, 1):
    text = (out / f"synth-{unit}-{en}.log").read_text(errors="replace")
    block = last_stat(text)
    cells = re.search(r"Number of cells:\s+(\d+)", block)
    if not cells:
        cells = re.search(r"^\s+(\d+) cells\b", block, re.M)
    ports = re.search(r"Number of ports:\s+(\d+)", block)
    if not ports:
        ports = re.search(r"^\s+(\d+) ports\b", block, re.M)
    ffs = sum(int(n) for n, _ in re.findall(r"^\s+(\d+)\s+(\$_DFF\w*)", block, re.M))
    latches = [f"{n} {k}" for n, k in re.findall(r"^\s+(\d+)\s+(\$(?:_)?[Dd][Ll][Aa][Tt][Cc][Hh]\w*)", block, re.M)]
    probs = re.findall(r"Found and reported (\d+) problems\.", text)
    print(f"SYNTH {unit} Enable={en} cells={cells.group(1) if cells else 'none'} ffs={ffs} ports={ports.group(1) if ports else '?'} problems={','.join(probs) or '?'} latch={';'.join(latches) or 'none'}")
    if not cells:
        print(block[-800:])
PY
echo "QSO_SUMMARY_DONE"
