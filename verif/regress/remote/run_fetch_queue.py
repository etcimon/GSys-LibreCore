#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Run a copied live-IQ diagnostic through testharness_proxy.py py --data inputs."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


def main():
    data = Path(os.environ["TH_DATA_DIR"])
    out = Path(os.environ["TH_OUT_DIR"])
    names = ["config_pkg.sv", "g6lc64_smt2_config_pkg.sv", "riscv_pkg.sv", "ariane_pkg.sv", "g6lc_fetch_pkg.sv",
             "cva6_fifo_v3.sv", "instr_queue.sv", "tb_g6lc_fetch_queue.sv"]
    sources = []
    hashes = {}
    source_dir = out / "source"
    source_dir.mkdir(exist_ok=True)
    for name in names:
        src = data / name
        if not src.is_file():
            raise RuntimeError(f"missing uploaded source: {name}")
        dst = source_dir / name
        shutil.copy2(src, dst)
        hashes[name] = hashlib.sha256(dst.read_bytes()).hexdigest()
        sources.append(str(dst))
    (out / "sources.json").write_text(json.dumps(hashes, indent=2) + "\n")
    verilator = shutil.which("verilator")
    if not verilator:
        raise RuntimeError("Verilator missing from proxy environment")
    results = []
    for slots, issue, harts in [(4, 2, 2), (2, 1, 1), (8, 2, 2)]:
        work = out / f"s{slots}-i{issue}-h{harts}"
        work.mkdir()
        command = [verilator, "--binary", "--timing", "--assert", "--threads", "1",
                   "-Wno-fatal", "--top-module", "tb_g6lc_fetch_queue",
                   f"-GSLOTS={slots}", f"-GISSUE={issue}", f"-GHARTS={harts}",
                   "--Mdir", str(work), "-o", "queue-test", *sources]
        (work / "build-command.json").write_text(json.dumps(command) + "\n")
        with (work / "build.log").open("w") as log:
            build = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=180)
        if build.returncode:
            print((work / "build.log").read_text()[-10000:])
            return build.returncode
        exe = work / "queue-test"
        result = subprocess.run([str(exe)], capture_output=True, text=True,
                                env={"PATH": "/usr/bin:/bin"}, timeout=30)
        text = result.stdout + result.stderr
        (work / "sim.log").write_text(text)
        print(f"s{slots}/i{issue}/h{harts}: {text[-3000:]}", flush=True)
        ok = result.returncode == 0 and text.count("FETCH_QUEUE_PASS ") == 1
        results.append({"slots": slots, "issue": issue, "harts": harts,
                        "rc": result.returncode, "pass": ok,
                        "executableSha256": hashlib.sha256(exe.read_bytes()).hexdigest()})
    (out / "result.json").write_text(json.dumps({"strictQualification": False,
        "kind": "rtl-leaf-diagnostic", "results": results}, indent=2) + "\n")
    return 0 if all(r["pass"] for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
