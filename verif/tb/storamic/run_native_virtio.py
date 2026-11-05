# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""ST-037C: build ariane_testharness (Storamic) + the virtio-blk bare-metal
ELF remotely, run positive and negative-oracle ELFs, write native-virtio.json.
Launched via remote-testharness.sh py with the delta tar in data/."""
import hashlib, json, os, re, shlex, shutil, subprocess, sys, tarfile, time
from pathlib import Path

SNAP = Path("/opt/testharness/runs/storamic-aggregate-gate-v3-71b2e9c4/aggregate-source")
# Pinned aggregate tool set (Verilator fork 8c69f297a, manifest-checked below).
TOOLS = Path("/opt/testharness/cache/storamic-aggregate-tools/v3-8c69f297aabc-545f88b2ed3a")
VL = str(TOOLS / "verilator-g6lc/bin/verilator")
RISCV = "/opt/testharness/toolchains/xpack-riscv-none-elf-gcc-14.2.0-3"
SPIKE = "/opt/testharness/toolchains/spike"   # fesvr headers + libs for the DTM
COMMON = "verif/tests/custom/common"
ENVDIR = "verif/tests/custom/env"
SRC = "verif/tests/custom/storamic/storamic_virtio_blk.c"

def sh(argv, cwd, env, log=None, timeout=7200):
    try:
        r = subprocess.run(argv, cwd=cwd, env=env, capture_output=True,
                           text=True, timeout=timeout)
    except subprocess.TimeoutExpired as e:
        def txt(b):
            return b.decode(errors="replace") if isinstance(b, bytes) else (b or "")
        r = subprocess.CompletedProcess(argv, 124, txt(e.stdout),
                                        txt(e.stderr) + f"\nTIMEOUT after {timeout}s\n")
    if log: Path(log).write_text(r.stdout + r.stderr)
    return r

def main():
    out = Path("output").resolve(); out.mkdir(exist_ok=True)
    work = Path("repo").resolve()
    man = json.loads((TOOLS / "manifest.json").read_text())
    if man.get("status") != "complete":
        raise RuntimeError("tool set incomplete")
    for rel, digest in man["binaries"].items():
        if hashlib.sha256((TOOLS / rel).read_bytes()).hexdigest() != digest:
            raise RuntimeError(f"tool drifted: {rel}")
    rep = {"snapshot": str(SNAP), "verilator": VL, "tools_manifest": man,
           "verilator_bin_sha256": hashlib.sha256(
               Path(VL).parent.joinpath("verilator_bin").read_bytes()).hexdigest(),
           "gcc": sh([f"{RISCV}/bin/riscv-none-elf-gcc", "--version"], ".",
                     dict(os.environ)).stdout.splitlines()[0]}
    shutil.copytree(SNAP, work, symlinks=True,
        ignore=lambda d, n: ["workspace"] if d.endswith("build-platform") else [])
    delta = Path("data/storamic-delta.tar").resolve()
    rep["delta_sha256"] = hashlib.sha256(delta.read_bytes()).hexdigest()
    with tarfile.open(delta) as t:
        for m in t.getmembers():
            if m.name.startswith("/") or ".." in Path(m.name).parts:
                raise RuntimeError(f"unsafe delta member {m.name}")
        t.extractall(work)
        rep["delta_files"] = sorted(m.name for m in t.getmembers() if m.isfile())
    # ST-011B: --native-defines overrides the default IO-role selection, e.g.
    # "G6LC_STORAMIC+G6LC_STORAMIC_MODEL" for the primary-memory role backed
    # by the simulation model memory.
    native_defines = "G6LC_STORAMIC_IO"
    # The remote py gateway forwards data files, not script arguments.
    defines_file = Path("data/native-defines.txt")
    if defines_file.exists():
        native_defines = defines_file.read_text().strip()
    for i, a in enumerate(sys.argv):
        if a == "--native-defines" and i + 1 < len(sys.argv):
            native_defines = sys.argv[i + 1]
    # Peripheral role only is the default; the primary-memory role
    # (G6LC_STORAMIC) replaces the simulation DRAM the harness preloads ELFs
    # into — functional only with G6LC_STORAMIC_MODEL (ST-011B).
    env = dict(os.environ, CVA6_REPO_DIR=str(work), RISCV=RISCV,
               HPDCACHE_DIR=str(work / "core/cache_subsystem/hpdcache"),
               TARGET_CFG="cv64a6_imafdc_sv39", SPIKE_INSTALL_DIR=SPIKE,
               LD_LIBRARY_PATH=f"{SPIKE}/lib:" + os.environ.get("LD_LIBRARY_PATH", ""),
               G6LC_STORAMIC_DEFINES=native_defines)
    rep["defines"] = env["G6LC_STORAMIC_DEFINES"]
    rep["native_defines"] = native_defines
    primary = "G6LC_STORAMIC" in native_defines.split("+")
    t0 = time.time()
    b = sh(["make", "verilate", "target=cv64a6_imafdc_sv39",
            f"verilator={VL}"], work, env, out / "build.log", timeout=5400)
    rep["build"] = {"rc": b.returncode, "seconds": round(time.time() - t0, 1),
                    "tail": (b.stdout + b.stderr)[-2000:]}
    elfs = {}
    # The harness invalidates CPU caches for Storamic DMA writes (InvalEn), so
    # the test reads device-written memory with plain loads.
    cflags = ["-DSTORAMIC_COHERENT_DMA"] + (["-DSTORAMIC_PRIMARY"] if primary else [])
    if "G6LC_STORAMIC_FLASH_COMMIT" in native_defines:
        cflags.append("-DSTORAMIC_COMMIT_SLOW")
    rep["test_cflags"] = cflags
    for name, extra in (("pos", []), ("neg", ["-DORACLE_NEGATIVE"])):
        elf = work / f"storamic_virtio_blk_{name}.elf"
        c = sh([f"{RISCV}/bin/riscv-none-elf-gcc", "-static",
                "-mcmodel=medany", "-march=rv64imafdc", "-mabi=lp64d",
                "-fvisibility=hidden", "-nostdlib", "-nostartfiles", "-O2",
                "-T", f"{COMMON}/link_verilator.ld",
                f"{COMMON}/syscalls.c", f"{COMMON}/crt.S", SRC,
                "-lgcc", f"-I{COMMON}", f"-I{ENVDIR}", *cflags, *extra,
                "-o", str(elf)],
               work, env, out / f"gcc-{name}.log")
        runs = rep.setdefault("runs", {})
        if c.returncode:
            runs[name] = {"gcc_rc": c.returncode,
                          "gcc_tail": (c.stdout + c.stderr)[-1500:]}
            continue
        if b.returncode:
            runs[name] = {"skipped": "harness build failed"}
            continue
        th = sh([f"{RISCV}/bin/riscv-none-elf-nm", str(elf)], work, env).stdout
        m = re.search(r"([0-9a-f]+) [dDbB] tohost", th)
        tohost = int(m.group(1), 16) if m else 0
        sim = work / "work-ver/Variane_testharness"
        r = sh([str(sim), "+time_out=20000000", "+debug_disable",
                "+g6lc_virtio_mmio_trace", "+g6lc_storamic_mem_trace",
                # Optional extra plusargs, one per line, from data/sim-plusargs.txt.
                *(Path("data/sim-plusargs.txt").read_text().split()
                  if Path("data/sim-plusargs.txt").exists() else []),
                f"+tohost_addr=0x{tohost:x}", str(elf)],
               work, env, out / f"sim-{name}.log", timeout=3600)
        log = (out / f"sim-{name}.log").read_text()
        # A SUCCESS banner that only means the cycle budget ran out is not a pass.
        ok = "*** SUCCESS ***" in log and "cycle budget reached" not in log
        failed = re.findall(r"\*\*\* FAILED \*\*\* \(tohost = (\d+)", log)
        runs[name] = {"elf": elf.name, "tohost": hex(tohost),
            "rc": r.returncode, "success": ok,
            "fail_code": failed[0] if failed else None,
            "cycles": (re.findall(r"after (\d+) cycles", log) or [None])[0],
            "tail": log[-1500:]}
    # ST-011B: in the primary-memory build hello_world proves programs run
    # from the sim model memory (preload lands in g6lc_storamic_sim_mem).
    if primary:
        helloc = "verif/tests/custom/hello_world/hello_world.c"
        elf = work / "hello_world_storamic.elf"
        c = sh([f"{RISCV}/bin/riscv-none-elf-gcc", "-static",
                "-mcmodel=medany", "-march=rv64imafdc", "-mabi=lp64d",
                "-fvisibility=hidden", "-nostdlib", "-nostartfiles", "-O2",
                "-T", f"{COMMON}/link_verilator.ld",
                f"{COMMON}/syscalls.c", f"{COMMON}/crt.S", helloc,
                "-lgcc", f"-I{COMMON}", f"-I{ENVDIR}", "-o", str(elf)],
               work, env, out / "gcc-hello.log")
        runs = rep.setdefault("runs", {})
        if c.returncode:
            runs["hello"] = {"gcc_rc": c.returncode,
                             "gcc_tail": (c.stdout + c.stderr)[-1500:]}
        elif b.returncode:
            runs["hello"] = {"skipped": "harness build failed"}
        else:
            th = sh([f"{RISCV}/bin/riscv-none-elf-nm", str(elf)], work,
                    env).stdout
            m = re.search(r"([0-9a-f]+) [dDbB] tohost", th)
            tohost = int(m.group(1), 16) if m else 0
            sim = work / "work-ver/Variane_testharness"
            r = sh([str(sim), "+time_out=20000000", "+debug_disable",
                    f"+tohost_addr=0x{tohost:x}", str(elf)],
                   work, env, out / "sim-hello.log", timeout=3600)
            log = (out / "sim-hello.log").read_text()
            runs["hello"] = {"elf": elf.name, "tohost": hex(tohost),
                "rc": r.returncode,
                "success": "*** SUCCESS ***" in log and
                           "cycle budget reached" not in log,
                "tail": log[-1500:]}
    runs = rep.get("runs", {})
    # Positive ELF passes; the negative-oracle ELF fails at FAIL_IN_DATA (16).
    # In the primary-memory build hello_world must also pass.
    rep["verdict"] = "PASS" if (
        runs.get("pos", {}).get("success") and
        runs.get("neg", {}).get("fail_code") == "16" and
        (not primary or runs.get("hello", {}).get("success"))
    ) else "FAIL"
    (out / "native-virtio.json").write_text(json.dumps(rep, indent=2))
    return 0 if rep["verdict"] == "PASS" else 1

if __name__ == "__main__":
    raise SystemExit(main())
