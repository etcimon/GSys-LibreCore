#!/bin/bash
# SPDX-License-Identifier: MIT
# Compile the grown mini and run it with batch TRACE.
#   CVA6_TRACE_FILE  default: this dir/trace-p6-batch.spec
set -uo pipefail
export PATH="/root/tools/verilator-v5.008/bin:/opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin:/root/tools/spike/bin:${PATH}"
export LD_LIBRARY_PATH="/root/tools/spike/lib:${LD_LIBRARY_PATH:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
export CVA6_TRACE=1
export CVA6_TRACE_FILE="${CVA6_TRACE_FILE:-$HERE/trace-p6-batch.spec}"
# shellcheck source=run_mini_p3split.sh
. "$HERE/run_mini_p3split.sh"
