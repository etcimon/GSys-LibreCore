#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
"""Create an isolated config-package overlay without editing checked-in packages.

Only allowlisted fields may change. The derived flist replaces exactly the
selected ``${TARGET_CFG}_config_pkg.sv`` path. Experimental N=1/N=2 overlays
are not Linux SKUs.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

ALLOWED = {
    "L2RoundRobinEn": re.compile(
        r"(L2RoundRobinEn:\s*bit'\()([01])(\))"
    ),
}


def die(msg: str) -> None:
    print(f"[isolated-overlay] {msg}", file=sys.stderr)
    raise SystemExit(2)


def parse_fields(items: list[str]) -> dict[str, str]:
    fields: dict[str, str] = {}
    for item in items:
        if "=" not in item:
            die(f"field must be NAME=VALUE, got {item!r}")
        name, value = item.split("=", 1)
        if name not in ALLOWED:
            die(f"field {name!r} is not allowlisted; permitted: {sorted(ALLOWED)}")
        if not re.fullmatch(r"[01]", value):
            die(f"{name} value must be 0 or 1")
        fields[name] = value
    if not fields:
        die("no overlay fields")
    return fields


def apply_fields(text: str, fields: dict[str, str]) -> tuple[str, dict]:
    record = {}
    out = text
    for name, value in fields.items():
        pattern = ALLOWED[name]
        matches = list(pattern.finditer(out))
        if len(matches) != 1:
            die(f"{name} must occur exactly once in the package (found {len(matches)})")
        old = matches[0].group(2)
        record[name] = {"from": old, "to": value}
        out = pattern.sub(rf"\g<1>{value}\g<3>", out, count=1)
        if out == text and old != value:
            die(f"failed to rewrite {name}")
    return out, record


def derive_flist(stock: str, overlay_pkg: Path, target: str) -> str:
    needle = f"${{CVA6_REPO_DIR}}/core/include/${{TARGET_CFG}}_config_pkg.sv"
    alt = f"${{CVA6_REPO_DIR}}/core/include/{target}_config_pkg.sv"
    path = overlay_pkg.resolve().as_posix()
    if needle in stock:
        return stock.replace(needle, path, 1)
    if alt in stock:
        return stock.replace(alt, path, 1)
    die("stock flist does not contain the expected config-package path")


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--root", type=Path, default=Path.cwd())
    p.add_argument("--target", required=True)
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--field", action="append", default=[], help="NAME=VALUE (repeatable)")
    p.add_argument("--check-only", action="store_true")
    args = p.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_]+", args.target):
        die("illegal target")
    fields = parse_fields(args.field)
    root = args.root.resolve()
    pkg = root / "core" / "include" / f"{args.target}_config_pkg.sv"
    flist = root / "core" / "Flist.cva6"
    if not pkg.is_file() or not flist.is_file():
        die(f"missing {pkg} or {flist}")
    text = pkg.read_text(encoding="utf-8")
    rewritten, record = apply_fields(text, fields)
    digest = hashlib.sha256(rewritten.encode()).hexdigest()[:12]
    if args.check_only:
        print(json.dumps({"ok": True, "fields": record, "digest": digest}, indent=2))
        return 0
    out = args.out.resolve()
    if out.exists() and not (out / "overlay.json").is_file() and any(out.iterdir()):
        die(f"refusing to reuse non-overlay directory {out}")
    pkg_dir = out / "core" / "include"
    pkg_dir.mkdir(parents=True, exist_ok=True)
    overlay_pkg = pkg_dir / pkg.name
    overlay_pkg.write_text(rewritten, encoding="utf-8")
    derived = out / "Flist.cva6.overlay"
    derived.write_text(derive_flist(flist.read_text(encoding="utf-8"), overlay_pkg, args.target), encoding="utf-8")
    meta = {
        "isolated": True,
        "experimental": True,
        "notALinuxSku": True,
        "target": args.target,
        "basePackage": str(pkg.relative_to(root).as_posix()),
        "overlayPackage": str(overlay_pkg),
        "derivedFlist": str(derived),
        "fields": record,
        "overlaySha25612": digest,
    }
    (out / "overlay.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
    print(f"[isolated-overlay] wrote {out} fields={record}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
