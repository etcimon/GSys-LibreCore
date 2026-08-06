#!/usr/bin/env bash
# Copyright 2021 Thales DIS design services SAS
#
# Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
# You may obtain a copy of the License at https://solderpad.org/licenses/
#
# Original Author: Jean-Roch COULON - Thales
#
# Smoke suite for cv64a6_imafdc_sv39. Executed (not sourced) by the build
# platform — use `exit`, never bare `return`, and fail hard on tool errors.

# -e/-o pipefail: fail on errors. Avoid -u while sourcing legacy install-*.sh
# scripts that expand optional env vars (VERILATOR_BUILD_DIR etc.).
set -eo pipefail

# Fail early with a clear message if the host is a broken Windows Git-Bash
# (Windows PATH without /usr/bin, Chocolatey non-GNU make, Store python stub).
need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Error: required tool '$1' not found on PATH" >&2
    echo "  On Windows prefer WSL (default): G6LC_REGRESS_ENGINE=wsl" >&2
    echo "  Or fix Git-Bash PATH so /usr/bin (dirname,sed,rm) and GNU make/python3 exist." >&2
    exit 127
  }
}
need dirname
need make
need python3
need sed
need rm
if ! make --version 2>/dev/null | head -1 | grep -qi "GNU Make"; then
  echo "Error: 'make' is not GNU Make (got: $(command -v make))" >&2
  echo "  Chocolatey/Windows make cannot run this Makefile. Use WSL or install GNU make." >&2
  exit 127
fi

# where are the tools
if [ -z "${RISCV:-}" ]; then
  echo "Error: RISCV variable undefined"
  exit 1
fi

if [ -z "${DV_SIMULATORS:-}" ]; then
  DV_SIMULATORS=vcs-testharness,spike
fi

# install the required tools
if [[ "$DV_SIMULATORS" == *"veri-testharness"* ]]; then
  # shellcheck source=/dev/null
  source ./verif/regress/install-verilator.sh
fi
# shellcheck source=/dev/null
source ./verif/regress/install-spike.sh

# install the required test suites
# shellcheck source=/dev/null
source ./verif/regress/install-riscv-compliance.sh
# shellcheck source=/dev/null
source ./verif/regress/install-riscv-tests.sh
# shellcheck source=/dev/null
source ./verif/regress/install-riscv-arch-test.sh

# setup sim env
# shellcheck source=/dev/null
source ./verif/sim/setup-env.sh

echo "SPIKE_INSTALL_DIR=${SPIKE_INSTALL_DIR:-}"

if [ -z "${UVM_VERBOSITY:-}" ]; then
  export UVM_VERBOSITY=UVM_NONE
fi

# Cycle limit lives in rvfi_tracer.sv default (20M) — covers rv64ui-v-add
# (~12M cycles on WT dcache). Override per-run with +time_out=<N> if needed.
export DV_OPTS="${DV_OPTS:-} --issrun_opts=+debug_disable=1+UVM_VERBOSITY=$UVM_VERBOSITY"

CC_OPTS="-static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles -g ../tests/custom/common/syscalls.c ../tests/custom/common/crt.S -I../tests/custom/env -I../tests/custom/common -lgcc"

cd verif/sim/

# iss_timeout (wall seconds): Verilator rv64ui-v-add is ~12–18e6 cycles ≈
# 5–8 min on this host; allow 20 min. Spike uses max(iss_timeout//3, 120) and
# stages logs via /tmp (see verif/sim/Makefile), so Spike is not the bottleneck.
ISS_TIMEOUT="${ISS_TIMEOUT:-1200}"

make -C ../.. clean
make clean_all
python3 cva6.py --testlist=../tests/testlist_riscv-compliance-cv64a6_imafdc_sv39.yaml --test rv32i-I-ADD-01 --iss_yaml cva6.yaml --target cv64a6_imafdc_sv39 --iss="$DV_SIMULATORS" $DV_OPTS --iss_timeout="$ISS_TIMEOUT"
python3 cva6.py --testlist=../tests/testlist_riscv-tests-cv64a6_imafdc_sv39-v.yaml --test rv64ui-v-add --iss_yaml cva6.yaml --target cv64a6_imafdc_sv39 --iss="$DV_SIMULATORS" $DV_OPTS --iss_timeout="$ISS_TIMEOUT"
python3 cva6.py --testlist=../tests/testlist_riscv-tests-cv64a6_imafdc_sv39-p.yaml --test rv64ui-p-add --iss_yaml cva6.yaml --target cv64a6_imafdc_sv39 --iss="$DV_SIMULATORS" $DV_OPTS --iss_timeout="$ISS_TIMEOUT"
python3 cva6.py --testlist=../tests/testlist_riscv-tests-cv64a6_imafdc_sv39-p.yaml --test rv64si-p-noncanonical --iss_yaml cva6.yaml --target cv64a6_imafdc_sv39 --iss="$DV_SIMULATORS" $DV_OPTS --iss_timeout="$ISS_TIMEOUT"
python3 cva6.py --testlist=../tests/testlist_riscv-arch-test-cv64a6_imafdc_sv39.yaml --test rv64i_m-add-01 --iss_yaml cva6.yaml --target cv64a6_imafdc_sv39 --iss="$DV_SIMULATORS" $DV_OPTS --iss_timeout="$ISS_TIMEOUT" --linker=../../config/gen_from_riscv_config/linker/link.ld
python3 cva6.py --testlist=../tests/testlist_custom.yaml --test custom_test_template --iss_yaml cva6.yaml --target cv64a6_imafdc_sv39 --iss="$DV_SIMULATORS" $DV_OPTS --iss_timeout="$ISS_TIMEOUT"
python3 cva6.py --c_tests ../tests/custom/hello_world/hello_world.c --iss_yaml cva6.yaml --target cv64a6_imafdc_sv39 --iss="$DV_SIMULATORS" --gcc_opts="$CC_OPTS -nostdlib -lgcc" $DV_OPTS --iss_timeout="$ISS_TIMEOUT" --linker=../../config/gen_from_riscv_config/linker/link.ld
make -C ../.. clean
make clean_all

cd -
