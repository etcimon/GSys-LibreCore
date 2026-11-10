# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Coverage-tiered Storamic CI gate (build-platform suite ``storamic-ci``).

Levels are cumulative (``--coverage`` or ``$G6LC_COVERAGE``, default quick):

* quick     host unittests, minus the four slow collector/remote modules.
* standard  + Verilator lint of the configuration bench, and the protocol /
            configuration / region / map benches of ``run_leaf.py`` with
            their negative oracles (a representative profile subset).
* full      + every stick / slot / width profile, configuration lint across
            every target package, and the slow unittests.

The benches use the same commands and verdict markers as ``run_leaf.py``'s
protocol/config/region/map stages, on repository paths instead of the remote
leaf's identity-checked flat snapshot. A PASS is therefore a CI signal for
the selected tier, not leaf evidence and not media or CXL qualification.

Exit: 0 PASS, 1 FAIL, 2 usage, 3 tools.
"""

import argparse
import concurrent.futures
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[3]
HERE = ROOT / "verif/tb/storamic"
LEVELS = ("quick", "standard", "full")
SLOW_UNITTESTS = (
    "test_g6lc_collect_cpu_debug_return",
    "test_run_remote",
    "test_g6lc_collect_cpu_debug_queue",
    "test_g6lc_collect_cpu_debug_execution",
)
SRC = {
    "cfg": "g6lc_storamic/rtl/include/g6lc_storamic_cfg_pkg.sv",
    "pkg": "g6lc_storamic/rtl/include/g6lc_storamic_pkg.sv",
    "pad": "g6lc_storamic/rtl/include/g6lc_storamic_pad_pkg.sv",
    "refuse": "g6lc_storamic/rtl/frontend/g6lc_storamic_axi_refuse.sv",
    "region": "g6lc_storamic/rtl/fabric/g6lc_storamic_region_pkg.sv",
    "memory": "g6lc_storamic/rtl/frontend/g6lc_storamic_axi_memory.sv",
    "slot_mux": "g6lc_storamic/rtl/fabric/g6lc_storamic_slot_mux.sv",
    "regs": "g6lc_storamic/rtl/frontend/g6lc_storamic_regs.sv",
    "top": "g6lc_storamic/rtl/g6lc_storamic_top.sv",
    "sram": "verif/tb/storamic/g6lc_storamic_sram_model.sv",
    "config_pkg": "core/include/config_pkg.sv",
    "build_config": "core/include/build_config_pkg.sv",
    "smt2": "core/include/g6lc64_smt2_config_pkg.sv",
}
FOUNDATION = ["cfg", "pkg", "pad", "refuse", "region", "memory", "regs", "top"]
MAP = ["cfg", "pkg", "pad", "refuse", "region", "memory", "slot_mux", "regs", "top", "sram"]
SIM = ["--binary", "--timing", "--assert", "-j", "1", "--threads", "1", "-Wno-fatal",
       "-Werror-LATCH", "-Werror-UNOPTFLAT"]


def paths(keys, *extra):
    return [str(ROOT / SRC[k]) for k in keys] + [str(HERE / e) for e in extra]


def benches(tier):
    """(name, top, flags, sources, positive marker, expected error, negative marker)."""
    proto = paths(FOUNDATION, "tb_g6lc_storamic.sv")
    profiles = [
        ("one", ["-GMaxSticks=1"], None), ("three", ["-GMaxSticks=3"], None),
        ("off", ["-GEnable=0", "-GSkeleton=0"], None),
        ("zero", ["-GMaxSticks=0"], "STORAMIC_CONFIG_ILLEGAL"),
        ("overflow", ["-GMaxSticks=9"], "STORAMIC_CONFIG_ILLEGAL"),
    ]
    if tier >= 2:
        profiles += [
            ("two", ["-GMaxSticks=2"], None), ("four", ["-GMaxSticks=4"], None),
            ("eight", ["-GMaxSticks=8"], None),
            ("capability", ["-GRequestedCaps=1"], "STORAMIC_CONFIG_ILLEGAL"),
            ("not-skeleton", ["-GSkeleton=0"], "STORAMIC_CONFIG_ILLEGAL"),
        ]
    out = [(f"protocol-{name}", "tb_g6lc_storamic", flags, proto, "STORAMIC_FOUNDATION_PASS",
            error, "STORAMIC_ORACLE_NEGATIVE" if name == "three" else None)
           for name, flags, error in profiles]
    config = paths(["config_pkg", "smt2", "build_config", "cfg"], "tb_g6lc_storamic_config.sv")
    configs = [("default", [], None), ("enabled", ["-DG6LC_STORAMIC"], None),
               ("bad-geometry", ["-DG6LC_STORAMIC", "-GBadGeometry=1"],
                "STORAMIC_CORE_AXI_GEOMETRY")]
    if tier >= 2:
        configs.append(("bad-checkpoint", ["-GBadCheckpoint=1"],
                        "STORAMIC_CHECKPOINT_PRIMARY_REQUIRED"))
    out += [(f"config-{name}", "tb_g6lc_storamic_config",
             ["--binary", "--assert", "-j", "1", "-Wno-fatal", *flags], config,
             "STORAMIC_CORE_CONFIG_PASS", error, None) for name, flags, error in configs]
    out.append(("region", "tb_g6lc_storamic_region", [],
                paths(["cfg", "region"], "tb_g6lc_storamic_region.sv"),
                "STORAMIC_REGION_PASS", None, "STORAMIC_REGION_ORACLE_NEGATIVE"))
    maps = [("map-one", ["-GSlots=1"]), ("map-three-wide", ["-GSlots=3", "-GDataWidth=512"]),
            ("map-rt", ["-GSlots=3", "-GBootMapEn=0"])]
    if tier >= 2:
        maps += [("map-two", ["-GSlots=2"]), ("map-three", ["-GSlots=3"]),
                 ("map-four", ["-GSlots=4"]), ("map-eight", ["-GSlots=8"]),
                 ("map-one-wide", ["-GSlots=1", "-GDataWidth=512"]),
                 ("map-eight-wide", ["-GSlots=8", "-GDataWidth=512"])]
    maps.append(("map-illegal", ["-DSTORAMIC_MAP_ILLEGAL"]))
    out += [(name, "tb_g6lc_storamic_map", flags, paths(MAP, "tb_g6lc_storamic_map.sv"),
             "STORAMIC_MAP_PASS",
             "STORAMIC_MODEL_CONFIG_ILLEGAL" if name == "map-illegal" else None,
             "STORAMIC_MAP_ORACLE_NEGATIVE" if name == "map-one" else None)
            for name, flags in maps]
    return out


def run_bench(verilator, out, bench):
    name, top, flags, sources, marker, error, negative = bench
    model = out / name
    build = flags if flags[:1] == ["--binary"] else SIM + flags
    command = [verilator, *build, "--top-module", top, "--Mdir", str(model), "-o", "sim",
               *sources]
    started = time.monotonic()
    with (out / f"{name}-build.log").open("w") as log:
        built = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, cwd=out)
    if built.returncode:
        return name, False, f"build rc={built.returncode} (see {name}-build.log)", time.monotonic() - started
    run = subprocess.run([str(model / "sim")], capture_output=True, text=True, timeout=120)
    text = run.stdout + run.stderr
    (out / f"{name}-sim.log").write_text(text)
    ok = (run.returncode != 0 and error in text) if error else (
        run.returncode == 0 and marker in text)
    if not ok:
        return name, False, f"unexpected verdict rc={run.returncode}: {text[-600:]}", time.monotonic() - started
    if negative:
        neg = subprocess.run([str(model / "sim"), "+oracle_negative"], capture_output=True,
                             text=True, timeout=120)
        ntext = neg.stdout + neg.stderr
        (out / f"{name}-negative.log").write_text(ntext)
        if neg.returncode == 0 or negative not in ntext:
            return name, False, "negative oracle failed to reject", time.monotonic() - started
    shutil.rmtree(model, ignore_errors=True)
    return name, True, "negative oracle rejects" if negative else "", time.monotonic() - started


def lint_targets(tier):
    if tier < 2:
        return [ROOT / SRC["smt2"]]
    return sorted(p for p in (ROOT / "core/include").glob("*_config_pkg.sv")
                  if "cva6_user_cfg_t cva6_cfg" in p.read_text(encoding="utf-8"))


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--coverage", default=os.environ.get("G6LC_COVERAGE", "quick"))
    parser.add_argument("--out")
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 1)
    args = parser.parse_args()
    if args.coverage not in LEVELS:
        parser.error(f"unknown coverage level: {args.coverage}")
    tier = LEVELS.index(args.coverage)
    verilator = shutil.which(os.environ.get("VERILATOR", "verilator"))
    if tier >= 1 and not verilator:
        print(f"BLOCKED: coverage '{args.coverage}' needs Verilator (tools install verilator)")
        return 3
    out = Path(args.out or ROOT / "build-platform/workspace/build/storamic-ci" /
               time.strftime("%Y%m%d-%H%M%S")).resolve()
    if out.exists():
        print(f"refusing existing output: {out}")
        return 2
    out.mkdir(parents=True)
    print(f"STORAMIC-CI coverage={args.coverage} out={out}")
    results = []

    modules = sorted(p.stem for p in HERE.glob("test_*.py"))
    if tier < 2:
        modules = [m for m in modules if m not in SLOW_UNITTESTS]
    started = time.monotonic()
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    with (out / "unittests.log").open("w") as log:
        unit = subprocess.run([sys.executable, "-B", "-m", "unittest", *modules], cwd=HERE,
                              env=env, stdout=log, stderr=subprocess.STDOUT)
    results.append(("unittests", unit.returncode == 0,
                    f"{len(modules)} modules (see unittests.log)", time.monotonic() - started))

    if tier >= 1:
        print(subprocess.run([verilator, "--version"], capture_output=True,
                             text=True).stdout.strip())
        for target in lint_targets(tier):
            started = time.monotonic()
            command = [verilator, "--lint-only", "--assert", "-Wno-fatal",
                       "--top-module", "tb_g6lc_storamic_config",
                       str(ROOT / SRC["config_pkg"]), str(target), str(ROOT / SRC["build_config"]),
                       str(ROOT / SRC["cfg"]), str(HERE / "tb_g6lc_storamic_config.sv")]
            with (out / f"lint-{target.stem}.log").open("w") as log:
                lint = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
            results.append((f"lint-{target.stem}", lint.returncode == 0, "",
                            time.monotonic() - started))
        with concurrent.futures.ThreadPoolExecutor(max(1, args.jobs)) as pool:
            results += pool.map(lambda b: run_bench(verilator, out, b), benches(tier))

    fails = 0
    for name, ok, detail, seconds in results:
        fails += not ok
        line = f"{'PASS' if ok else 'FAIL'} {name} ({seconds:.0f}s)"
        print(line + (f" -- {detail}" if detail else ""))
    verdict = "PASS" if not fails else f"FAIL ({fails} of {len(results)})"
    print(f"STORAMIC-CI {verdict} ({len(results)} checks, coverage={args.coverage}; "
          "selected tier only)")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
