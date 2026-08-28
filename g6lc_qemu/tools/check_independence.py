#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# check_independence.py — enforce the two structural invariants of this package.
#
#   KD0        the Rust workspace depends on nothing outside g6lc_qemu/
#   E-GPLLINK  no crate links, includes, binds or vendors QEMU
#
# Both are build failures, not review comments (AGENTS-licensing.md section 2.3).
#
#   python tools/check_independence.py [--verbose]

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from env_common import package_root  # noqa: E402

# --- KD0 ---------------------------------------------------------------------
# A dependency line is acceptable only if it is a path dependency that stays
# inside the package.
_DEP_SECTION = re.compile(r"^\s*\[(?:workspace\.)?(?:build-|dev-)?dependencies\]\s*$")
_ANY_SECTION = re.compile(r"^\s*\[")
_PATH_DEP = re.compile(r'path\s*=\s*"([^"]+)"')
# A member crate may inherit a dependency the workspace declared, but only if the
# workspace declared it as an in-package path dependency; see _workspace_path_deps.
_WORKSPACE_DEP = re.compile(r"workspace\s*=\s*true")

# --- E-GPLLINK ---------------------------------------------------------------
# Tokens that would indicate a native link surface inside crates/**.
_FORBIDDEN_RS = [
    (re.compile(r"\bbindgen\b"), "bindgen (native binding generation)"),
    (re.compile(r'#\s*\[\s*link\s*[\(\]]'), "#[link] attribute"),
    (re.compile(r'#\s*\[\s*link_name'), "#[link_name] attribute"),
    (re.compile(r'extern\s+"C"\s*\{'), 'extern "C" block (foreign linkage)'),
    (re.compile(r'include!\s*\('), "include! of generated bindings"),
]
# QEMU specifically, anywhere in the crates tree, in any file type.
_QEMU_TOKENS = [
    re.compile(r"qemu[/\\][a-z0-9_./\\-]*\.h", re.IGNORECASE),
    re.compile(r'#\s*include\s*[<"][^">]*qemu', re.IGNORECASE),
    re.compile(r"\blibqemu\b", re.IGNORECASE),
    re.compile(r"qemu-plugin\.h", re.IGNORECASE),
]
# Emitters legitimately contain the *string* "qemu" (file names, banners). Only
# the patterns above — which imply consuming QEMU's own headers — are forbidden.

_SKIP_DIRS = {".git", "target", ".tools", "out", "qemu", "__pycache__", ".venv"}


class Findings:
    def __init__(self) -> None:
        self.errors: list[str] = []
        self.checked = 0

    def err(self, path: Path, msg: str) -> None:
        self.errors.append(f"{path}: {msg}")


def _walk(root: Path):
    for p in root.rglob("*"):
        if any(part in _SKIP_DIRS for part in p.parts):
            continue
        if p.is_file():
            yield p


def _dependency_lines(manifest: Path):
    """Yield (lineno, name, body) for every entry in a dependency section."""
    in_deps = False
    for lineno, raw in enumerate(manifest.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.split("#", 1)[0]
        if _DEP_SECTION.match(line):
            in_deps = True
            continue
        if _ANY_SECTION.match(line):
            in_deps = False
        if not in_deps:
            continue
        stripped = line.strip()
        if not stripped or "=" not in stripped:
            continue
        name, _, body = stripped.partition("=")
        yield lineno, name.strip(), body.strip()


def _workspace_path_deps(root: Path, f: Findings) -> set[str]:
    """Names declared in the root [workspace.dependencies] as in-package path deps.

    A member crate is allowed to write `dep = { workspace = true }`, but only when the
    inherited entry itself resolves to a path inside this package. Accepting inheritance
    without checking what it inherits would leave the door open that KD0 exists to close.
    """
    names: set[str] = set()
    man = root / "Cargo.toml"
    if not man.is_file():
        return names
    for lineno, name, body in _dependency_lines(man):
        m = _PATH_DEP.search(body)
        if not m:
            f.err(man, f"line {lineno}: workspace dependency `{name}` is not a path "
                       f"dependency. The workspace declares no external crates; "
                       f"see AGENTS-licensing.md section 5.")
            continue
        dep = (root / m.group(1)).resolve()
        try:
            dep.relative_to(root)
        except ValueError:
            f.err(man, f"line {lineno}: path dependency `{name}` escapes the package: "
                       f"{m.group(1)}")
            continue
        names.add(name)
    return names


def check_cargo_manifests(root: Path, f: Findings, verbose: bool) -> None:
    f.checked += 1
    inheritable = _workspace_path_deps(root, f)

    crates = root / "crates"
    members = sorted(crates.glob("*/Cargo.toml")) if crates.is_dir() else []
    if not members:
        f.err(crates, "no crate manifests found under crates/")

    for man in members:
        f.checked += 1
        if verbose:
            print(f"[indep] manifest {man.relative_to(root)}")
        for lineno, name, body in _dependency_lines(man):
            if _WORKSPACE_DEP.search(body):
                if name not in inheritable:
                    f.err(man, f"line {lineno}: `{name}` inherits from the workspace, but "
                               f"the workspace does not declare it as an in-package path "
                               f"dependency.")
                continue
            m = _PATH_DEP.search(body)
            if not m:
                f.err(man, f"line {lineno}: non-path dependency `{name} = {body}`. "
                           f"The workspace declares no external crates; "
                           f"see AGENTS-licensing.md section 5.")
                continue
            dep = (man.parent / m.group(1)).resolve()
            try:
                dep.relative_to(root)
            except ValueError:
                f.err(man, f"line {lineno}: path dependency escapes the package: {m.group(1)}")

    # A build script is the usual way a native library sneaks in.
    for bs in root.glob("crates/*/build.rs"):
        f.err(bs, "build.rs is not permitted in crates/** (E-GPLLINK: no native build surface)")


def check_gpl_link(root: Path, f: Findings, verbose: bool) -> None:
    crates = root / "crates"
    if not crates.is_dir():
        return
    for path in _walk(crates):
        if path.suffix not in (".rs", ".toml"):
            continue
        f.checked += 1
        text = path.read_text(encoding="utf-8", errors="replace")
        # The QEMU-emitter crate is text-out: it legitimately emits QEMU C source,
        # including QEMU header #includes, but it must still not link or bind QEMU.
        is_qemu_emitter = any(part == "g6q-emit-qemu" for part in path.parts)
        if not is_qemu_emitter:
            for pat in _QEMU_TOKENS:
                m = pat.search(text)
                if m:
                    f.err(path, f"E-GPLLINK: reference to QEMU internals ({m.group(0)!r}). "
                                f"Emission is text-out only.")
        if path.suffix == ".rs":
            for pat, what in _FORBIDDEN_RS:
                m = pat.search(text)
                if m:
                    f.err(path, f"E-GPLLINK: {what} found ({m.group(0)!r}). "
                                f"No crate may link a foreign library.")
        if verbose:
            print(f"[indep] scanned {path.relative_to(root)}")


def check_fixtures_synthetic(root: Path, f: Findings) -> None:
    """Fixtures must be authored here, never copied out of a host project."""
    fixtures = root / "fixtures"
    if not fixtures.is_dir():
        return
    marker = fixtures / "README.md"
    if not marker.is_file():
        f.err(fixtures, "fixtures/README.md missing (must assert fixtures are synthetic)")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="KD0 + E-GPLLINK enforcement.")
    ap.add_argument("--verbose", "-v", action="store_true")
    args = ap.parse_args(argv)

    root = package_root()
    f = Findings()
    check_cargo_manifests(root, f, args.verbose)
    check_gpl_link(root, f, args.verbose)
    check_fixtures_synthetic(root, f)

    if f.errors:
        print("[indep] FAILED", file=sys.stderr)
        for e in f.errors:
            print(f"  - {e}", file=sys.stderr)
        return 1
    print(f"[indep] OK ({f.checked} files checked): "
          f"no external dependency, no QEMU link surface")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
