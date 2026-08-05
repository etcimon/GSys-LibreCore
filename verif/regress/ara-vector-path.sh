#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# U10ᵇ Ara path gate: vendor tree + Flist.ara + directed vector tests + DTS;
# optional lint of g6lc64_server_math_v when extraFlists is armed.
#
# Usage:
#   bash verif/regress/ara-vector-path.sh
#   CVA6_ARA_ATTACH=1  # live Ara lint (default when upstream present)

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

echo "[ara-vector-path] U10ᵇ Ara / RVV attach contract"

need=(
  architecture/ara-vector-attach.md
  agents/guides/AGENTS-vector.md
  vendor/ara/README.md
  vendor/ara/Flist.ara
  vendor/ara/Flist.ara.example
  core/include/g6lc64_server_math_v_config_pkg.sv
  corev_apu/bootrom/ariane-server-math-v.dts
  corev_apu/src/g6lc_ara_attach.sv
  verif/tests/custom/vector/v_memcpy_skip.S
  verif/tests/custom/vector/v_misa_v.S
  verif/tests/custom/vector/v_memcpy_lmul.S
  verif/tests/testlist_ara_vector.yaml
)
for f in "${need[@]}"; do
  test -f "$f" || { echo "[ara-vector-path] MISSING $f"; exit 1; }
done
echo "  ok docs + flist + package + DTS + directed tests + testlist"

# DTS must advertise RVV 1.0 for the _v package contract (v + zve64d + imafdcv)
grep -q '"v"' corev_apu/bootrom/ariane-server-math-v.dts \
  || { echo "[ara-vector-path] FAIL: ariane-server-math-v.dts missing v token" >&2; exit 1; }
grep -q 'zve64d' corev_apu/bootrom/ariane-server-math-v.dts \
  || { echo "[ara-vector-path] FAIL: ariane-server-math-v.dts missing zve64d (RVV 1.0 / #ext:v)" >&2; exit 1; }
grep -qE 'riscv,isa = "rv64imafdcv_' corev_apu/bootrom/ariane-server-math-v.dts \
  || { echo "[ara-vector-path] FAIL: riscv,isa must include imafdcv" >&2; exit 1; }
grep -q 'riscv,isa-extensions' corev_apu/bootrom/ariane-server-math-v.dts
echo "  ok server-math-v DTS advertises RVV 1.0 (v + zve64d)"

if [[ -d vendor/ara/upstream/hardware/src ]]; then
  test -f vendor/ara/upstream/hardware/src/ara.sv
  test -f vendor/ara/upstream/hardware/src/cva6_accel_first_pass_decoder.sv
  echo "  ok upstream Ara RTL present (vendor sync ara done)"
else
  echo "  WARN: vendor/ara/upstream missing — run: cva6-build vendor sync ara"
fi

grep -q 'RVV\|VExtEn\|CVA6ConfigVExtEn' core/include/g6lc64_server_math_v_config_pkg.sv
echo "  ok server_math_v package identity"

# Optional assemble smoke for soft-skip tests (no V opcodes → any rv64imafdc gcc)
asm_smoke() {
  local src="$1"
  local out
  out="$(mktemp -t ara_vec_XXXXXX.o 2>/dev/null || mktemp /tmp/ara_vec_XXXXXX.o)"
  if "${CROSS_COMPILE:-riscv64-unknown-elf-}gcc" -c \
      -march=rv64imafdc -mabi=lp64d \
      -Iverif/tests/custom/env -Iverif/tests/custom/common \
      -o "$out" "$src" 2>/dev/null; then
    rm -f "$out"
    return 0
  fi
  rm -f "$out"
  return 1
}

if command -v "${CROSS_COMPILE:-riscv64-unknown-elf-}gcc" >/dev/null 2>&1 \
   || command -v riscv64-unknown-elf-gcc >/dev/null 2>&1 \
   || command -v riscv-none-elf-gcc >/dev/null 2>&1; then
  CC_TRY="${CROSS_COMPILE:-}"
  if [[ -z "$CC_TRY" ]]; then
    if command -v riscv64-unknown-elf-gcc >/dev/null 2>&1; then
      CROSS_COMPILE=riscv64-unknown-elf-
    elif command -v riscv-none-elf-gcc >/dev/null 2>&1; then
      CROSS_COMPILE=riscv-none-elf-
    fi
  fi
  if asm_smoke verif/tests/custom/vector/v_memcpy_skip.S \
     && asm_smoke verif/tests/custom/vector/v_misa_v.S \
     && asm_smoke verif/tests/custom/vector/v_memcpy_lmul.S; then
    echo "  ok directed vector .S assemble (rv64imafdc; raw V encodings)"
  else
    echo "  WARN: assemble smoke failed (toolchain flags) — tests still present"
  fi
else
  echo "  skip assemble smoke (no riscv-*-gcc on PATH)"
fi

if command -v bun >/dev/null 2>&1; then
  echo "[ara-vector-path] lint g6lc64_server_math (C-light, no Ara flist)..."
  bun build-platform/src/cli/index.ts verify --lint --target g6lc64_server_math || \
    echo "[ara-vector-path] WARN: server_math lint failed/skipped"

  if [[ -d vendor/ara/upstream/hardware/src ]]; then
    echo "[ara-vector-path] lint g6lc64_server_math_v (typed attach stub)..."
    if bun build-platform/src/cli/index.ts verify --lint --target g6lc64_server_math_v; then
      echo "  ok server_math_v attach-stub lint"
    else
      echo "[ara-vector-path] FAIL: server_math_v stub lint" >&2
      exit 1
    fi
    echo "[ara-vector-path] lint g6lc64_server_math_v with CVA6_ARA_ATTACH=1 (live Ara)..."
    if CVA6_ARA_ATTACH=1 bun build-platform/src/cli/index.ts verify --lint --target g6lc64_server_math_v; then
      echo "  ok server_math_v + live Ara IP lint"
    else
      echo "[ara-vector-path] FAIL: live Ara lint" >&2
      exit 1
    fi
  fi
fi

cat <<'EOF'
[ara-vector-path] next for full vector cosim:
  1. cva6-build vendor sync ara   # if upstream missing
  2. CVA6_ARA_ATTACH=1 + Ara on flist (extraFlistsByTarget for _v)
  3. OpenSBI vector context + Linux CONFIG_RISCV_ISA_V
  4. cva6.py + testlist_ara_vector.yaml (v_memcpy_lmul) on live Ara
  Guide: agents/guides/AGENTS-vector.md
  DTS:   corev_apu/bootrom/ariane-server-math-v.dts
EOF
echo "[ara-vector-path] PASS (artifact contracts)"
