#!/bin/bash
# Probe a directed ELF on a model: extract tohost, run to completion (or cap),
# report wall time + perf instructions. Usage: probe_run.sh MODEL ELF [CAP]
set -u
M="$1"; E="$2"; CAP="${3:-500000}"
NM=/opt/testharness/toolchains/xpack-riscv-none-elf-gcc-14.2.0-3/bin/riscv-none-elf-nm
TH=$($NM "$E" 2>/dev/null | awk '$3=="tohost"{print "0x"$1; exit}')
TH=${TH:-0xdeadbeef}
echo "elf=$E tohost=$TH cap=$CAP"
/usr/bin/time -f "wall=%e" perf stat -e instructions,cycles \
  -- "$M" +debug_disable +quiet_axi +max-cycles=$CAP +time_out=$CAP \
  +tohost_addr=$TH "$E" > /tmp/probe-out.log 2>/tmp/probe-perf.log
tail -12 /tmp/probe-out.log
grep -E "instructions:|cycles:|wall=" /tmp/probe-perf.log
