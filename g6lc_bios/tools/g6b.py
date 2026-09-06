#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# PRIMARY CLI for g6lc_bios. GREEN COMMAND: python tools/g6b.py check

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

_TOOLS = Path(__file__).resolve().parent
if str(_TOOLS) not in sys.path:
    sys.path.insert(0, str(_TOOLS))

from env_common import cargo_bin, contained_env, package_root  # noqa: E402


def log(msg: str) -> None:
    print(f"[g6b] {msg}")


def err(msg: str) -> None:
    print(f"[g6b] ERROR: {msg}", file=sys.stderr)


def cargo_cmd() -> str:
    contained = cargo_bin()
    if contained.is_file():
        return str(contained)
    found = shutil.which("cargo")
    if found:
        return found
    return "cargo"


def run_cargo(argv: list[str]) -> int:
    env = contained_env() if cargo_bin().is_file() else os.environ.copy()
    cmd = [cargo_cmd(), *argv]
    log("+ " + " ".join(cmd))
    return subprocess.run(cmd, cwd=str(package_root()), env=env).returncode


def cmd_check(_: argparse.Namespace) -> int:
    failed: list[str] = []
    log("--- independence ---")
    rc = subprocess.run(
        [sys.executable, str(_TOOLS / "check_independence.py")],
        cwd=str(package_root()),
    ).returncode
    if rc != 0:
        failed.append("independence")
    else:
        ui = package_root() / "browser-ui"
        bun = shutil.which("bun")
        log("--- browser-ui ---")
        if not bun:
            err("bun not on PATH (browser-ui)")
            failed.append("browser-ui")
        else:
            for name, argv in [("browser-ui-test", ["test"]), ("browser-ui-build", ["run", "build"])]:
                log(f"--- {name} ---")
                log("+ bun " + " ".join(argv))
                if subprocess.run([bun, *argv], cwd=str(ui)).returncode != 0:
                    failed.append(name)
                    break
        if not failed:
            for name, argv in [
                ("fmt", ["fmt", "--all", "--check"]),
                ("clippy", ["clippy", "--workspace", "--all-targets", "--", "-D", "warnings"]),
                ("test", ["test", "--workspace"]),
            ]:
                log(f"--- {name} ---")
                if run_cargo(argv) != 0:
                    failed.append(name)
                    break
    if failed:
        err("check FAILED: " + ", ".join(failed))
        return 1
    log("check OK")
    return 0


def cmd_design(args: argparse.Namespace) -> int:
    spec = args.spec
    out = args.out or str(package_root() / "out")
    return run_cargo(
        [
            "run",
            "-p",
            "g6b-cli",
            "--",
            "design-compile",
            "--spec",
            spec,
            "--out",
            out,
        ]
    )


def cmd_display(args: argparse.Namespace) -> int:
    argv = ["run", "-p", "g6b-cli", "--", args.cmd]
    if args.spec:
        argv += ["--spec", args.spec]
    return run_cargo(argv)


def cmd_qemu_args(args: argparse.Namespace) -> int:
    argv = ["run", "-p", "g6b-cli", "--", "qemu-args"]
    if args.spec:
        argv += ["--spec", args.spec]
    if args.vnc is not None:
        argv += ["--vnc", args.vnc]
    if args.no_gl:
        argv += ["--no-gl"]
    return run_cargo(argv)


def cmd_holyc_eval(args: argparse.Namespace) -> int:
    argv = ["run", "-p", "g6b-cli", "--", "holyc-eval"]
    if args.spec:
        argv += ["--spec", args.spec]
    return run_cargo(argv)


def cmd_holyc_serve(args: argparse.Namespace) -> int:
    argv = ["run", "-p", "g6b-cli", "--", args.cmd]
    if args.spec:
        argv += ["--spec", args.spec]
    if args.port is not None:
        argv += ["--port", str(args.port)]
    if args.once:
        argv.append("--once")
    return run_cargo(argv)


def cmd_display_proxy(args: argparse.Namespace) -> int:
    argv = ["run", "-p", "g6b-cli", "--", "display-proxy"]
    if args.spec:
        argv += ["--spec", args.spec]
    if args.out:
        argv += ["--out", args.out]
    return run_cargo(argv)


def cmd_gr(args: argparse.Namespace) -> int:
    argv = ["run", "-p", "g6b-cli", "--", "gr"]
    if args.spec:
        argv += ["--spec", args.spec]
    if args.out:
        argv += ["--out", args.out]
    return run_cargo(argv)


def cmd_smoke(args: argparse.Namespace) -> int:
    argv = ["run", "-p", "g6b-cli", "--", "smoke"]
    if args.spec:
        argv += ["--spec", args.spec]
    if getattr(args, "out", None):
        argv += ["--out", args.out]
    return run_cargo(argv)


def cmd_elf(args: argparse.Namespace) -> int:
    argv = ["run", "-p", "g6b-cli", "--", "elf"]
    if args.spec:
        argv += ["--spec", args.spec]
    if args.out:
        argv += ["--out", args.out]
    return run_cargo(argv)


def cmd_regress(args: argparse.Namespace) -> int:
    script = _TOOLS / "bios_regress.py"
    cmd = [sys.executable, str(script)]
    if args.spec:
        cmd += ["--spec", args.spec]
    log("+ " + " ".join(cmd))
    return subprocess.run(cmd, cwd=str(package_root())).returncode


def main() -> int:
    p = argparse.ArgumentParser(prog="g6b")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("check")
    d = sub.add_parser("design-compile")
    d.add_argument("--spec", required=True)
    d.add_argument("--out")
    disp = sub.add_parser("display")
    disp.add_argument("--spec")
    boot = sub.add_parser("boot")
    boot.add_argument("--spec")
    qa = sub.add_parser("qemu-args")
    qa.add_argument("--spec")
    qa.add_argument("--vnc", help="VNC display number (host frontend, 5900+N)")
    qa.add_argument("--no-gl", action="store_true",
                    help="2D virtio-gpu fallback for hosts without a DRM render node")
    he = sub.add_parser("holyc-eval")
    he.add_argument("--spec")
    hs = sub.add_parser("holyc-serve")
    hs.add_argument("--spec")
    hs.add_argument("--port", type=int)
    hs.add_argument("--once", action="store_true")
    httpsv = sub.add_parser("http-serve")
    httpsv.add_argument("--spec")
    httpsv.add_argument("--port", type=int)
    httpsv.add_argument("--once", action="store_true")
    lb = sub.add_parser("loopback")
    lb.add_argument("--spec")
    lb.add_argument("--port", type=int)
    lb.add_argument("--once", action="store_true")
    rg = sub.add_parser("regress")
    rg.add_argument("--spec")
    elfp = sub.add_parser("elf")
    elfp.add_argument("--spec")
    elfp.add_argument("--out")
    smk = sub.add_parser("smoke")
    smk.add_argument("--spec")
    smk.add_argument("--out")
    grp = sub.add_parser("gr")
    grp.add_argument("--spec")
    grp.add_argument("--out")
    dpx = sub.add_parser("display-proxy")
    dpx.add_argument("--spec")
    dpx.add_argument("--out")
    args = p.parse_args()
    if args.cmd == "check":
        rc = cmd_check(args)
        if rc != 0:
            return rc
        log("--- bios-regress ---")
        return cmd_regress(argparse.Namespace(spec=None))
    if args.cmd == "design-compile":
        return cmd_design(args)
    if args.cmd in ("display", "boot"):
        return cmd_display(args)
    if args.cmd == "qemu-args":
        return cmd_qemu_args(args)
    if args.cmd == "holyc-eval":
        return cmd_holyc_eval(args)
    if args.cmd in ("holyc-serve", "loopback", "http-serve"):
        return cmd_holyc_serve(args)
    if args.cmd == "regress":
        return cmd_regress(args)
    if args.cmd == "elf":
        return cmd_elf(args)
    if args.cmd == "smoke":
        return cmd_smoke(args)
    if args.cmd == "gr":
        return cmd_gr(args)
    if args.cmd == "display-proxy":
        return cmd_display_proxy(args)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
