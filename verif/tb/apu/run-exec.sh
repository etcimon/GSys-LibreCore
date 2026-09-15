#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Remote helper: native exec + firmware bind + resident sequence + mini-hart +
# host TGSI compile + DRAM-hole/boot/load checks + synth.
set -euo pipefail
export APU_EXEC=1 APU_SYNTH=1
exec "$(dirname "$0")/run-virtio-mmio.sh"
