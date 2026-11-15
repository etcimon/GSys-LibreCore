#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# White-box check of the depth-tiled g6lc_apu_fwram gen_hex preload:
# tb_fwpre lets the time-0 HexFile load run, then probes each tile's
# tc_sram sram[] against the flat image — catching tile/local-row
# misplacement that a bus-level readback (same mapping both ways)
# cannot see.  FWPRE_HEX regenerates the gitignored *.hex vector
# deterministically; the DUT and the checker read the same file, so any
# non-degenerate pattern works (adjacent-equal words would mask bugs).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
export CVA6_REPO_DIR="$ROOT"
OUT="${APU_FWPRE_OUT:-/tmp/g6lc-apu-fwpre}"
VERILATOR="${VERILATOR:-verilator}"
if ! command -v "$VERILATOR" >/dev/null 2>&1 && \
   [ -x /opt/testharness/toolchains/verilator-v5.008/bin/verilator ]; then
  VERILATOR=/opt/testharness/toolchains/verilator-v5.008/bin/verilator
fi
rm -rf "$OUT"
mkdir -p "$OUT"

# fwpre.hex is gitignored (verif/.gitignore *.hex): synthesize the same
# 60000-word splitmix64 stream the bench was written against.  The hex
# loader treats each 32-bit word; two words pack one 64-bit sram row.
python3 - "$OUT/fwpre.hex" <<'PY'
import sys
x = 0x243F6A8885A308D3
w = open(sys.argv[1], "w")
for _ in range(60000):
    x = (x + 0x9E3779B97F4A7C15) & 0xFFFFFFFFFFFFFFFF
    z = x
    z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & 0xFFFFFFFFFFFFFFFF
    z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & 0xFFFFFFFFFFFFFFFF
    z ^= z >> 31
    w.write("%08x\n" % (z & 0xFFFFFFFF))
w.close()
PY

"$VERILATOR" --binary --timing --assert -Wall \
  -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-WIDTHEXPAND -Wno-BLKSEQ \
  -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
  -Wno-LITENDIAN \
  "$ROOT/verif/tb/apu/apu_axi.vlt" -f "$ROOT/corev_apu/apu/Flist.apu_soc" \
  "$ROOT/verif/tb/apu/tb_fwpre.sv" --top-module tb_fwpre \
  -Mdir "$OUT" -o tb_fwpre 2>&1 | tee "$OUT/build.log" | tail -n 20

# Run from $OUT so the DUT's relative HexFile("fwpre.hex") resolves; the
# checker's $readmemh gets the same file via +HEX= (absolute).
( cd "$OUT" && ./tb_fwpre "+HEX=$OUT/fwpre.hex" ) 2>&1 | tee "$OUT/sim.log"
