#!/usr/bin/env bash
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
# Read-only builder inspection through testharness_proxy.py shell --cmd-file.
set -eu
python3 - <<'PY'
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

root = Path("/opt/testharness")
runtime = root / "runs/review-private-runtime-20260915/runtime/include/verilated_funcs.h"
tools = {
    "verilator": root / "src/verilator-causal/bin/verilator",
    "gcc": root / "toolchains/xpack-riscv-none-elf-gcc-14.2.0-3/bin/riscv-none-elf-gcc",
    "spike": root / "toolchains/spike/bin/spike",
}
memory = dict(line.split(":", 1) for line in Path("/proc/meminfo").read_text().splitlines())
result = {
    "cpus": os.cpu_count(), "load": os.getloadavg(),
    "available_memory": memory.get("MemAvailable", "").strip(),
    "free_disk_bytes": shutil.disk_usage(root).free,
    "runtime_sha256": hashlib.sha256(runtime.read_bytes()).hexdigest()
    if runtime.is_file() else None,
    "tools": {name: {"path": str(path), "exists": path.is_file()}
              for name, path in tools.items()},
    "processes": subprocess.run(
        ["ps", "-eo", "pid,pcpu,comm", "--sort=-pcpu"],
        capture_output=True, text=True, check=True).stdout.splitlines()[:15],
}
for name, path in tools.items():
    if path.is_file():
        result["tools"][name]["version"] = subprocess.run(
            [str(path), "--version"], capture_output=True, text=True,
            timeout=15, check=False).stdout.splitlines()[:2]
print(json.dumps(result, indent=2))
PY
