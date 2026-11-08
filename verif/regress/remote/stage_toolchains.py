#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
"""Stage wiped testharness toolchains from proxy --data uploads.

Moves data/verilator-v5.008-wsl -> /opt/testharness/toolchains/verilator-v5.008
(stock pinned runtime headers verified by hash) and
data/verilator         -> /opt/testharness/src/verilator-g6lc
(the tools/verilator g6lc-fork checkout at gitlink bc8d406c3).

Verifies identities and prints them; never overwrites a populated target.
"""
import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path("/opt/testharness")
DATA = Path("data")


def sha(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def move(src: Path, dst: Path, expect: str) -> dict:
    if dst.exists():
        # already staged: verify identity marker instead of overwriting
        marker = dst / ".stage-ok"
        return {"dst": str(dst), "action": "present", "marker": marker.exists()}
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(src), str(dst))
    (dst / ".stage-ok").write_text(expect + "\n")
    return {"dst": str(dst), "action": "moved", "from": str(src)}


def main() -> int:
    out = []
    vlt = DATA / "verilator-v5.008-wsl"
    fork = DATA / "verilator"
    if not vlt.is_dir():
        print(f"FATAL: missing {vlt}", file=sys.stderr)
        return 2
    if not fork.is_dir():
        print(f"FATAL: missing {fork}", file=sys.stderr)
        return 2

    # 1. stock pinned toolchain (provision.sh skips when bin/verilator exists)
    dst_vlt = ROOT / "toolchains" / "verilator-v5.008"
    r = move(vlt, dst_vlt, "stock-v5.008-wsl")
    hdr = dst_vlt / "share" / "verilator" / "include" / "verilated_funcs.h"
    r["headerSha256"] = sha(hdr) if hdr.is_file() else None
    r["headerPinned"] = (
        r["headerSha256"]
        == "8c408609b477f5d29c0897bf5412c8417676f9ea66c6622809c1796b4ac3099e"
    )
    r["verilatorBinSha256"] = sha(dst_vlt / "bin" / "verilator_bin") if (dst_vlt / "bin" / "verilator_bin").is_file() else None
    out.append(r)

    # 2. fork source checkout for install-verilator-g6lc.sh (VLT_SRC)
    dst_fork = ROOT / "src" / "verilator-g6lc"
    r = move(fork, dst_fork, "g6lc-bc8d406c3")
    r["v3const"] = (dst_fork / "src" / "V3Const.cpp").is_file()
    # neutralize the submodule gitfile pointer (points into absent parent .git)
    gitfile = dst_fork / ".git"
    if gitfile.is_file():
        gitfile.unlink()
    out.append(r)

    # 3. report toolchain state
    for cmd in (
        ["bash", "-lc", f"{dst_vlt}/bin/verilator --version 2>&1 | head -1"],
        ["bash", "-lc", f"sha256sum {dst_vlt}/bin/verilator_bin | cut -d' ' -f1"],
        ["bash", "-lc", "ls /opt/testharness/toolchains/ /opt/testharness/src/ 2>/dev/null"],
    ):
        p = subprocess.run(cmd, capture_output=True, text=True)
        out.append({"probe": cmd[-1], "rc": p.returncode, "out": p.stdout.strip()[:500]})

    print(json.dumps({"staged": out}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
