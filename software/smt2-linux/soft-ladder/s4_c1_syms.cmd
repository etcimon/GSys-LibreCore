ELF=/opt/testharness/runs/linux-g6lc64_server_math_v/fw_payload.elf
NM=/opt/testharness/toolchains/xpack-riscv-none-elf-gcc-14.2.0-3/bin/riscv-none-elf-nm
OBJ=/opt/testharness/toolchains/xpack-riscv-none-elf-gcc-14.2.0-3/bin/riscv-none-elf-objdump
echo "=== nm nearest ==="
"$NM" "$ELF" | awk '{print $1,$2,$3}' | grep -E '^[0-9a-f]{16}' | sort |
  awk 'BEGIN{t[1]="800003d0";t[2]="80040460";t[3]="80046e10";t[4]="80046f2c";t[5]="800002f0";t[6]="800400b8"}
       {a=$1} 
       END{}'
"$NM" "$ELF" | grep -E "start_hang|_wait_for_boot|_trap_handler|switch_mode|fw_next|payload|sbi_init|generic_cold" | head -40
echo "=== objdump 3c0..3e0 ==="
"$OBJ" -d --start-address=0x800003c0 --stop-address=0x800003e8 "$ELF"
echo "=== objdump 2e0..310 ==="
"$OBJ" -d --start-address=0x800002e0 --stop-address=0x80000310 "$ELF"
echo "=== nm around 80040460 ==="
"$NM" "$ELF" | awk '$1 ~ /^0000000080040/ {print}'
echo "=== readelf 80040000 ==="
readelf -l "$ELF" | head -30
