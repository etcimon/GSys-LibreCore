#!/bin/bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
export PATH="/root/tools/verilator-v5.008/bin:/opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin:/root/tools/spike/bin:${PATH}"
export LD_LIBRARY_PATH="/root/tools/spike/lib:${LD_LIBRARY_PATH:-}"
export SPIKE_INSTALL_DIR="${SPIKE_INSTALL_DIR:-/root/tools/spike}"
export RISCV="${RISCV:-$SPIKE_INSTALL_DIR}"
export CVA6_REPO_DIR="$ROOT"
export CROSS_COMPILE=riscv-none-elf-

echo "[gate] incremental verilate imafdc..."
# Do NOT wipe work-ver — incremental if possible
make -C "$ROOT" verilate \
  verilator="verilator --no-timing" \
  target=cv64a6_imafdc_sv39 \
  XLEN=64 \
  CVA6_REPO_DIR="$CVA6_REPO_DIR" \
  SPIKE_INSTALL_DIR="$SPIKE_INSTALL_DIR" \
  RISCV="$RISCV" 2>&1 | tee /tmp/verilate_inc.log | tail -30

test -x work-ver/Variane_testharness || { echo "no harness"; exit 1; }

COMMON=verif/tests/custom/common
H=work-ver/Variane_testharness

mksize() {
  local n=$1
  cat > "work-ver/fv_${n}.S" << EOF
  .globl main
main:
  li   t0, ${n}
  sub  sp, sp, t0
  mv   s0, sp
  mv   t0, s0
  li   t1, ${n}
1:
  sub  t2, t0, s0
  xor  t3, t0, t2
  sd   t3, 0(t0)
  addi t0, t0, 8
  addi t1, t1, -8
  bnez t1, 1b
  mv   t0, s0
  li   t1, ${n}
2:
  sub  t2, t0, s0
  xor  t3, t0, t2
  ld   t4, 0(t0)
  bne  t3, t4, fail
  addi t0, t0, 8
  addi t1, t1, -8
  bnez t1, 2b
  li   t0, ${n}
  add  sp, sp, t0
  li   a0, 0
  jal  exit
fail:
  li   t0, ${n}
  add  sp, sp, t0
  li   a0, 1
  jal  exit
EOF
  riscv-none-elf-gcc -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles \
    -Iverif/tests/custom/env -I"$COMMON" "$COMMON/syscalls.c" "$COMMON/crt.S" "work-ver/fv_${n}.S" \
    -T "$COMMON/link_verilator.ld" -o "work-ver/fv_${n}.o" \
    -march=rv64imafdc_zicsr_zifencei -mabi=lp64d
}

runone() {
  local elf=$1 cycles=$2 name=$3
  local th
  th=$(riscv-none-elf-nm "$elf" | awk '$3=="tohost"{print $1; exit}')
  echo -n "$name "
  set +e
  timeout 90 "$H" +max-cycles="$cycles" +time_out="$cycles" +debug_disable +tohost_addr=0x$th "$elf" >"/tmp/g2_${name}.log" 2>&1
  set -e
  grep -E 'SUCCESS|FAILED' "/tmp/g2_${name}.log" | tail -1
}

for n in 64 128 160 256 512; do
  mksize $n
  runone "work-ver/fv_${n}.o" 300000 "fv${n}"
done

# stream suite
export MC_SPO_VERI_REBUILD=0
export MC_SPO_VERI_FORCE_IMAFDC=1
export MC_SPO_VERI_REBUILD_ELF=1
export MC_SPO_VERI_TESTS="mc_stream_plane mc_spo_cas_stream mc_spo_st_fwd"
export MC_SPO_VERI_CYCLES=2000000
bash verif/regress/mc-spo-veri.sh 2>&1 | tee /tmp/suite2.log | grep -E 'PASS|FAIL|SUMMARY|SUCCESS|FAILED|==='
