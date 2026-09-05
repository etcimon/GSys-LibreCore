#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Real descriptor helper/engine format boundary, isolated remote Verilator only."""

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import uuid

SOURCES = (
    "core/include/config_pkg.sv",
    "core/include/g6lc64_ai_config_pkg.sv",
    "core/include/build_config_pkg.sv",
    "corev_apu/ai_island/include/g6lc_ai_desc_pkg.sv",
    "corev_apu/ai_island/g6lc_ai_desc_engine.sv",
    "verif/tb/ai_island/tb_g6lc_ai_desc_formats.sv",
    "verif/tb/ai_island/desc_formats_main.cpp",
)
TOP = "tb_g6lc_ai_desc_formats"


def dispatch(args):
    root = Path(__file__).resolve().parents[2]
    proxy = root / "verif/regress/remote/testharness_proxy.py"
    files = [root / source for source in SOURCES]
    for path in [proxy, *files]:
        if not path.is_file():
            raise RuntimeError("missing input: " + str(path))
    tag = "ai-desc-formats-" + datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:12]

    def proxy_path(path):
        if os.name != "nt":
            return str(path)
        if len(path.drive) != 2:
            raise RuntimeError("WSL requires drive-qualified paths")
        return "/mnt/" + path.drive[0].lower() + path.as_posix()[2:]

    launcher = ["wsl.exe", "--exec", "python3"] if os.name == "nt" else [sys.executable]
    command = [*launcher, proxy_path(proxy), "py", proxy_path(Path(__file__).resolve()),
               "--tag", tag, "--threads", "1", "--pull"]
    for path in files:
        command.extend(("--data", proxy_path(path)))
    print("PROXY_ONLY " + shlex.join(command), flush=True)
    print("PULL_OUTPUT " + str(root / "remote-runs" / tag / "output"), flush=True)
    return 0 if args.dry_run else subprocess.run(command, cwd=root, check=False).returncode


def remote():
    data = Path(os.environ["TH_DATA_DIR"]).resolve()
    parent = Path(os.environ["TH_OUT_DIR"]).resolve()
    if not data.is_dir() or not parent.is_dir():
        raise RuntimeError("proxy data/output parents must exist")
    out = Path(tempfile.mkdtemp(prefix="desc-formats-results-", dir=parent))
    work = Path(tempfile.mkdtemp(prefix="g6lc-desc-formats-build-"))
    snapshots = out / "sources"
    snapshots.mkdir()
    report = {"status": "RUNNING", "scope": "descriptor helper and engine handoff, not full GEMM/SoC", "sha256": {}}
    try:
        for source in SOURCES:
            original = data / Path(source).name
            target = snapshots / original.name
            shutil.copy2(original, target)
            report["sha256"][source] = hashlib.sha256(target.read_bytes()).hexdigest()
        report["runner_sha256"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        tool = Path("/opt/testharness/toolchains/verilator-v5.008/bin/verilator")

        def run(command, name):
            print("RUN " + shlex.join(map(str, command)), flush=True)
            result = subprocess.run(list(map(str, command)), cwd=snapshots, capture_output=True,
                                    text=True, check=False, timeout=900)
            text = result.stdout + result.stderr
            (out / (name + ".log")).write_text(text + "\nRETURN_CODE " + str(result.returncode) + "\n", encoding="utf-8")
            if result.returncode or "%Warning" in text:
                print(text, flush=True)
                raise RuntimeError(name + " failed or emitted Verilator warnings")
            return text

        report["verilator"] = run([tool, "--version"], "version").strip()
        if "Verilator 5.008" not in report["verilator"]:
            raise RuntimeError("Verilator 5.008 required; no tool install/fallback")
        # No blanket waiver file and no -Wno-fatal: enabled diagnostics are fatal.
        sv = [snapshots / Path(source).name for source in SOURCES if source.endswith(".sv")]
        run([tool, "--lint-only", "--assert", "--top-module", TOP, *sv], "lint")
        run([tool, "--cc", "--exe", "--build", "--assert", "-j", "2", "--top-module", TOP,
             "--Mdir", work, "-CFLAGS", "-std=c++17 -Wall -Wextra -Werror", *sv,
             snapshots / "desc_formats_main.cpp"], "build")
        text = run([work / ("V" + TOP)], "simulation")
        marker = "PASS desc_formats helpers=3072 wide_mask=1024 engines=1024 starts=4 mask=3 enums=0..7"
        if marker not in text or "CORE_CONFIG PASS MatrixEn=1" not in text:
            raise RuntimeError("missing exhaustive/core-config pass marker")
        print(text, flush=True)
        report.update(status="PASS", result=marker)
    except Exception as error:
        report.update(status="FAIL", error=str(error))
        raise
    finally:
        (out / "results.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print("RESULTS " + str(out / "results.json"), flush=True)
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    return remote() if os.environ.get("TH_DATA_DIR") else dispatch(args)


if __name__ == "__main__":
    sys.exit(main())
