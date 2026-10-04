#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ShaderCore commit scanner (g6lc_apu_shmod) — directed unit test:
# corpus commits + golden-table diff + fault matrix.
# SHMOD_SYNTH=1 adds the yosys Enable=0/1 screens (default geometry
# and the small screen -GShaderRegs=16 -GShaderIds=64 -GShaderSlots=2
# so logic is visible apart from the SRAMs).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
export CVA6_REPO_DIR="$ROOT"
OUT="${APU_SHMOD_OUT:-/tmp/g6lc-apu-shmod}"
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
VLTS=("$ROOT/verif/tb/apu/apu_axi.vlt")
vver="$("$VERILATOR" --version | grep -o '[0-9][0-9.]*' | head -1)"
if awk -v v="$vver" 'BEGIN{split(v,a,"."); exit !(a[1]>5||(a[1]==5&&a[2]>=16))}'; then
  VLTS+=("$ROOT/verif/tb/apu/apu_vn.vlt")
fi
if ! "$VERILATOR" --binary --timing --assert -Wall \
  -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  -Wno-BLKSEQ -Wno-SYNCASYNCNET -Wno-DECLFILENAME \
  -Wno-PINCONNECTEMPTY \
  "${VLTS[@]}" \
  -f "$ROOT/corev_apu/apu/Flist.apu_shmod" \
  "$ROOT/vendor/pulp-platform/tech_cells_generic/src/rtl/tc_sram.sv" \
  "$ROOT/verif/tb/apu/tb_g6lc_apu_shmod.sv" \
  --top-module tb_g6lc_apu_shmod \
  -Mdir "$OUT/sim" -o tb_g6lc_apu_shmod \
  > "$OUT/build.log" 2>&1; then
  echo "VERILATOR BUILD FAILED"
  tail -n 80 "$OUT/build.log"
  exit 1
fi
echo "VERILATOR BUILD OK"
set +e
stdbuf -o0 -e0 "$OUT/sim/tb_g6lc_apu_shmod" \
  +shv="$ROOT/verif/tb/apu/sh_vectors" > "$OUT/sim.log" 2>&1
rc=$?
set -e
echo "SIM rc=$rc"
cat "$OUT/sim.log"
if ! grep -q '^PASS tb_g6lc_apu_shmod ' "$OUT/sim.log"; then
  echo "SIM FAILED"
  exit 1
fi
if [ "$rc" -ne 0 ]; then
  echo "SIM rc=$rc despite PASS"
  exit 1
fi
if [ "${SHMOD_SYNTH:-0}" != 1 ]; then
  exit 0
fi
synth_one() {
  local tag="$1"; shift
  cat > "$OUT/shmod-synth$tag.ys" <<EOF
read_slang -f $ROOT/corev_apu/apu/Flist.apu_shmod \
  $ROOT/vendor/pulp-platform/tech_cells_generic/src/rtl/tc_sram.sv \
  --top g6lc_apu_shmod_fixture $*
hierarchy -top g6lc_apu_shmod_fixture
flatten
proc
opt
memory_collect
check -assert
stat
synth -top g6lc_apu_shmod_fixture -noabc
check -assert
stat
select -assert-none t:\$dlatch t:\$_DLATCH_*
EOF
  if ! "$YOSYS" -Q -T "$OUT/shmod-synth$tag.ys" \
    > "$OUT/synth$tag.log" 2>&1; then
    echo "SYNTH FAILED $tag"
    tail -n 40 "$OUT/synth$tag.log"
    exit 1
  fi
  echo "SYNTH OK $tag"
}
synth_one "-0" "-GEnable=0"
synth_one "-1s" "-GEnable=1 -GShaderSlots=2 -GShaderIds=64 \
                  -GShaderRegs=16 -GShaderWords=64 \
                  -GShaderMembers=16 -GShaderInit=8"
if [ "${SHMOD_SYNTH_FULL:-0}" = 1 ]; then
  synth_one "-1" "-GEnable=1"
fi
python3 - "$OUT" <<'PY'
import re, sys, pathlib
out = pathlib.Path(sys.argv[1])
for tag in ("-0", "-1s", "-1"):
    p = pathlib.Path(f"{out}/synth{tag}.log")
    if not p.exists():
        continue
    text = p.read_text(errors="replace")
    stats = re.split(r"\d+\. Printing statistics\.", text)
    gate = stats[-1]
    cells = re.search(r"Number of cells:\s+(\d+)", gate) or \
            re.search(r"^\s+(\d+) cells\b", gate, re.M)
    ffs = sum(int(n) for n, _ in
              re.findall(r"^\s+(\d+)\s+(\$_DFF\w*)", gate, re.M))
    mems = re.findall(r"^\s+(\d+)\s+(\$mem\S*)", gate, re.M)
    print(f"{tag}: cells={cells.group(1) if cells else '?'} "
          f"ffs={ffs} mems={mems}")
PY
