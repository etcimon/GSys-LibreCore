#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
"""Run the OpenWrt graphics probe on the existing remote QEMU builder."""
from __future__ import annotations

import argparse
import importlib.util
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load_proxy():
    root = HERE
    while root != root.parent:
        cand = root / "verif" / "regress" / "remote" / "testharness_proxy.py"
        if cand.is_file():
            spec = importlib.util.spec_from_file_location("th_proxy", cand)
            mod = importlib.util.module_from_spec(spec)
            assert spec.loader is not None
            spec.loader.exec_module(mod)
            return mod
        root = root.parent
    sys.exit("testharness_proxy.py not found walking up from " + str(HERE))


def main() -> int:
    mod = load_proxy()
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--host", default=mod.HOST)
    ap.add_argument("--root", default="/opt/testharness")
    ap.add_argument("--qemu-root", default="/opt/testharness/g6lc-qemu")
    ap.add_argument("--overlay", default=None)
    ap.add_argument("--qemu", default=None)
    ap.add_argument("--kernel", default=None)
    ap.add_argument("--mode", choices=("gl", "vugpu", "2d"), default="vugpu")
    ap.add_argument("--tag", default=None)
    ap.add_argument("--timeout", type=int, default=240)
    ap.add_argument("--out", default=None)
    ap.add_argument("--negative", action="store_true")
    ap.add_argument("--audit", action="store_true")
    ap.add_argument(
        "--cap-profile",
        choices=("none", "gles2-min", "gles2-xfer"),
        default="none",
    )
    ap.add_argument("--no-push", action="store_true")
    args = ap.parse_args()

    overlay = args.overlay or f"{args.root}/cache/openwrt-overlay"
    qemu = args.qemu or f"{args.qemu_root}/build/qemu/qemu-system-riscv64"
    runs = f"{args.root}/runs"
    tag = args.tag or f"gfx-{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}"
    local_out = Path(args.out) if args.out else HERE.parent / "out" / "remote-gfx" / tag
    local_out.mkdir(parents=True, exist_ok=True)

    if not args.no_push:
        push = subprocess.run(
            [sys.executable, str(HERE / "push-overlay.py")],
            check=False,
        )
        if push.returncode != 0:
            return int(push.returncode)

    rem = mod.Remote(args.host)
    rem.timeout = float(args.timeout + 60)
    try:
        rem.start_master()
        res = rem.run(
            f"mkdir -p {shlex.quote(overlay)} {shlex.quote(runs)}",
            check=False,
            capture=True,
        )
        if res.returncode != 0:
            sys.stderr.write(res.stderr or res.stdout or "")
            return int(res.returncode)
        cmd = [
            "env",
            f"OPENWRT_SRC={shlex.quote(args.root + '/cache/openwrt')}",
            f"G6Q_REMOTE_QEMU={shlex.quote(qemu)}",
            f"TH_RUNS={shlex.quote(runs)}",
            "bash",
            shlex.quote(f"{overlay}/remote-gfx-probe.sh"),
            "--mode", args.mode,
            "--tag", tag,
            "--timeout", str(args.timeout),
        ]
        if args.negative:
            cmd.append("--negative")
        if args.audit:
            cmd.append("--audit")
        if args.cap_profile != "none":
            cmd += ["--cap-profile", args.cap_profile]
        if args.kernel:
            cmd += ["--kernel", shlex.quote(args.kernel)]
        res = rem.run(" ".join(cmd), check=False, capture=True)
        stdout = res.stdout or ""
        stderr = res.stderr or ""
        sys.stdout.write(stdout)
        sys.stderr.write(stderr)
        (local_out / "probe.stdout.log").write_text(stdout, encoding="utf-8")
        if stderr:
            (local_out / "probe.stderr.log").write_text(stderr, encoding="utf-8")

        for key in ("QEMU_LOG", "SERIAL_LOG", "BACKEND_LOG"):
            m = re.search(rf"^{key}=(\S+)", stdout, re.MULTILINE)
            if not m:
                continue
            remote_path = m.group(1)
            got = rem.run(f"cat {shlex.quote(remote_path)}", check=False, capture=True)
            if got.returncode == 0:
                (local_out / Path(remote_path).name).write_text(
                    got.stdout or "", encoding="utf-8", errors="replace"
                )

        m = re.search(r"^CAPTURE_DIR=(\S+)", stdout, re.MULTILINE)
        if m:
            remote_cap = m.group(1)
            local_cap = local_out / "capture"
            scp = subprocess.run(
                ["scp", "-r", *rem.base_opts(), f"{rem.host}:{remote_cap}", str(local_cap)],
                check=False,
                capture_output=True,
                text=True,
            )
            if scp.returncode != 0:
                sys.stderr.write(scp.stderr or scp.stdout or "")
            else:
                print(f"LOCAL_CAPTURE_DIR={local_cap}")
                summary_cmd = [
                    sys.executable,
                    str(HERE / "summarize-virgl-capture.py"),
                    str(local_cap),
                    "--strict",
                ]
                if args.negative:
                    summary_cmd.append("--expect-errors")
                if args.audit:
                    summary_cmd.append("--expect-audit")
                subprocess.run(summary_cmd, check=False)
        print(f"LOCAL_LOG_DIR={local_out}")
        return int(res.returncode)
    finally:
        rem.close()


if __name__ == "__main__":
    raise SystemExit(main())
