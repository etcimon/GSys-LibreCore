#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Remote helper: SoC/attach/th/xbar/fwram/th_load suite plus generic synth.
set -euo pipefail
export APU_SOC=1 APU_SYNTH=1
exec "$(dirname "$0")/run-virtio-mmio.sh"
