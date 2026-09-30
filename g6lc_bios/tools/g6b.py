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


def _pglite_dist_pin() -> dict:
    import tomllib

    pins = tomllib.loads((package_root() / "pins.toml").read_text(encoding="utf-8"))
    return pins["pglite"]["dist"]


def cmd_pglite_dist(args: argparse.Namespace) -> int:
    """Download the pinned npm tarball, SHA-256 verify, extract four dist files.

    Absent bytes are empty, not a compile error. `check()` never calls this.
    """
    import hashlib
    import json
    import tarfile
    import urllib.request

    pin = _pglite_dist_pin()
    root = package_root()
    dest = (root / pin.get("extract_to", ".tools/pglite-dist")).resolve()
    try:
        dest.relative_to(root.resolve())
    except ValueError:
        err(f"pglite-dist extract_to escapes the package: {dest}")
        return 1
    names = list(pin.get("files") or ["pglite.wasm", "initdb.wasm", "pglite.data", "index.js"])
    want_sha = str(pin["sha256"]).lower()
    manifest_path = dest / "manifest.json"
    if not getattr(args, "force", False) and manifest_path.is_file():
        try:
            man = json.loads(manifest_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            man = {}
        if man.get("tarball_sha256") == want_sha and all((dest / n).is_file() for n in names):
            log(f"pglite-dist already extracted at {dest} (sha256={want_sha[:12]}…)")
            return 0

    url = pin["tarball"]
    log(f"pglite-dist: GET {url}")
    dest.mkdir(parents=True, exist_ok=True)
    tgz_path = dest / "pglite.tgz"
    try:
        with urllib.request.urlopen(url, timeout=120) as resp:
            blob = resp.read()
    except OSError as e:
        err(f"pglite-dist download failed: {e}")
        return 1
    got = hashlib.sha256(blob).hexdigest()
    if got != want_sha:
        err(f"pglite-dist sha256 mismatch: got {got} want {want_sha}")
        return 1
    tgz_path.write_bytes(blob)
    extracted: dict[str, int] = {}
    with tarfile.open(tgz_path, "r:gz") as tar:
        for name in names:
            member_name = f"package/dist/{name}"
            try:
                member = tar.getmember(member_name)
            except KeyError:
                err(f"pglite-dist tarball missing {member_name}")
                return 1
            if not member.isfile() or member.size < 1:
                err(f"pglite-dist {member_name} is not a nonempty file")
                return 1
            src = tar.extractfile(member)
            if src is None:
                err(f"pglite-dist cannot read {member_name}")
                return 1
            data = src.read()
            if name.endswith(".wasm") and not data.startswith(b"\0asm"):
                err(f"pglite-dist {name} is not a wasm module")
                return 1
            (dest / name).write_bytes(data)
            extracted[name] = len(data)
            log(f"  {name} {len(data)} bytes")
    manifest = {
        "package": pin.get("package") or pin.get("npm"),
        "version": pin.get("version"),
        "tarball": url,
        "tarball_sha256": got,
        "files": extracted,
    }
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    tgz_path.unlink(missing_ok=True)
    log(f"pglite-dist OK → {dest}")
    return 0


def cmd_store_embed(args: argparse.Namespace) -> int:
    """Emit a first-party dump JSON for `__g6b_store_dump` (not Electric tar).

    `check()` never runs this and never probes the output file.
    """
    import json
    import re

    if not args.fixture or not args.out:
        err("usage: python tools/g6b.py store-embed --fixture FILE --out FILE")
        return 2
    root = package_root()
    src = Path(args.fixture)
    if not src.is_file():
        err(f"store-embed: fixture not found: {src}")
        return 1
    dest = Path(args.out)
    if not dest.is_absolute():
        dest = (root / dest).resolve()
    try:
        dest.relative_to(root.resolve())
    except ValueError:
        err(f"store-embed --out escapes the package: {dest}")
        return 1
    try:
        data = json.loads(src.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as e:
        err(f"store-embed: {e}")
        return 1
    if not isinstance(data, dict):
        err("store-embed: fixture must be a JSON object")
        return 1
    if data.get("g6b_store") != 1:
        err("store-embed: g6b_store must be 1")
        return 1
    uuid = data.get("uuid")
    if not isinstance(uuid, str) or not re.fullmatch(
        r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
        uuid,
    ):
        err("store-embed: uuid must be an RFC 4122 hyphenated id")
        return 1
    purpose = data.get("purpose")
    if not isinstance(purpose, str) or not re.fullmatch(r"[a-z][a-z0-9_]{0,31}", purpose):
        err("store-embed: purpose must match ^[a-z][a-z0-9_]{0,31}$")
        return 1
    tables = data.get("tables")
    if tables is None:
        data["tables"] = {}
    elif not isinstance(tables, dict):
        err("store-embed: tables must be an object")
        return 1
    compact = json.dumps(data, separators=(",", ":"), ensure_ascii=False)
    n = len(compact.encode("utf-8"))
    if n > 256 * 1024:
        err(f"store-embed: dump {n} bytes exceeds max_result_bytes default 256KiB")
        return 1
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(compact + "\n", encoding="utf-8")
    log(f"store-embed OK {n} bytes → {dest}")
    return 0


_BOTAN_MARKER = "kernel-spec/botan/test_data/tls_13_rfc8448/server_certificate.pem"
_BOTAN_URL = "https://github.com/etcimon/botan.git"
_SPEC_SUBMODULES = (
    "g6lc_bios/kernel-spec/goja",
    "g6lc_bios/kernel-spec/TempleOS",
    "g6lc_bios/kernel-spec/lirx-dom",
    "g6lc_bios/kernel-spec/goosie",
)


def _git_toplevel(start: Path) -> Path | None:
    r = subprocess.run(
        ["git", "-C", str(start), "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
        check=False,
    )
    if r.returncode != 0:
        return None
    return Path(r.stdout.strip())


def cmd_spec_sync(args: argparse.Namespace) -> int:
    """Submodule init/pull for kernel-spec + botan marker for g6b-tls tests."""
    root = package_root()
    check_only = bool(getattr(args, "check", False))
    top = _git_toplevel(root)
    if top is not None and not check_only:
        cmd = ["git", "-C", str(top), "submodule", "update", "--init", "--"]
        cmd.extend(_SPEC_SUBMODULES)
        log("+ " + " ".join(cmd))
        subprocess.run(cmd, check=False)
    marker = root / _BOTAN_MARKER
    botan = root / "kernel-spec" / "botan"
    if marker.is_file():
        log(f"botan spec OK {marker}")
        return 0
    if check_only:
        err(f"missing {_BOTAN_MARKER}; run python tools/g6b.py spec-sync")
        return 1
    if (botan / ".git").is_dir():
        log("+ git -C kernel-spec/botan pull --ff-only")
        rc = subprocess.run(["git", "-C", str(botan), "pull", "--ff-only"]).returncode
        return rc if not marker.is_file() else 0
    botan.parent.mkdir(parents=True, exist_ok=True)
    log(f"+ git clone --depth 1 {_BOTAN_URL} {botan}")
    rc = subprocess.run(["git", "clone", "--depth", "1", "--single-branch", _BOTAN_URL, str(botan)]).returncode
    if rc != 0 or not marker.is_file():
        err("botan clone did not produce TLS 1.3 RFC 8448 vectors")
        return 1
    return 0


def cmd_check(args: argparse.Namespace) -> int:
    rust_only = bool(getattr(args, "rust_only", False))
    failed: list[str] = []
    log("--- spec-sync ---")
    if cmd_spec_sync(argparse.Namespace(check=True)) != 0:
        failed.append("spec-sync")
    log("--- independence ---")
    rc = subprocess.run(
        [sys.executable, str(_TOOLS / "check_independence.py")],
        cwd=str(package_root()),
    ).returncode
    if rc != 0:
        failed.append("independence")
    else:
        log("--- native-image-tests ---")
        if subprocess.run([sys.executable, str(_TOOLS / "test_guest_native.py")], cwd=str(package_root())).returncode != 0:
            failed.append("native-image-tests")
        log("--- journal-disk-tests ---")
        if subprocess.run([sys.executable, str(_TOOLS / "test_journal_disk.py")], cwd=str(package_root())).returncode != 0:
            failed.append("journal-disk-tests")
        ui = package_root() / "browser-ui"
        bun = shutil.which("bun")
        log("--- browser-ui ---")
        if rust_only:
            log("skipped (--rust-only); the tracked browser-ui/out artifacts feed the cargo gates")
        elif not bun:
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
    if args.native_manifest:
        argv += ["--native-manifest", args.native_manifest]
    return run_cargo(argv)


def cmd_native(args: argparse.Namespace) -> int:
    from guest_native import main as native_main

    argv = ["--load-address", args.load_address]
    if args.out:
        argv += ["--out", args.out]
    return native_main(argv)


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
    chk = sub.add_parser("check", help="GREEN gate: spec-sync check + independence + bun + cargo")
    chk.add_argument(
        "--rust-only",
        action="store_true",
        help="skip the browser-ui bun test/build lane (CI without the libwasm/svelte-d submodules or LDC)",
    )
    ss = sub.add_parser(
        "spec-sync",
        help="git submodule update --init for kernel-spec + botan fetch/pull for g6b-tls vectors",
    )
    ss.add_argument(
        "--check",
        action="store_true",
        help="fail if botan RFC 8448 vectors are missing (no network)",
    )
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
    elfp.add_argument("--native-manifest")
    nat = sub.add_parser("native")
    nat.add_argument("--load-address", required=True)
    nat.add_argument("--out")
    smk = sub.add_parser("smoke")
    smk.add_argument("--spec")
    smk.add_argument("--out")
    grp = sub.add_parser("gr")
    grp.add_argument("--spec")
    grp.add_argument("--out")
    dpx = sub.add_parser("display-proxy")
    dpx.add_argument("--spec")
    dpx.add_argument("--out")
    pd = sub.add_parser(
        "pglite-dist",
        help="extract pinned @electric-sql/pglite dist into .tools/pglite-dist",
    )
    pd.add_argument(
        "--force",
        action="store_true",
        help="re-download even when manifest sha256 already matches",
    )
    se = sub.add_parser(
        "store-embed",
        help="emit first-party __g6b_store_dump rodata from a fixture (PR3c)",
    )
    se.add_argument("--fixture", help="JSON dump fixture")
    se.add_argument("--out", help="output path")
    args = p.parse_args()
    if args.cmd == "spec-sync":
        return cmd_spec_sync(args)
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
    if args.cmd == "native":
        return cmd_native(args)
    if args.cmd == "smoke":
        return cmd_smoke(args)
    if args.cmd == "gr":
        return cmd_gr(args)
    if args.cmd == "display-proxy":
        return cmd_display_proxy(args)
    if args.cmd == "pglite-dist":
        return cmd_pglite_dist(args)
    if args.cmd == "store-embed":
        return cmd_store_embed(args)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
