#!/usr/bin/env bash
set -euo pipefail
export ROOT=/mnt/e/cva6
cd "$ROOT"
export SPIKE_INSTALL_DIR="$ROOT/build-platform/workspace/tooling/spike"
export RISCV=/opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3
export LD_LIBRARY_PATH="$SPIKE_INSTALL_DIR/lib:${LD_LIBRARY_PATH:-}"
export CXX=g++ CC=gcc
VLT_HOME=/root/tools/verilator-v5.008
export VERILATOR_ROOT=$VLT_HOME/share/verilator
[ -e $VERILATOR_ROOT/verilator_bin ] || ln -sfn $VLT_HOME/bin/verilator_bin $VERILATOR_ROOT/verilator_bin
mkdir -p /tmp/mc-spo-veri-vlt-wrap
cat > /tmp/mc-spo-veri-vlt-wrap/verilator << EOF
#!/usr/bin/env bash
args=()
for a in "\$@"; do
  [[ "\$a" == "-Wno-SIDEEFFECT" ]] && continue
  args+=("\$a")
done
export VERILATOR_ROOT=$VERILATOR_ROOT
exec $VLT_HOME/bin/verilator "\${args[@]}"
EOF
chmod +x /tmp/mc-spo-veri-vlt-wrap/verilator
export PATH="/tmp/mc-spo-veri-vlt-wrap:$VLT_HOME/bin:/usr/bin:$RISCV/bin:$SPIKE_INSTALL_DIR/bin:${PATH}"
export VERILATOR_INSTALL_DIR=${HOME}/tools/oss-cad-suite
# Only rebuild C++ TB object + link (no full re-verilate)
cd work-ver
# Touch to force recompile of ariane_tb
rm -f ariane_tb.o
make -f Variane_testharness.mk ariane_tb.o Variane_testharness \
  CXX="$CXX" \
  CPPFLAGS="-I$VERILATOR_ROOT/include -I$VERILATOR_ROOT/include/vltstd -I$SPIKE_INSTALL_DIR/include -I$ROOT/corev_apu/tb/dpi -std=c++17 -O3 -DVL_DEBUG" \
  2>&1 | tail -40
# Fallback: full make verilate if needed
if [ ! -x Variane_testharness ]; then
  echo "fallback full verilate"
  cd "$ROOT"
  make verilate verilator="verilator --no-timing -Wno-MODDUP" target=cv64a6_server_math XLEN=64 \
    CVA6_REPO_DIR=$ROOT SPIKE_INSTALL_DIR=$SPIKE_INSTALL_DIR RISCV=$RISCV \
    VERILATOR_INSTALL_DIR=$VERILATOR_INSTALL_DIR CXX=$CXX CC=$CC 2>&1 | tail -20
fi
ls -la $ROOT/work-ver/Variane_testharness
# Run probe
export CVA6_MC_PC_PROBE=1
$ROOT/work-ver/Variane_testharness +time_out=100000 +debug_disable +tohost_addr=0x80041730 \
  $ROOT/build-platform/workspace/smt2-linux/fw_payload.elf 2>&1 | tee $ROOT/monorepo-soak/baseline-opensbi-probe-v2.log