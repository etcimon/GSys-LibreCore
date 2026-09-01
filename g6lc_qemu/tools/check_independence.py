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
#   python tools/check_independence.py --selftest

from __future__ import annotations

import argparse
import re
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from env_common import package_root  # noqa: E402

# --- KD0 ---------------------------------------------------------------------
# A dependency line is acceptable only if it is a path dependency that stays
# inside the package.
_DEP_SECTION = re.compile(r"^\s*\[.*dependencies\]\s*$")
_ANY_SECTION = re.compile(r"^\s*\[")
_PATH_DEP = re.compile(r'path\s*=\s*"([^"]+)"')
# A member crate may inherit a dependency the workspace declared, but only if the
# workspace declared it as an in-package path dependency; see _workspace_path_deps.
_WORKSPACE_DEP = re.compile(r"workspace\s*=\s*true")

# Native library linkage inside a package manifest.
_PACKAGE_LINK = re.compile(r"^\s*links\s*=\s*")
_PACKAGE_BUILD = re.compile(r"^\s*build\s*=\s*")
_PACKAGE_LINKS_VALUE = re.compile(r'^\s*links\s*=\s*"([^"]+)"')
_PACKAGE_BUILD_VALUE = re.compile(r"^\s*build\s*=\s*(.+)")

# Crate types that would produce a native object QEMU could load.
_FORBIDDEN_CRATE_TYPE = re.compile(
    r'crate-type\s*=\s*\[[^\]]*(?:cdylib|dylib|staticlib)(?:[^\]]*\])?'
)

# --- E-GPLLINK ---------------------------------------------------------------
# Tokens that would indicate a native link surface inside crates/**.
_FORBIDDEN_RS = [
    (re.compile(r"\bbindgen\b"), "bindgen (native binding generation)"),
    (re.compile(r'#\s*\[\s*link\s*[\(\]]'), "#[link] attribute"),
    (re.compile(r'#\s*\[\s*link_name'), "#[link_name] attribute"),
    (re.compile(r'extern\s+"C"\s*\{'), 'extern "C" block (foreign linkage)'),
    (re.compile(r'include!\s*\('), "include! of generated bindings"),
    (re.compile(r'global_asm!\s*\('), "global_asm! (native code injection)"),
]
# cfg_attr(...) that forwards to a link attribute.
_CFG_ATTR_LINK = re.compile(
    r'#\s*\[\s*cfg_attr\s*\([^)]*\b(?:link|link_name)\b',
    re.IGNORECASE,
)
# include_str!/include_bytes! with a string-literal path.
_INCLUDE_STR_BYTES = re.compile(
    r'(?:include_str|include_bytes)!\s*\(\s*"([^"]+)"\s*\)'
)
# QEMU specifically, anywhere in the crates tree, in any file type.
_QEMU_TOKENS = [
    re.compile(r"qemu[/\\][a-z0-9_./\\-]*\.h", re.IGNORECASE),
    re.compile(r'#\s*include\s*[<"][^">]*qemu', re.IGNORECASE),
    re.compile(r"\blibqemu\b", re.IGNORECASE),
    re.compile(r"qemu-plugin\.h", re.IGNORECASE),
]
# Emitters legitimately contain the *string* "qemu" (file names, banners). Only
# the patterns above — which imply consuming QEMU's own headers — are forbidden.

_SKIP_DIRS = {".git", "target", ".tools", "out", "qemu", "linux-dist", "__pycache__", ".venv"}


def _is_inside(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


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
        if not _is_inside(dep, root):
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

        in_package = False
        for lineno, raw in enumerate(man.read_text(encoding="utf-8").splitlines(), 1):
            line = raw.split("#", 1)[0]
            if _ANY_SECTION.match(line):
                in_package = line.strip().startswith("[package]")
            if not in_package:
                # crate-type can appear in [[bin]] / [lib] / [example] sections, not just [package].
                if _FORBIDDEN_CRATE_TYPE.search(line):
                    f.err(man, f"line {lineno}: forbidden crate type `cdylib`, `dylib` or "
                               f"`staticlib` (E-GPLLINK: no native object output).")
                continue
            if _PACKAGE_LINK.match(line):
                m = _PACKAGE_LINKS_VALUE.search(line)
                if m:
                    f.err(man, f"line {lineno}: package links against native library "
                               f"`{m.group(1)}` (E-GPLLINK).")
            if _PACKAGE_BUILD.match(line):
                m = _PACKAGE_BUILD_VALUE.search(line)
                if m:
                    val = m.group(1).strip()
                    if val != "false":
                        f.err(man, f"line {lineno}: package has a build script `{val}` "
                                   f"(E-GPLLINK: no native build surface).")
            if _FORBIDDEN_CRATE_TYPE.search(line):
                f.err(man, f"line {lineno}: forbidden crate type `cdylib`, `dylib` or "
                           f"`staticlib` (E-GPLLINK: no native object output).")

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
            if not _is_inside(dep, root):
                f.err(man, f"line {lineno}: path dependency escapes the package: {m.group(1)}")

    # A build script is the usual way a native library sneaks in.
    # Only the default Cargo build-script location is forbidden here; any explicit
    # `build = "..."` path is caught by the manifest check above.
    for bs in root.glob("crates/*/build.rs"):
        f.err(bs, "build.rs is not permitted at the crate root (E-GPLLINK: no native build surface)")


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
            if _CFG_ATTR_LINK.search(text):
                f.err(path, "E-GPLLINK: #[cfg_attr(..., link/)] forwards a native link "
                            "attribute.")
            for m in _INCLUDE_STR_BYTES.finditer(text):
                inc_path = m.group(1)
                resolved = (path.parent / inc_path).resolve()
                if not _is_inside(resolved, root):
                    f.err(path, f"E-GPLLINK: include_str!/include_bytes! loads a file outside "
                                f"the package: `{inc_path}` -> `{resolved}`")
                elif any(part.lower() == "qemu" for part in resolved.parts):
                    f.err(path, f"E-GPLLINK: include_str!/include_bytes! loads a file under "
                                f"a `qemu/` path: `{inc_path}` -> `{resolved}`")
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
    ap.add_argument("--selftest", action="store_true",
                    help="run a synthetic package through the checks")
    args = ap.parse_args(argv)

    if args.selftest:
        return selftest()

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


def selftest() -> int:
    """Create a fake package with known violations and a clean package, and verify
    the checker catches the first and accepts the second.
    """
    root = Path(tempfile.mkdtemp(prefix="g6lc_indep_test_"))
    try:
        # --- bad package ------------------------------------------------------
        bad = root / "bad"
        (bad / "crates" / "bad-crate").mkdir(parents=True)
        (bad / "crates" / "bad-crate" / "src").mkdir(parents=True)
        (bad / "Cargo.toml").write_text(
            '[workspace]\nmembers = ["crates/bad-crate"]\n'
            '[workspace.dependencies]\nfoo = "1.0"\n',
            encoding="utf-8",
        )
        (bad / "crates" / "bad-crate" / "Cargo.toml").write_text(
            '[package]\nname = "bad-crate"\nversion = "0.1.0"\n'
            'links = "qemu"\nbuild = "build.rs"\n'
            '[dependencies]\nfoo = { workspace = true }\n'
            'bar = "2.0"\n'
            '[[bin]]\nname = "plugin"\ncrate-type = ["cdylib"]\n',
            encoding="utf-8",
        )
        (bad / "crates" / "bad-crate" / "src" / "lib.rs").write_text(
            'extern "C" { fn qemu_foo(); }\n'
            '#[link(name = "qemu")]\n'
            '#[cfg_attr(target_os = "linux", link(name = "qemu"))]\n'
            'include!("qemu.h");\n'
            'static X: &[u8] = include_bytes!("../../../../../.other/file.h");\n',
            encoding="utf-8",
        )
        (bad / "crates" / "bad-crate" / "build.rs").write_text(
            "fn main() {}", encoding="utf-8"
        )

        f = Findings()
        check_cargo_manifests(bad, f, False)
        check_gpl_link(bad, f, False)
        check_fixtures_synthetic(bad, f)
        want = [
            "workspace dependency `foo` is not a path dependency",
            "non-path dependency `bar = \"2.0\"`",
            "package links against native library `qemu`",
            "package has a build script",
            "forbidden crate type",
            "build.rs is not permitted",
            'extern "C" block',
            "#[link] attribute",
            "#[cfg_attr(",
            "include!",
            "include_bytes! loads a file outside the package",
        ]
        missing = [msg for msg in want if not any(msg in e for e in f.errors)]
        if missing:
            print(f"[indep] SELFTEST FAILED: expected violations not found: {missing}",
                  file=sys.stderr)
            for e in f.errors:
                print(f"  - {e}", file=sys.stderr)
            return 1

        # --- good package -----------------------------------------------------
        good = root / "good"
        (good / "crates" / "g6q-foo").mkdir(parents=True)
        (good / "crates" / "g6q-foo" / "src").mkdir(parents=True)
        (good / "crates" / "g6q-foo" / "data").mkdir(parents=True)
        (good / "fixtures").mkdir()
        (good / "fixtures" / "README.md").write_text("synthetic", encoding="utf-8")
        (good / "Cargo.toml").write_text(
            '[workspace]\nmembers = ["crates/g6q-foo"]\n'
            '[workspace.dependencies]\ng6q-bar = { path = "crates/g6q-foo" }\n',
            encoding="utf-8",
        )
        (good / "crates" / "g6q-foo" / "Cargo.toml").write_text(
            '[package]\nname = "g6q-foo"\nversion = "0.1.0"\n'
            '[dependencies]\ng6q-bar = { workspace = true }\n',
            encoding="utf-8",
        )
        (good / "crates" / "g6q-foo" / "data" / "table.ini").write_text(
            "[x]\nconfig = X\n", encoding="utf-8"
        )
        (good / "crates" / "g6q-foo" / "src" / "lib.rs").write_text(
            'pub const TABLE: &str = include_str!("../data/table.ini");\n',
            encoding="utf-8",
        )

        f2 = Findings()
        check_cargo_manifests(good, f2, False)
        check_gpl_link(good, f2, False)
        check_fixtures_synthetic(good, f2)
        if f2.errors:
            print("[indep] SELFTEST FAILED: clean package produced errors", file=sys.stderr)
            for e in f2.errors:
                print(f"  - {e}", file=sys.stderr)
            return 1

        print("[indep] SELFTEST OK")
        return 0
    finally:
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
