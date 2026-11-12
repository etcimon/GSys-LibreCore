#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# Elaborate the hyp8 SoC (top g6lc_testharness) from a remote closure directory
# and list the live modules/cells: the APU-side liveness census.
#   bash analysis/r127/elab_soc.sh <closure-dir> <out-dir> [flist] [extra verilator args]
set -uo pipefail
C="${1:?closure dir}"; OUT="${2:?out dir}"; FL="${3:-verif/regress/remote/hyp8/Flist.hyp8_sim}"; shift 3 2>/dev/null || shift $#
mkdir -p "$OUT"
cd "$C"
export CVA6_REPO_DIR="$C"
verilator --xml-only --no-timing -Wno-fatal -Wno-PINCONNECTEMPTY -Wno-ASSIGNDLY -Wno-DECLFILENAME \
  -Wno-UNUSED -Wno-UNOPTFLAT -Wno-BLKANDNBLK -Wno-style "$@" \
  --top-module g6lc_testharness -f "$FL" verilator_config.vlt \
  --Mdir "$OUT/obj" --xml-output "$OUT/soc.xml" > "$OUT/elab.log" 2>&1
echo "elab rc=$? errors=$(grep -c '%Error' "$OUT/elab.log")"
grep -m4 '%Error' "$OUT/elab.log" | cut -c1-220
python3 - "$OUT/soc.xml" "$OUT/live-modules.txt" <<'PY'
import re,sys,collections
xml=open(sys.argv[1],encoding='utf-8',errors='replace').read()
cells=re.findall(r'<cell [^>]*?submodname="([^"]+)"[^>]*?hier="([^"]+)"',xml) or [(b,a) for a,b in re.findall(r'<cell [^>]*?hier="([^"]+)"[^>]*?submodname="([^"]+)"',xml)]
orig=dict(re.findall(r'<module [^>]*?name="([^"]+)"[^>]*?origName="([^"]+)"',xml))
c=collections.Counter(orig.get(m,m) for m,h in cells)
open(sys.argv[2],'w').write(''.join(f"{m} {n}\n" for m,n in sorted(c.items())))
print(f"live modules: {len(c)} (cells {len(cells)})")
PY
