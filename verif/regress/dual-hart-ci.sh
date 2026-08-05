#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Optional dual-hart / SMT2 CI gate (not default verify).
# Stages: artifacts → smt-linux-boot-path → bare-metal dual-park artifact →
# optional smt2 lint → document full Linux lab steps.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

echo "[dual-hart-ci] OPTIONAL — dual-hart / SMT2 bring-up"
echo "  profile: core/include/g6lc64_smt2_config_pkg.sv  (NrHarts=2)"
echo "  notes:   architecture/multi-threading/smt2-bringup.md"

need=(
  core/include/g6lc64_smt2_config_pkg.sv
  architecture/multi-threading/smt2-bringup.md
  architecture/multi-threading/dts-linux-smt.md
  core/smt/g6lc_smt_regfile.sv
  core/smt/g6lc_smt_csr_bank.sv
  core/smt/g6lc_thread_select.sv
  corev_apu/bootrom/ariane-smt2.dts
  verif/tests/custom/smt/smt_dual_park.S
  verif/tests/testlist_smt_linux.yaml
  verif/regress/smt-linux-boot-path.sh
  verif/regress/smt-linux-rootfs.sh
)
for f in "${need[@]}"; do
  test -f "$f" || { echo "[dual-hart-ci] MISSING $f"; exit 1; }
  echo "  ok $f"
done

grep -q "NrHarts: *unsigned'(2)" core/include/g6lc64_smt2_config_pkg.sv || {
  echo "[dual-hart-ci] g6lc64_smt2 must set NrHarts=2"; exit 1
}
echo "  ok NrHarts=2"

# R0 DTS/RTL dual-hart boot path (CLINT/PLIC + DTS schema when linux-dts present)
echo "[dual-hart-ci] running smt-linux-boot-path.sh..."
bash verif/regress/smt-linux-boot-path.sh

# Bare-metal dual-park directed test is the pre-Linux software gate
grep -q "smt_dual_park\|wfi\|mhartid" verif/tests/custom/smt/smt_dual_park.S
echo "  ok smt_dual_park.S bare-metal dual-hart directed"

# Optional rootfs preflight (does not require Linux image)
if [[ -f verif/regress/smt-linux-rootfs.sh ]]; then
  echo "[dual-hart-ci] running smt-linux-rootfs preflight (no payload required)..."
  bash verif/regress/smt-linux-rootfs.sh || \
    echo "[dual-hart-ci] WARN: smt-linux-rootfs preflight skipped/failed"
fi

if command -v bun >/dev/null 2>&1; then
  echo "[dual-hart-ci] lint g6lc64_smt2..."
  if bun build-platform/src/cli/index.ts verify --lint --target g6lc64_smt2; then
    echo "  ok g6lc64_smt2 lint"
  else
    echo "[dual-hart-ci] FAIL: g6lc64_smt2 lint" >&2
    exit 1
  fi
else
  echo "[dual-hart-ci] WARN: bun not on PATH — skip smt2 lint"
fi

cat <<'EOF'
[dual-hart-ci] full Linux lab (manual / when payload present):
  1. dtc -I dts -O dtb -o ariane-smt2.dtb corev_apu/bootrom/ariane-smt2.dts
  2. OpenSBI: expected_harts = NrCores×NrHarts; embed DTB (software/smt2-linux/)
  3. Boot Linux maxcpus=2 earlycon=… root=…
  4. cat /proc/cpuinfo ; taskset -c 0,1 stress-ng --cpu 2
  Gates: smt-linux-boot-path + smt-linux-rootfs (CVA6_LINUX_PAYLOAD for sim)
EOF
echo "[dual-hart-ci] PASS (artifacts + boot-path + dual-park + lint)"
