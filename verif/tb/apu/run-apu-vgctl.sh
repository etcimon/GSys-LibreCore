#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# virtio-gpu control-queue processor (g6lc_apu_vgctl) — directed unit
# test over the real ObjTab; VGCTL_SYNTH=1 adds the yosys Enable=0/1
# screens.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
export CVA6_REPO_DIR="$ROOT"
OUT="${APU_VGCTL_OUT:-/tmp/g6lc-apu-vgctl}"
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
if ! command -v "$YOSYS" >/dev/null 2>&1 && [ -x /usr/local/bin/yosys ]; then
  YOSYS=/usr/local/bin/yosys
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
  -f "$ROOT/corev_apu/apu/Flist.apu_vgctl" \
  "$ROOT/vendor/pulp-platform/tech_cells_generic/src/rtl/tc_sram.sv" \
  "$ROOT/corev_apu/apu/g6lc_apu_objtab.sv" \
  "$ROOT/verif/tb/apu/tb_g6lc_apu_vgctl.sv" \
  --top-module tb_g6lc_apu_vgctl \
  -Mdir "$OUT/sim" -o tb_g6lc_apu_vgctl \
  > "$OUT/build.log" 2>&1; then
  echo "VERILATOR BUILD FAILED"
  tail -n 80 "$OUT/build.log"
  exit 1
fi
echo "VERILATOR BUILD OK"
set +e
stdbuf -o0 -e0 "$OUT/sim/tb_g6lc_apu_vgctl" > "$OUT/sim.log" 2>&1
rc=$?
set -e
echo "SIM rc=$rc"
cat "$OUT/sim.log"
if ! grep -q '^PASS tb_g6lc_apu_vgctl ' "$OUT/sim.log"; then
  echo "SIM FAILED"
  exit 1
fi
if [ "$rc" -ne 0 ]; then
  echo "SIM rc=$rc despite PASS"
  exit 1
fi
if [ "${VGCTL_SYNTH:-0}" != 1 ]; then
  exit 0
fi
for en in 0 1; do
  cat > "$OUT/vgctl-synth$en.ys" <<EOF
read_slang -f $ROOT/corev_apu/apu/Flist.apu_vgctl --top g6lc_apu_vgctl_fixture -GEnable=$en
hierarchy -top g6lc_apu_vgctl_fixture
flatten
proc
opt
memory_collect
check -assert
stat
synth -top g6lc_apu_vgctl_fixture -noabc
check -assert
stat
select -assert-none t:\$dlatch t:\$_DLATCH_*
EOF
  if ! "$YOSYS" -Q -T "$OUT/vgctl-synth$en.ys" > "$OUT/synth-$en.log" 2>&1; then
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
    cells = re.search(r"Number of cells:\s+(\d+)", gate) or \
            re.search(r"^\s+(\d+) cells\b", gate, re.M)
    ffs = sum(int(n) for n, _ in
              re.findall(r"^\s+(\d+)\s+(\$_DFF\w*)", gate, re.M))
    print(f"Enable={en}: cells={cells.group(1) if cells else '?'} "
          f"ffs={ffs}")
PY
