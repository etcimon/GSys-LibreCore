#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
"""Pull E3 OpenWrt products from ovh_calltorch via testharness_proxy SSH."""
from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
root = HERE
th_path = None
while root != root.parent:
    cand = root / "verif" / "regress" / "remote" / "testharness_proxy.py"
    if cand.is_file():
        th_path = cand
        break
    root = root.parent
if th_path is None:
    sys.exit("testharness_proxy.py not found walking up from " + str(HERE))

spec = importlib.util.spec_from_file_location("th_proxy", th_path)
mod = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(mod)

dest = HERE.parent / "out" / "loader-run" / "openwrt"
dest.mkdir(parents=True, exist_ok=True)
remote_bin = "/opt/testharness/cache/openwrt/bin/targets/sifiveu/generic"
files = [
    f"{remote_bin}/openwrt-sifiveu-generic-sifive_unleashed-initramfs-kernel.bin",
    f"{remote_bin}/openwrt-sifiveu-generic-rootfs.cpio.gz",
    f"{remote_bin}/sha256sums",
    f"{remote_bin}/openwrt-sifiveu-generic-sifive_unleashed.manifest",
    "/opt/testharness/cache/openwrt/build_dir/target-riscv64_riscv64_musl/linux-sifiveu_generic/Image",
]

rem = mod.Remote(mod.HOST)
rem.timeout = 120.0
try:
    rem.start_master()
    listing = rem.out(f"ls -l --time-style=long-iso {remote_bin}")
    print(listing)
    for f in files:
        rem.pull(f, dest)
    print("===== local =====")
    for p in sorted(dest.iterdir()):
        print(f"{p.stat().st_size:10d}  {p.name}")
    print("PULL_PRODUCTS_OK")
finally:
    rem.close()
