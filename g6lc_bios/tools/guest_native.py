#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
TARGET = "riscv64imac-unknown-none-elf"
MAX_IMAGE_BYTES = 16 * 1024 * 1024
PAGE = 4096
SYMBOL = re.compile(r"(?:native_entry|_ZN9g6b_guest12native_entry17h[0-9a-f]{16}E)\Z")
ROLE = "native-service-callee-not-bootable-firmware"


def extent(data: bytes, offset: int, length: int) -> bytes:
    if offset < 0 or length < 0 or offset + length > len(data):
        raise ValueError("truncated ELF/archive extent")
    return data[offset:offset + length]


def elf_header(data: bytes, kind: int) -> tuple:
    if len(data) < 64 or data[:7] != b"\x7fELF\x02\x01\x01":
        raise ValueError("expected ELF64 little-endian version 1")
    if any(data[7:16]):
        raise ValueError("unsupported ELF OS ABI or reserved identification bytes")
    fields = struct.unpack_from("<HHIQQQIHHHHHH", data, 16)
    if fields[0:3] != (kind, 243, 1) or fields[7] != 64:
        raise ValueError("unexpected ELF type/machine/header")
    if fields[6] & ~1:
        raise ValueError("native image requires the RV64 integer calling convention")
    return fields


def entry_symbols(data: bytes) -> list[str]:
    fields = elf_header(data, 1)
    section_offset, section_size, section_count = fields[5], fields[10], fields[11]
    if section_size != 64 or not 0 < section_count <= 4096:
        raise ValueError("invalid ELF section table")
    table = extent(data, section_offset, section_size * section_count)
    sections = [struct.unpack_from("<IIQQQQIIQQ", table, i * 64) for i in range(section_count)]
    found = []
    for section in sections:
        if section[1] != 2:
            continue
        if section[9] != 24 or section[5] % 24 or section[6] >= len(sections):
            raise ValueError("invalid symbol table")
        strings = sections[section[6]]
        if strings[1] != 3:
            raise ValueError("symbol names do not reference a string table")
        names = extent(data, strings[4], strings[5])
        symbols = extent(data, section[4], section[5])
        for at in range(0, len(symbols), 24):
            name, info, _other, index, _value, _size = struct.unpack_from("<IBBHQQ", symbols, at)
            if name >= len(names):
                raise ValueError("symbol name outside string table")
            end = names.find(b"\0", name)
            if end < 0:
                raise ValueError("unterminated symbol name")
            text = names[name:end].decode("ascii", "strict")
            if SYMBOL.fullmatch(text) and info & 15 == 2 and info >> 4 in (0, 1, 2) and 0 < index < section_count:
                found.append(text)
    return found


def archive_entry(data: bytes) -> str:
    if not data.startswith(b"!<arch>\n") or len(data) > 128 * 1024 * 1024:
        raise ValueError("expected bounded regular static archive")
    found = []
    at = 8
    while at < len(data):
        header = extent(data, at, 60)
        if header[58:60] != b"`\n":
            raise ValueError("invalid archive header")
        length = int(header[48:58].decode("ascii").strip())
        member = extent(data, at + 60, length)
        if header[:3] == b"#1/":
            name_length = int(header[3:16].decode("ascii").strip())
            member = extent(member, name_length, length - name_length)
        if member.startswith(b"\x7fELF"):
            found.extend(entry_symbols(member))
        at += 60 + length
        if at & 1:
            if extent(data, at, 1) != b"\n":
                raise ValueError("invalid archive padding")
            at += 1
    if len(found) != 1:
        raise ValueError(f"expected exactly one native_entry definition, found {len(found)}")
    return found[0]


def validate_image(data: bytes, base: int) -> dict:
    fields = elf_header(data, 2)
    entry, offset, size, count = fields[3], fields[4], fields[8], fields[9]
    if not 0 < base < (1 << 64) - MAX_IMAGE_BYTES or base % PAGE:
        raise ValueError("load address must be nonzero, page-aligned and bounded")
    if len(data) > MAX_IMAGE_BYTES or size != 56 or not 0 < count <= 16:
        raise ValueError("invalid native program-header extent")
    table = extent(data, offset, size * count)
    segments = []
    for i in range(count):
        kind, flags, file_offset, address, physical, file_size, mem_size, alignment = struct.unpack_from(
            "<IIQQQQQQ", table, i * size
        )
        if kind in (2, 3, 7, 0x6474E552):
            raise ValueError("dynamic/interpreted native images are refused")
        if kind in (0, 4, 6, 0x6474E551, 0x70000003) or kind != 1 or mem_size == 0:
            continue
        # Same contract as g6b-elf::native::Image::parse: RX or R, file-backed,
        # no BSS, no W, no WX. The BIOS payload remains a separate RWX PT_LOAD.
        if (
            flags not in (4, 5)
            or physical != address
            or file_size != mem_size
            or file_size > MAX_IMAGE_BYTES
            or address < base
            or address + mem_size > base + MAX_IMAGE_BYTES
            or alignment != PAGE
            or address % PAGE
            or file_offset % PAGE
        ):
            raise ValueError("invalid, unbounded or writable-executable native segment")
        extent(data, file_offset, file_size)
        segments.append(
            {
                "address": address,
                "offset": file_offset,
                "file_bytes": file_size,
                "memory_bytes": mem_size,
                "flags": flags,
            }
        )
    segments.sort(key=lambda segment: segment["address"])
    if not segments or segments[0]["address"] != base:
        raise ValueError("native image does not start at its requested load address")
    for a, b in zip(segments, segments[1:]):
        if a["address"] + a["memory_bytes"] > b["address"]:
            raise ValueError("overlapping native segments")
    if entry % (2 if fields[6] & 1 else 4) or not any(
        segment["flags"] & 1
        and segment["address"] <= entry < segment["address"] + segment["file_bytes"]
        for segment in segments
    ):
        raise ValueError("entry is not backed by executable file bytes")
    return {
        "target": TARGET,
        "abi_version": 1,
        "frame_bytes": 256,
        "calling_convention": "C: a0 points to one exclusively owned initialized 256-byte frame; a0 returns status",
        "load_address": base,
        "entry": entry,
        "segments": segments,
        "role": ROLE,
        "sha256": hashlib.sha256(data).hexdigest(),
    }


def command(args: list[str], env: dict) -> str:
    print("[guest-native] + " + " ".join(args), flush=True)
    result = subprocess.run(args, cwd=ROOT, env=env, text=True, encoding="utf-8", capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result.stdout


def pinned_env() -> tuple[dict, str]:
    env = os.environ.copy()
    pin = re.search(r'^rust\s*=\s*"([^"]+)"', (ROOT / "pins.toml").read_text(encoding="utf-8"), re.M)
    if not pin:
        raise RuntimeError("pins.toml is missing the rust toolchain pin")
    env["RUSTUP_TOOLCHAIN"] = pin[1]
    env["CARGO_PROFILE_RELEASE_LTO"] = "false"
    env["CARGO_PROFILE_RELEASE_PANIC"] = "abort"
    env["CARGO_TARGET_DIR"] = str(ROOT / "target" / "native-services")
    env["RUSTFLAGS"] = "-C relocation-model=static -C code-model=medium"
    version = command(["rustc", "--version", "--verbose"], env)
    if f"release: {pin[1]}\n" not in version:
        raise RuntimeError("native build requires the repository's pinned Rust version")
    return env, version


def build(output: Path, base: int) -> Path:
    if not 0 < base < (1 << 64) - MAX_IMAGE_BYTES or base % PAGE:
        raise ValueError("load address must be nonzero, page-aligned and bounded")
    env, version = pinned_env()
    host = re.search(r"^host: (.+)$", version, re.M)[1]
    sysroot = Path(command(["rustc", "--print", "sysroot"], env).strip())
    linker = sysroot / "lib" / "rustlib" / host / "bin" / ("rust-lld.exe" if os.name == "nt" else "rust-lld")
    if not linker.is_file():
        raise RuntimeError(f"pinned rust-lld missing: {linker}")
    messages = command(
        [
            "cargo",
            "build",
            "--locked",
            "--release",
            "--target",
            TARGET,
            "-p",
            "g6b-runtime-abi",
            "--message-format=json",
        ],
        env,
    )
    libraries = []
    for line in messages.splitlines():
        item = json.loads(line)
        if item.get("reason") == "compiler-artifact" and item.get("target", {}).get("name") == "g6b_runtime_abi":
            libraries.extend(Path(path) for path in item["filenames"] if path.endswith(".rlib"))
    if len(libraries) != 1:
        raise RuntimeError("ABI build did not report exactly one rlib")
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="native-build-", dir=output) as temporary:
        directory = Path(temporary)
        archive = directory / "libg6b_guest.a"
        command(
            [
                "rustc",
                "--crate-name",
                "g6b_guest",
                "--edition=2021",
                "--crate-type=staticlib",
                "--target",
                TARGET,
                "--cfg",
                'feature="native"',
                "-C",
                "panic=abort",
                "-C",
                "opt-level=s",
                "-C",
                "relocation-model=static",
                "-C",
                "code-model=medium",
                "--extern",
                f"g6b_runtime_abi={libraries[0]}",
                "-L",
                f"dependency={libraries[0].parent}",
                str(ROOT / "crates/g6b-guest/src/lib.rs"),
                "-o",
                str(archive),
            ],
            env,
        )
        symbol = archive_entry(archive.read_bytes())
        script = directory / "native.ld"
        script.write_text(
            f"""ENTRY(__g6b_native_entry)
PHDRS {{ text PT_LOAD FLAGS(5); rodata PT_LOAD FLAGS(4); }}
SECTIONS {{
  . = 0x{base:x};
  .native_entry : {{
    __g6b_native_entry = .;
    KEEP(*(.text.{symbol}))
  }} :text
  ASSERT(SIZEOF(.native_entry) > 0, "native entry section missing")
  .text : {{ *(.text .text.*) }} :text
  . = ALIGN({PAGE});
  .rodata : {{ *(.rodata .rodata.* .srodata .srodata.*) }} :rodata
  /DISCARD/ : {{
    *(.eh_frame .eh_frame.* .comment .got .got.*
      .data .data.* .sdata .sdata.* .bss .bss.* .sbss .sbss.* COMMON)
  }}
}}
""",
            encoding="utf-8",
        )
        image = directory / "g6b-native.elf"
        command(
            [
                str(linker),
                "-flavor",
                "gnu",
                "-m",
                "elf64lriscv",
                "--no-relax",
                "--gc-sections",
                "-z",
                "max-page-size=4096",
                "-T",
                str(script),
                "-o",
                str(image),
                "--whole-archive",
                str(archive),
                "--no-whole-archive",
            ],
            env,
        )
        data = image.read_bytes()
        report = validate_image(data, base)
        report.update(
            {
                "rust_version": version.strip(),
                "entry_symbol": symbol,
                "sources": {
                    name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
                    for name in (
                        "crates/g6b-guest/src/lib.rs",
                        "crates/g6b-guest/src/service.rs",
                        "crates/g6b-guest/Cargo.toml",
                        "crates/g6b-runtime-abi/src/lib.rs",
                        "Cargo.lock",
                        "pins.toml",
                        "tools/guest_native.py",
                    )
                },
            }
        )
        destination = output / f"g6b-native-{report['sha256']}.elf"
        destination.write_bytes(data)
        report["image"] = destination.name
        report_path = output / "native-manifest.json"
        pending = directory / "native-manifest.json"
        pending.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        pending.replace(report_path)
        return report_path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Build a validated native BIOS service callee, not a bootable BIOS"
    )
    parser.add_argument("--load-address", required=True, type=lambda value: int(value, 0))
    parser.add_argument("--out", type=Path, default=ROOT / "out" / "native")
    args = parser.parse_args(argv)
    try:
        manifest = build(args.out.resolve(), args.load_address)
    except (OSError, ValueError, RuntimeError) as error:
        print(f"[guest-native] FAIL: {error}")
        return 1
    print(f"[guest-native] wrote {manifest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
