# Copyright 2022 Thales DIS design services SAS
#
# Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
# You may obtain a copy of the License at https://solderpad.org/licenses/
#
# Original Author: Zbigniew CHAMSKI (zbigniew.chamski@thalesgroup.fr)

# where are the tools
if ! [ -n "$RISCV" ]; then
  echo "Error: RISCV variable undefined"
  return
fi

if ! [ -n "$DV_SIMULATORS" ]; then
  DV_SIMULATORS=vcs-uvm
fi

if ! [ -n "$DV_TARGET" ]; then
  DV_TARGET=cv32a65x
fi

# install the required tools
if [[ "$DV_SIMULATORS" == *"veri-testharness"* ]]; then
  source ./verif/regress/install-verilator.sh
fi
source ./verif/regress/install-spike.sh

source ./verif/sim/setup-env.sh

make clean
make -C verif/sim clean_all

cd verif/sim

src0=../tests/custom/dhrystone/dhrystone_main.c
srcA=(
        ../tests/custom/dhrystone/dhrystone.c
        ../tests/custom/common/syscalls.c
        ../tests/custom/common/crt.S
)
cflags=(
        -fno-tree-loop-distribute-patterns
        -static
        -mcmodel=medany
        -fvisibility=hidden
        -nostdlib
        -nostartfiles
        -lgcc
        -Os --no-inline
        -Wno-implicit-function-declaration
        -Wno-implicit-int
        -I../tests/custom/env
        -I../tests/custom/common
        -I../tests/custom/dhrystone/
        -DNOPRINT
)

ROOT_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
BENCH_LOG="${CVA6_BENCH_LOG:-$ROOT_REPO/build-platform/workspace/build/bench/dhrystone_smoke.log}"
mkdir -p "$(dirname "$BENCH_LOG")"

set +e
python3 cva6.py \
        --target $DV_TARGET \
        --iss="$DV_SIMULATORS" \
        --iss_yaml=cva6.yaml \
        --c_tests "$src0" \
        --sv_seed 1 \
        --gcc_opts "${srcA[*]} ${cflags[*]}" 2>&1 | tee "$BENCH_LOG"
py_rc=${PIPESTATUS[0]:-${?}}
set -e

# Optional timing-package correlation (structural FO4 — not STA).
# Metrics: parse log for DMIPS/cycles when present (-DNOPRINT may leave empty).
export CVA6_BENCH_ID="${CVA6_BENCH_ID:-dhrystone-smoke}"
export CVA6_BENCH_SCORE="${CVA6_BENCH_SCORE:-smoke}"
export CVA6_BENCH_RUNTIME_S="${CVA6_BENCH_RUNTIME_S:-0}"
if [[ -n "${CVA6_FROM_TIMING:-${FROM_TIMING:-}}" ]] && command -v bun >/dev/null 2>&1; then
  FT="${CVA6_FROM_TIMING:-$FROM_TIMING}"
  echo "[dhrystone_smoke] timings correlate --bench dhrystone-smoke --from-timing $FT --file $BENCH_LOG"
  (cd "$ROOT_REPO/build-platform" && bun run src/cli/index.ts timings correlate \
    --from-timing "$FT" --bench dhrystone-smoke --file "$BENCH_LOG") || true
fi

exit "$py_rc"
