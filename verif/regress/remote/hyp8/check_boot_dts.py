#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Compile and inspect the actual DTBs used by the experimental hyp8 boots.

Validate the compiled tree, including /include/ expansion. The existing DTS
source-text counter cannot count CPU0 supplied by a .dtsi include.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess


ISA = "rv64imafdc_zba_zbb_zbs_zicboz_zicsr_zifencei"
EXTENSIONS = {"i", "m", "a", "f", "d", "c", "zba", "zbb", "zbs",
              "zicboz", "zicsr", "zifencei"}
PROFILES = (
    ("g6lc-hyp8", 1, False),
    ("g6lc-hyp8-smt2", 2, False),
    ("g6lc-hyp8-linux", 1, True),
    ("g6lc-hyp8-smt2-linux", 2, True),
)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require_equal(actual, expected, label):
    if actual != expected:
        raise ValueError(f"{label}: expected {expected!r}, observed {actual!r}")


def main():
    data = Path(os.environ["TH_DATA_DIR"])
    out = Path(os.environ["TH_OUT_DIR"])
    source = out / "source"
    source.mkdir(exist_ok=True)
    names = [p[0] + ".dts" for p in PROFILES] + ["g6lc-hyp8-platform.dtsi"]
    inputs = {}
    for name in names:
        matches = [p for p in data.rglob(name) if p.is_file()]
        require_equal(len(matches), 1, f"unique uploaded source {name}")
        shutil.copy2(matches[0], source / name)
        inputs[name] = sha(source / name)
    dtc = shutil.which("dtc")
    fdtget = shutil.which("fdtget")
    if not dtc or not fdtget:
        raise RuntimeError("dtc and fdtget are required; no unchecked fallback")
    report = {
        "schema": "hyp8-compiled-dtb-contract.v1",
        "inputs": inputs,
        "dtcSha256": sha(Path(dtc)),
        "fdtgetSha256": sha(Path(fdtget)),
        "runnerSha256": sha(Path(__file__)),
        "profiles": {},
    }
    failed = False
    for name, hart_count, linux in PROFILES:
        dtb = out / f"{name}.dtb"
        record = {"expectedHarts": hart_count, "linux": linux}
        report["profiles"][name] = record
        command = [dtc, "-i", str(source), "-I", "dts", "-O", "dtb",
                   "-o", str(dtb), str(source / f"{name}.dts")]
        record["command"] = command
        compiled = subprocess.run(command, capture_output=True, text=True,
                                  timeout=30)
        (out / f"{name}.dtc.log").write_text(compiled.stdout + compiled.stderr)
        record["compileRc"] = compiled.returncode
        try:
            require_equal(compiled.returncode, 0, f"{name} dtc exit")
            record["dtbSha256"] = sha(dtb)

            def query(node, prop=None, mode="x"):
                args = [fdtget, "-l", str(dtb), node] if prop is None else [
                    fdtget, "-t", mode, str(dtb), node, prop]
                response = subprocess.run(args, capture_output=True, text=True,
                                          timeout=10, check=True)
                return response.stdout.strip()

            def cells(node, prop):
                return [int(value, 16) for value in query(node, prop).split()]

            cpus = sorted(node for node in query("/cpus").split()
                          if node.startswith("cpu@"))
            require_equal(cpus, [f"cpu@{h:x}" for h in range(hart_count)],
                          "enabled CPU node set")
            clint_interrupts = []
            plic_interrupts = []
            cpu_records = []
            for hart in range(hart_count):
                node = f"/cpus/cpu@{hart:x}"
                require_equal(cells(node, "reg"), [hart], node + " hart ID")
                require_equal(query(node, "status", "s"), "okay", node + " status")
                isa = query(node, "riscv,isa", "s")
                require_equal(isa, ISA, node + " ISA")
                require_equal(set(query(node, "riscv,isa-extensions", "s").split()),
                              EXTENSIONS, node + " ISA extensions")
                require_equal(query(node, "mmu-type", "s"), "riscv,sv39", node + " MMU")
                for prop, value in (
                        ("riscv,cboz-block-size", 64),
                        ("i-cache-block-size", 16), ("i-cache-size", 16384),
                        ("d-cache-block-size", 16), ("d-cache-size", 32768)):
                    require_equal(cells(node, prop), [value], node + " " + prop)
                intc = cells(node + "/interrupt-controller", "phandle")[0]
                require_equal(cells(node + "/interrupt-controller", "#interrupt-cells"),
                              [1], node + " interrupt cell count")
                cpu_handle = cells(node, "phandle")[0]
                require_equal(cells(f"/cpus/cpu-map/cluster0/core0/thread{hart}", "cpu"),
                              [cpu_handle], node + " core/thread topology")
                clint_interrupts.extend((intc, 3, intc, 7))
                plic_interrupts.extend((intc, 11, intc, 9))
                cpu_records.append({"hart": hart, "isa": isa, "interruptPhandle": intc})
            require_equal(cells("/soc/clint@2000000", "interrupts-extended"),
                          clint_interrupts, "CLINT context order")
            require_equal(cells("/soc/interrupt-controller@c000000", "interrupts-extended"),
                          plic_interrupts, "PLIC context order")
            require_equal(cells("/memory@80000000", "reg"),
                          [0, 0x80000000, 0, 0x10000000], "memory map")
            require_equal(cells("/cpus", "timebase-frequency"), [12500000], "RTC")
            require_equal(cells("/soc/uart@10000000", "reg-shift"), [2], "UART shift")
            require_equal(cells("/soc/uart@10000000", "reg-io-width"), [4], "UART width")
            if linux:
                require_equal(cells("/chosen", "linux,initrd-start"),
                              [0, 0x84000000], "initrd start")
                require_equal(cells("/chosen", "linux,initrd-end"),
                              [0, 0x840E3800], "initrd end")
                bootargs = query("/chosen", "bootargs", "s").split()
                require_equal([arg for arg in bootargs if arg.startswith("maxcpus=")],
                              [f"maxcpus={hart_count}"], "Linux CPU bound")
            record.update(passed=True, cpus=cpu_records,
                          clintContexts=len(clint_interrupts) // 2,
                          plicContexts=len(plic_interrupts) // 2)
        except (ValueError, subprocess.CalledProcessError, IndexError) as error:
            failed = True
            record.update(passed=False, error=str(error))
    report["passed"] = not failed
    (out / "dtb-contract.json").write_text(json.dumps(report, indent=2) + "\n")
    print("HYP8_DTB_PASS" if not failed else "HYP8_DTB_FAIL")
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())
