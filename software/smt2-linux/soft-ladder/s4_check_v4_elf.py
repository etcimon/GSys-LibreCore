#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
import hashlib
import struct
import subprocess
from pathlib import Path

elf_path = Path("/mnt/e/cva6/build-platform/workspace/smt2-linux-v4/fw_payload.elf")
data = elf_path.read_bytes()
print("elf md5", hashlib.md5(data).hexdigest(), "size", len(data))
need = bytes.fromhex("d00dfeed")
idx = data.find(need)
print("fdt at", hex(idx) if idx >= 0 else None)
if idx < 0:
    raise SystemExit(1)
tsz = int.from_bytes(data[idx + 4 : idx + 8], "big")
dtb = Path("/tmp/v4embed.dtb")
dtb.write_bytes(data[idx : idx + tsz])
print("tsz", hex(tsz))
out = subprocess.check_output(["dtc", "-I", "dtb", "-O", "dts", str(dtb)], text=True)
cpus = [ln.strip() for ln in out.splitlines() if "cpu@" in ln]
print("cpu count", len(cpus))
for ln in cpus:
    print(" ", ln)
for key in ("maxcpus", "model"):
    for ln in out.splitlines():
        if key in ln:
            print(ln.strip())
            break
# confirm pin/i4dp not overwritten
pin = Path("/mnt/e/cva6/software/smt2-linux/soft-ladder/build/fw_payload_r3a_c15_plat_skip.pin-bc7ed11d.elf")
if pin.is_file():
    print("pin md5", hashlib.md5(pin.read_bytes()).hexdigest())
