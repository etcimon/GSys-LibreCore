#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Elaborated instance hierarchy of the hyp8 core (g6lc_core, g6lc64_hyp8
# config as bound by Flist.g6lc_hyp8) from the host Verilator's --xml-only
# dump. Purpose: decide which board rows are instantiated after generate
# pruning (A89: only instantiated modules decide a target's period) from the
# elaborator, not from reading config flags.
#
#   bash analysis/r127/elab_hierarchy.sh [out_dir]
#   ELAB_DEFINES="+define+G6LC_HYP8_DEEP" bash analysis/r127/elab_hierarchy.sh <out_dir>
# Writes <out_dir>/g6lc_core.xml and <out_dir>/live-modules.txt (origName
# of every module with at least one elaborated cell, plus the top).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYP="$(cd "$HERE/../.." && pwd)"
ROOT="$(cd "$HYP/../../../.." && pwd)"
OUT="${1:-$ROOT/build-platform/workspace/build/hyp8-elab-r127}"
mkdir -p "$OUT"
sed "s|\${HYP_CORE_DIR}|$HYP|g" "$HYP/core/Flist.g6lc_hyp8" \
  | grep -v 'g6lc_fetch_dbg\.sv' > "$OUT/flist.f"
"${VERILATOR:-verilator}" --xml-only --xml-output "$OUT/g6lc_core.xml" -Wno-fatal \
  -Wno-UNUSED -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY -Wno-UNOPTFLAT \
  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-WIDTHCONCAT -Wno-CASEINCOMPLETE \
  -Wno-UNSIGNED -Wno-VARHIDDEN -Wno-SYMRSVDWORD -Wno-TIMESCALEMOD \
  -Wno-SELRANGE -Wno-LITENDIAN -Wno-ASSIGNDLY -Wno-BLKANDNBLK -Wno-style \
  ${ELAB_DEFINES:-} --top-module g6lc_core -f "$OUT/flist.f" > "$OUT/elab.log" 2>&1 || true
python3 - "$OUT/g6lc_core.xml" "$OUT/live-modules.txt" <<'PY'
import sys, re
xml = open(sys.argv[1], encoding='utf-8', errors='replace').read()
orig = dict(re.findall(r'<module [^>]*?name="([^"]+)"[^>]*?origName="([^"]+)"', xml))
cells = re.findall(r'<cell [^>]*?submodname="([^"]+)"', xml)
live = {}
for c in cells:
    o = orig.get(c, c)
    live[o] = live.get(o, 0) + 1
top = re.search(r'<module [^>]*?name="([^"]+)"[^>]*?topModule="1"', xml)
if top:
    live.setdefault(orig.get(top.group(1), top.group(1)), 1)
with open(sys.argv[2], 'w', encoding='utf-8') as f:
    for k in sorted(live):
        f.write(f"{k} {live[k]}\n")
print(f"live modules: {len(live)} (cells {len(cells)})")
PY
