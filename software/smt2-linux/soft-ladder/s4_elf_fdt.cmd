ELF=/opt/testharness/runs/linux-g6lc64_server_math_v/fw_payload.elf
python3 - <<'PY'
from pathlib import Path
data=Path("/opt/testharness/runs/linux-g6lc64_server_math_v/fw_payload.elf").read_bytes()
# PT_LOAD va 0x80000000 fileoff 0x1000 → VA 0x8001e000 is fileoff 0x1f000
off=0x1f000
mag=data[off:off+4]
print("magic", mag.hex(), "expect d00dfeed")
# totalsize BE at +4
tsz=int.from_bytes(data[off+4:off+8],"big")
print("tsz", hex(tsz))
Path("/tmp/fw_fdt.bin").write_bytes(data[off:off+tsz])
print("wrote /tmp/fw_fdt.bin", tsz)
PY
dtc -I dtb -O dts /tmp/fw_fdt.bin 2>/dev/null | grep -E "cpu@|hart|cpus|reg = <|status" | head -60
echo "=== cpu@ count ==="
dtc -I dtb -O dts /tmp/fw_fdt.bin 2>/dev/null | grep -c "cpu@"
