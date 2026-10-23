#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Build configuration-matched hyp8 firmware from pinned reference inputs.

The OpenSBI archive and the existing platform/toolchain recipes are frozen.
Only the DTB/profile changes; the strict supervisor payload and Linux payload
bytes are reused unchanged. This builds inputs; it never executes a CPU model.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile


COMMIT = "455de672dd7c2aa1992df54dfb08dc11abbc1b1a"
ARCHIVE = "e81df11f64e47a8caf61c48f0ca61971ff61a04a85f00b69465f88be56a5c1a6"
PROTECTED = {
    "firmware/fw_base.S": "8cbdd52a8c5444cea34bafcfaa27ca3b69a678ed2b7d393f405a0f58bda1490d",
    "lib/sbi/sbi_init.c": "f8650ee7d2585a8c34b7c6693777538a74dc8a0e16ef769a7155f1c5a29a3d02",
    "lib/sbi/sbi_hsm.c": "23629418e90abc0a5871bf0d6121a59cde6e1d43bf962cad3edca7141f2506de",
    "platform/generic/platform.c": "bbaf1b5a6fe1117e59449e0017603ec5a898a188e1d133c4ec87b1dce4986e7c",
    "lib/utils/libfdt/fdt_ro.c": "164aa62cae3abacb8469c1859dc1985118b38a79ddc5e64afcbb40d3342da3ea",
}
PATCHES = {
    "patch_opensbi_nopie.py": "2aff89857e14be25e396e1b377a88223c104877641e16aa258383996635f8dae",
    "wrap_pie_flags.py": "6725aa5371021a9d0eb285d76532fbd0fd103a5fd743ebb407ad641b9d4202ce",
    "patch_opensbi_g6lc_clint.py": "911838df48f730b9f00ed9606460b7452059f755bbb61c905eec6855d41c960f",
}
DTBS = {
    "g6lc-hyp8-smt2.dtb": "42d27db8642c8731864b96772aa368dd05643a1b76bb48d69fd0d249a01a8a48",
    "g6lc-hyp8-linux.dtb": "f64c1f6fca7ce9be95c9f5f80f78b2eaacff4f4730ca8cde691ad6762a4ebdb7",
    "g6lc-hyp8-smt2-linux.dtb": "fc0fd28f4a95ca5989279a53df0a390ffaecc29696365cc6fc2daa5279e7f39d",
}
STRICT_ELF = "7e4142ac43378329957c1a7f270a1c426d85f08caa32adcc3ea7a9fa62647b78"
STRICT_BINARY = "2b7cdc0495bd00e5a814d5316ae4708229967065131d3e4f3fdffdde95584016"
LINUX_SOURCE = Path("/opt/testharness/runs/linux-payload-l1s2/payload.bin")
LINUX_BINARY = "da38306f4cff20c50ea61c7bf29f0657c0fc3d981b655847f129acff9570d481"
CROSS = "/opt/testharness/toolchains/xpack-riscv-none-elf-gcc-14.2.0-3/bin/riscv-none-elf-"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require_hash(path, expected):
    actual = sha(path)
    if actual != expected:
        raise ValueError(f"input identity changed: {path}: {actual} != {expected}")


def main():
    data = Path(os.environ["TH_DATA_DIR"])
    out = Path(os.environ["TH_OUT_DIR"])
    source = out / "opensbi"
    inputs = out / "inputs"
    inputs.mkdir(exist_ok=True)
    report = {
        "schema": "hyp8-firmware-build.v1",
        "upstreamCommit": COMMIT,
        "archiveSha256": ARCHIVE,
        "protectedSources": PROTECTED,
        "recipeHashes": PATCHES,
        "runnerSha256": sha(Path(__file__)),
        "compilerSha256": sha(Path(CROSS + "gcc")),
        "profiles": {},
        "execution": "not run",
    }

    def pick(name):
        found = [p for p in data.rglob(name) if p.is_file()]
        if len(found) != 1:
            raise ValueError(f"expected one {name}, found {len(found)}")
        return found[0]

    def command(argv, log, timeout=900):
        with (out / log).open("w") as stream:
            completed = subprocess.run(argv, stdout=stream,
                                       stderr=subprocess.STDOUT,
                                       timeout=timeout)
        if completed.returncode:
            raise RuntimeError(f"command failed rc={completed.returncode}: {log}")

    archive = pick("hyp8-opensbi-455de672.tar")
    require_hash(archive, ARCHIVE)
    if source.exists():
        raise RuntimeError("source directory already exists; use a fresh run tag")
    source.mkdir()
    with tarfile.open(archive) as packed:
        packed.extractall(source, filter="data")
    for name, expected in PROTECTED.items():
        require_hash(source / name, expected)
    before = {str(p.relative_to(source)): sha(p)
              for p in source.rglob("*") if p.is_file()}
    for name, expected in PATCHES.items():
        recipe = pick(name)
        require_hash(recipe, expected)
        target = source if name == "patch_opensbi_g6lc_clint.py" else source / "Makefile"
        command([sys.executable, str(recipe), str(target)], name + ".log", 60)
    for name, expected in PROTECTED.items():
        require_hash(source / name, expected)
    after = {str(p.relative_to(source)): sha(p)
             for p in source.rglob("*") if p.is_file()}
    report["platformSourceDelta"] = {
        name: {"before": before.get(name), "after": value}
        for name, value in after.items() if before.get(name) != value}
    report["patchedSourceHashes"] = after

    strict_elf = pick("payload.elf")
    require_hash(strict_elf, STRICT_ELF)
    shutil.copy2(strict_elf, inputs / "strict-payload.elf")
    command([CROSS + "objcopy", "-O", "binary", str(inputs / "strict-payload.elf"),
             str(inputs / "strict-payload.bin")], "strict-objcopy.log", 60)
    require_hash(inputs / "strict-payload.bin", STRICT_BINARY)
    require_hash(LINUX_SOURCE, LINUX_BINARY)
    shutil.copy2(LINUX_SOURCE, inputs / "linux-payload.bin")
    require_hash(inputs / "linux-payload.bin", LINUX_BINARY)
    for name, expected in DTBS.items():
        dtb = pick(name)
        require_hash(dtb, expected)
        shutil.copy2(dtb, inputs / name)

    profiles = (
        ("strict-smt2", 2, "g6lc-hyp8-smt2.dtb", "strict-payload.bin"),
        ("linux-scalar", 1, "g6lc-hyp8-linux.dtb", "linux-payload.bin"),
        ("linux-smt2", 2, "g6lc-hyp8-smt2-linux.dtb", "linux-payload.bin"),
    )
    for name, harts, dtb, payload in profiles:
        build = out / f"build-{name}"
        argv = [
            "make", "-C", str(source), f"O={build}", "PLATFORM=generic",
            "FW_TEXT_START=0x80000000", "FW_PAYLOAD_OFFSET=0x200000",
            f"FW_PAYLOAD_PATH={inputs / payload}", f"FW_FDT_PATH={inputs / dtb}",
            f"CROSS_COMPILE={CROSS}", "OPENSBI_ALLOW_NO_PIE=y",
            "PLATFORM_RISCV_ISA=rv64imafdc_zicsr_zifencei", "-j2",
        ]
        record = {
            "harts": harts, "cores": 1, "dtbSha256": DTBS[dtb],
            "payloadSha256": sha(inputs / payload), "command": argv,
            "status": "building",
        }
        report["profiles"][name] = record
        (out / "firmware-build.json").write_text(json.dumps(report, indent=2) + "\n")
        command(argv, f"build-{name}.log")
        elf = build / "platform/generic/firmware/fw_payload.elf"
        require_hash(inputs / dtb, DTBS[dtb])
        for protected, expected in PROTECTED.items():
            require_hash(source / protected, expected)
        record.update(status="built", firmware=str(elf), firmwareSha256=sha(elf))
    report["status"] = "built-not-executed"
    (out / "firmware-build.json").write_text(json.dumps(report, indent=2) + "\n")
    print("HYP8_FIRMWARE_BUILT_NOT_EXECUTED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
