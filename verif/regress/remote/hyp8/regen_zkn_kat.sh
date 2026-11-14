#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# Regenerate the `expected` checksum of verif/tests/custom/hyp8_zkn_kat.S from
# the Spike ISA simulator: assemble with the integration's GCC flags, run on
# spike (Zknd/Zkne/Zknh), read the value the program stores to `chk_out`, and
# with --patch write it into the source, rebuild and require tohost == 1.
#   bash verif/regress/remote/hyp8/regen_zkn_kat.sh [--patch]
# Needs riscv64-unknown-elf-gcc and a spike that prints the commit log
# (SPIKE=<path> overrides; default: the managed build-platform spike, then PATH).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
S="$ROOT/verif/tests/custom/hyp8_zkn_kat.S"
O="${ZKN_KAT_OUT:-$ROOT/build-platform/workspace/build/hyp8-zkn-kat}"; mkdir -p "$O"
SPIKE="${SPIKE:-$(ls "$ROOT/build-platform/workspace/tooling/spike/bin/spike" 2>/dev/null || command -v spike)}"
build() {
  riscv64-unknown-elf-gcc -march=rv64imafdc_zicsr_zifencei -mabi=lp64d -mcmodel=medany -O2 \
    -nostdlib -nostartfiles -T "$ROOT/verif/tests/custom/common/link_verilator.ld" \
    -o "$O/zkn.elf" "$S" 2> "$O/build.log" || { echo "gcc FAIL: $(head -3 "$O/build.log")"; exit 1; }
}
run() {
  timeout 120 "$SPIKE" --isa=rv64gc_zknd_zkne_zknh -m0x80000000:0x10000000 "$O/zkn.elf" > "$O/spike.log" 2>&1
}
sym() { riscv64-unknown-elf-nm -n "$O/zkn.elf" | awk -v s="$1" '$3==s{print $1}'; }
memw() { grep -a "mem 0x$1 " "$O/spike.log" | tail -1 | awk '{print $NF}'; }
build; run
CHK="$(sym chk_out)"; TOH="$(sym tohost)"
V="$(memw "$CHK")"
echo "spike checksum: ${V:-<none>} (tohost write: $(memw "$TOH"))"
[ -n "$V" ] || { echo "no checksum in the spike log (does this spike print commits?)"; exit 1; }
if [ "${1:-}" = "--patch" ]; then
  python3 - "$S" "$V" <<'PY'
import re, sys
path, value = sys.argv[1], int(sys.argv[2], 16)
text = open(path, encoding="utf-8").read()
text, n = re.subn(r"(expected:\n  \.dword )0x[0-9a-fA-F]+", lambda m: m.group(1) + "0x%016x" % value, text)
assert n == 1, "expected dword not found"
open(path, "w", encoding="utf-8", newline="\n").write(text)
print("patched expected = 0x%016x" % value)
PY
  build; run
fi
T="$(memw "$TOH")"
echo "tohost: ${T:-<none>}"
[ "$T" = "0x00000001" ]
