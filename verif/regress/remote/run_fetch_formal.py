#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Bounded live fetch assertions and separate reachability tasks; proxy py only."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys


def main():
    data = Path(os.environ["TH_DATA_DIR"])
    out = Path(os.environ["TH_OUT_DIR"])
    formal = out / "source/core/fetch_B/formal"
    formal.mkdir(parents=True)
    hashes = {}
    selected = os.environ.get("REVIEW_FORMAL_TASK", "")
    if selected not in {"", "g6lc_fetch_iq", "g6lc_fetch_realign", "g6lc_fetch_iq_order", "g6lc_fetch_smt"}:
        raise ValueError("unknown formal task")
    names = [selected] if selected else ["g6lc_fetch_realign", "g6lc_fetch_iq"]
    for name in names:
        task = data / (name + ".sby")
        shutil.copy2(task, formal / task.name)
        for entry in task.read_text().split("[files]\n", 1)[1].splitlines():
            if not entry or entry.startswith("#"):
                continue
            src = data / Path(entry).name
            dst = (formal / entry).resolve()
            if not dst.is_relative_to(out.resolve()):
                raise RuntimeError("task input outside snapshot")
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)
            hashes[str(dst.relative_to(out))] = hashlib.sha256(dst.read_bytes()).hexdigest()
    (out / "sources.json").write_text(json.dumps(hashes, indent=2))
    results = []
    for name in names:
        for mode in ["cover", "prove" if name == "g6lc_fetch_smt" else "bmc"]:
            log_path = out / f"{name}-{mode}.log"
            with log_path.open("w") as log:
                proc = subprocess.Popen(["sby", "-f", name + ".sby", mode], cwd=formal,
                                        stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                try:
                    rc = proc.wait(timeout=120)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGTERM)
                    proc.wait()
                    rc = 124
            status_file = formal / f"{name}_{mode}/status"
            status = status_file.read_text().strip() if status_file.exists() else "MISSING"
            results.append({"task": name, "mode": mode, "rc": rc, "status": status})
            print(results[-1], flush=True)
            print(log_path.read_text()[-2500:], flush=True)
    (out / "result.json").write_text(json.dumps(results, indent=2))
    return 0 if all(r["rc"] == 0 and r["status"].startswith("PASS") for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
