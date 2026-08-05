#!/usr/bin/env bash
set -euo pipefail
export ROOT=/mnt/e/cva6
cd "$ROOT"
export SPIKE_INSTALL_DIR="$ROOT/build-platform/workspace/tooling/spike"
export RISCV=/opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3
export LD_LIBRARY_PATH="$SPIKE_INSTALL_DIR/lib:${LD_LIBRARY_PATH:-}"
export CXX=g++ CC=gcc
export CVA6_REPO_DIR=$ROOT
export DV_TARGET=cv64a6_server_math
VLT_HOME=/root/tools/verilator-v5.008
export VERILATOR_ROOT=$VLT_HOME/share/verilator
# ensure bin
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
echo "[baseline] $(verilator -V 2>&1 | head -1)"
rm -rf "$ROOT/work-ver"
mkdir -p "$ROOT/work-ver" "$ROOT/monorepo-soak"
make -C "$ROOT" verilate \
  verilator="verilator --no-timing -Wno-MODDUP" \
  target="$DV_TARGET" \
  XLEN=64 \
  CVA6_REPO_DIR="$CVA6_REPO_DIR" \
  SPIKE_INSTALL_DIR="$SPIKE_INSTALL_DIR" \
  RISCV="$RISCV" \
  VERILATOR_INSTALL_DIR="$VERILATOR_INSTALL_DIR" \
  CXX="$CXX" CC="$CC" 2>&1 | tee "$ROOT/monorepo-soak/rebuild-baseline-server_math.log"
test -x "$ROOT/work-ver/Variane_testharness"
echo "[baseline] OK $(ls -la work-ver/Variane_testharness)"