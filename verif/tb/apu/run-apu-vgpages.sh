#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Aperture page allocator (g6lc_apu_vgpages) — directed + seeded-random
# Verilator sim at the shipped 8192-page (32 MiB) geometry and at the
# 65536-page (256 MiB) 3d-c scaling geometry (VGPAGES_PAGES overrides).
# VGPAGES_SYNTH=1 adds yosys Enable=0/1 screens at both geometries.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
export CVA6_REPO_DIR="$ROOT"
OUT="${APU_VGPAGES_OUT:-/tmp/g6lc-apu-vgpages}"
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
rc=0
for pages in ${VGPAGES_PAGES:-8192 65536}; do
  if ! "$VERILATOR" --binary --timing --assert -Wall \
    -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-WIDTHEXPAND -Wno-BLKSEQ \
    -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
    -Wno-GENUNNAMED \
    "${VLTS[@]}" \
    -f "$ROOT/corev_apu/apu/Flist.apu_vgpages" \
    "$ROOT/verif/tb/apu/tb_g6lc_apu_vgpages.sv" \
    --top-module tb_g6lc_apu_vgpages -GPages="$pages" \
    -Mdir "$OUT/sim-$pages" -o tb_g6lc_apu_vgpages \
    > "$OUT/build-$pages.log" 2>&1; then
    echo "VERILATOR BUILD FAILED Pages=$pages"
    tail -n 80 "$OUT/build-$pages.log"
    exit 1
  fi
  echo "VERILATOR BUILD OK Pages=$pages"
  set +e
  stdbuf -o0 -e0 "$OUT/sim-$pages/tb_g6lc_apu_vgpages" \
    > "$OUT/sim-$pages.log" 2>&1
  src=$?
  set -e
  echo "SIM Pages=$pages rc=$src"
  cat "$OUT/sim-$pages.log"
  if ! grep -q "^PASS tb_g6lc_apu_vgpages pages=$pages " \
       "$OUT/sim-$pages.log"; then
    echo "SIM FAILED Pages=$pages"
    exit 1
  fi
  if [ "$src" -ne 0 ]; then
    echo "SIM rc=$src despite PASS"
    exit 1
  fi
done
if [ "${VGPAGES_SYNTH:-0}" != 1 ]; then
  exit 0
fi
for pages in ${VGPAGES_PAGES:-8192 65536}; do
  for en in 0 1; do
    yp="read_slang -f $ROOT/corev_apu/apu/Flist.apu_vgpages --top g6lc_apu_vgpages_fixture -GEnable=$en -GPages=$pages; hierarchy -top g6lc_apu_vgpages_fixture; flatten; proc; opt; memory_collect; check -assert; stat; synth -top g6lc_apu_vgpages_fixture -noabc; check -assert; stat; select -assert-none t:\$dlatch t:\$_DLATCH_*"
    if ! "$YOSYS" -Q -T -p "$yp" > "$OUT/synth-$en-p$pages.log" 2>&1; then
      echo "SYNTH FAILED Enable=$en Pages=$pages"
      tail -n 40 "$OUT/synth-$en-p$pages.log"
      exit 1
    fi
    echo "SYNTH OK Enable=$en Pages=$pages"
  done
done
python3 - "$OUT" <<'PY'
import re, sys, pathlib
out = pathlib.Path(sys.argv[1])
for log in sorted(out.glob("synth-*.log")):
    text = log.read_text(errors="replace")
    stats = re.split(r"\d+\. Printing statistics\.", text)
    gate = stats[-1]
    cells = re.search(r"Number of cells:\s+(\d+)", gate) or \
            re.search(r"^\s+(\d+) cells\b", gate, re.M)
    ffs = sum(int(n) for n, _ in re.findall(r"^\s+(\d+)\s+(\$_DFF\w*)", gate, re.M))
    probs = re.findall(r"Found and reported (\d+) problems\.", text)
    print(f"SYNTH {log.stem} cells={cells.group(1) if cells else '?'} "
          f"ffs={ffs} problems={','.join(probs) or '0'} latch=none")
PY
echo "VGPAGES_SUMMARY_DONE"
