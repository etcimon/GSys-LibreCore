#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Remote-only research basis for policy-codec provisioning returns.
#
# Builds tb_g6lc_ai_gemm_backend on the testharness for each (PeLanes, MaxAROut)
# provisioning point and runs the +measure sweep, which walks the codec's own
# shape classes (bulk/decode/tall/wide/large) across every granted numeric format
# and every legal AR depth, twice per shape so run-to-run spread is measured.
#
# The question it answers: is there a provisioning choice the eight-state codec
# could make that yields a CALCULATED POSITIVE return against a single fixed
# provisioning?  Shape classes are the codec's own grouping, so a per-group
# optimum here is directly expressible as a policy code, and a per-group optimum
# that never beats the fixed baseline is proof the codec has no positive return
# to capture at that provisioning point.
#
# All Verilator work runs through verif/regress/remote/testharness_proxy.py.
# Local execution is refused: this script either dispatches or runs as the remote
# payload, so no result here can be a quietly local run.
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import uuid
from fractions import Fraction

SOURCES = (
    "core/include/config_pkg.sv",
    "corev_apu/include/g6lc_ai_island_cfg_pkg.sv",
    "corev_apu/ai_island/include/g6lc_ai_fp_pkg.sv",
    "corev_apu/ai_island/g6lc_ai_pe_dot.sv",
    "corev_apu/ai_island/g6lc_ai_pe_dot_float.sv",
    "corev_apu/ai_island/g6lc_ai_pe_dot_float_pipe.sv",
    "corev_apu/ai_island/g6lc_ai_tile_sram.sv",
    "corev_apu/ai_island/g6lc_ai_gemm_seq.sv",
    "corev_apu/ai_island/g6lc_ai_cap_window.sv",
    "corev_apu/src/g6lc_ai_dram_backend.sv",
    "corev_apu/ai_island/g6lc_ai_dram_timing.sv",
    "verif/tb/ai_island/tb_g6lc_ai_gemm_backend.sv",
)
VENDOR = (
    "vendor/pulp-platform/common_cells/src/cf_math_pkg.sv",
    "vendor/pulp-platform/common_cells/src/lzc.sv",
    "vendor/pulp-platform/common_cells/src/counter.sv",
    "vendor/pulp-platform/common_cells/src/delta_counter.sv",
    "vendor/pulp-platform/common_cells/src/fifo_v3.sv",
    "vendor/pulp-platform/common_cells/src/spill_register_flushable.sv",
    "vendor/pulp-platform/common_cells/src/spill_register.sv",
    "vendor/pulp-platform/common_cells/src/rr_arb_tree.sv",
    "vendor/pulp-platform/axi/src/axi_pkg.sv",
    "vendor/pulp-platform/axi/src/axi_intf.sv",
    "vendor/pulp-platform/axi/src/axi_id_prepend.sv",
    "vendor/pulp-platform/axi/src/axi_mux.sv",
    "vendor/pulp-platform/axi/src/axi_demux.sv",
    "vendor/pulp-platform/tech_cells_generic/src/rtl/tc_sram.sv",
    "common/local/util/tc_sram_wrapper.sv",
    "corev_apu/axi_mem_if/src/axi2mem.sv",
    "common/local/util/sram.sv",
)
# Macro headers. The proxy flattens every uploaded file into one data directory,
# but the sources include them by subdirectory path ("axi/typedef.svh"), so the
# remote side rebuilds that layout under the snapshot root before verilating.
INCLUDES = (
    ("vendor/pulp-platform/axi/include/axi/typedef.svh", "axi"),
    ("vendor/pulp-platform/axi/include/axi/assign.svh", "axi"),
    ("vendor/pulp-platform/common_cells/include/common_cells/registers.svh", "common_cells"),
    ("vendor/pulp-platform/common_cells/include/common_cells/assertions.svh", "common_cells"),
)
# Default provisioning points. Lanes below the 8-byte beat are excluded because
# SplitArId requires PeLanes >= BytesPerBeat and PeLanes=4 deadlocks the directed
# phase. The baseline point (8,2) is the shipped live provisioning and must stay
# in any point set, because every reported gain is measured against it.
DEFAULT_LANES = (8, 16, 32)
DEFAULT_AR = (2, 8)
BASELINE = (8, 2)
TOP = "tb_g6lc_ai_gemm_backend"
FORMATS = {0: "INT8", 1: "INT4", 3: "FP8_E4M3", 4: "FP8_E5M2", 5: "FP16", 6: "BF16", 7: "FP32"}
# Shape class -> the policy code the frozen codec assigns it (policy_encode:
# m<=1 with n,k>=2 is DECODE, n>m is WIDE, m>n is TALL, otherwise BULK).
SHAPE_GROUPS = {(8, 8): "BULK", (1, 16): "DECODE", (16, 1): "TALL",
                (2, 16): "WIDE", (16, 16): "BULK"}
RUN_RE = re.compile(r"^MEASURE fmt=(\d+) ar=(\d+) m=(\d+) n=(\d+) k=(\d+) macs=(\d+) cycles=(\d+) "
                    r"pmu_cycles=(\d+) r_beats=(\d+) w_beats=(\d+) c0=([0-9a-fA-F]+) c1=([0-9a-fA-F]+)$")


def parse_runs(text):
    runs = []
    for line in text.splitlines():
        match = RUN_RE.match(line.strip())
        if match:
            fields = [int(match.group(i)) for i in range(1, 11)]
            record = dict(zip(("numfmt", "ar", "m", "n", "k", "macs", "cycles",
                               "pmu_cycles", "r_beats", "w_beats"), fields))
            record["digest"] = match.group(11) + ":" + match.group(12)
            runs.append(record)
    return runs


def worst(runs, key):
    """Worst-case (largest) cycles per key, so no conclusion rests on a lucky pass."""
    table = {}
    for run in runs:
        table.setdefault(key(run), []).append(run["cycles"])
    return {name: max(values) for name, values in table.items()}


def analyse(points):
    """Per shape class and format, does any provisioning beat the fixed baseline?

    The baseline is the shipped live provisioning (8 lanes, AR 2). A positive
    return requires a provisioning point that is better for some shape class AND
    not simply better for every class, because a uniformly better point is a
    static configuration change, not something the codec adds value by choosing.
    """
    baseline = BASELINE
    if baseline not in points:
        raise RuntimeError("the shipped baseline point must be measured for gains to mean anything")
    shapes = sorted({(run["m"], run["n"]) for runs in points.values() for run in runs})
    report = {"baseline_point": {"lanes": baseline[0], "ar": baseline[1]},
              "shape_classes": [], "codec_value": {}}
    best_per_shape = {}
    for shape in shapes:
        entry = {"m": shape[0], "n": shape[1], "group": SHAPE_GROUPS.get(shape, "?"), "formats": []}
        for numfmt, name in sorted(FORMATS.items()):
            def cycles(point):
                runs = [r for r in points[point]
                        if (r["m"], r["n"]) == shape and r["numfmt"] == numfmt and r["ar"] == point[1]]
                return max(r["cycles"] for r in runs) if runs else None
            base = cycles(baseline)
            if base is None:
                continue
            options = {point: cycles(point) for point in points if cycles(point) is not None}
            winner = min(options, key=lambda p: (options[p], p[0], p[1]))
            entry["formats"].append({
                "format": name,
                "baseline_cycles": base,
                "best_point": {"lanes": winner[0], "ar": winner[1]},
                "best_cycles": options[winner],
                "gain_percent_milli": int(Fraction(base - options[winner], options[winner]) * 100000),
            })
            best_per_shape.setdefault(numfmt, {})[shape] = winner
        report["shape_classes"].append(entry)
    # The codec only earns its keep if the best point DIFFERS between shape
    # classes for the same format. One point winning everywhere is a static
    # provisioning decision that needs no runtime policy at all.
    verdict = {}
    for numfmt, per_shape in sorted(best_per_shape.items()):
        distinct = sorted({point for point in per_shape.values()})
        verdict[FORMATS[numfmt]] = {
            "distinct_best_points": [{"lanes": l, "ar": a} for l, a in distinct],
            "shape_dependent": len(distinct) > 1,
        }
    report["codec_value"] = {
        "per_format": verdict,
        "shape_dependent_formats": sorted(name for name, v in verdict.items() if v["shape_dependent"]),
        "meaning": "A runtime codec can only add throughput where the best provisioning point "
                   "differs between shape classes. Where one point wins every class, the correct "
                   "action is a static configuration change and the codec contributes nothing.",
    }
    return report


def remote(args):
    data = Path(os.environ["TH_DATA_DIR"]).resolve()
    parent = Path(os.environ["TH_OUT_DIR"]).resolve()
    if not data.is_dir() or not parent.is_dir():
        raise RuntimeError("proxy data/output parents must exist")
    out = Path(tempfile.mkdtemp(prefix="gemm-codec-basis-", dir=parent))
    work = Path(tempfile.mkdtemp(prefix="g6lc-gemm-codec-basis-"))
    snapshots = out / "sources"
    snapshots.mkdir()
    report = {"status": "RUNNING", "schema": "g6lc.codec-basis.v1", "sha256": {},
              "points": [], "channels": args.channels,
              "scope": "RTL simulation cycles from one testbench memory model; "
                       "not silicon, not wall clock, and no MAC/s rate",
              "provisioning_note": "PeLanes/MaxAROut are swept as research provisioning only; "
                                   "no shipped RTL parameter is changed by this run"}
    staged = {}
    for source in (*SOURCES, *VENDOR):
        original = data / Path(source).name
        if not original.is_file():
            raise RuntimeError("missing remote source: " + str(original))
        target = snapshots / original.name
        shutil.copy2(original, target)
        report["sha256"][source] = hashlib.sha256(target.read_bytes()).hexdigest()
        staged[source] = target
    for header, subdir in INCLUDES:
        original = data / Path(header).name
        if not original.is_file():
            raise RuntimeError("missing remote include: " + str(original))
        target = snapshots / subdir / Path(header).name
        target.parent.mkdir(exist_ok=True)
        shutil.copy2(original, target)
        report["sha256"][header] = hashlib.sha256(target.read_bytes()).hexdigest()
    report["runner_sha256"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()

    def run(command, name, timeout=1800):
        completed = subprocess.run(list(map(str, command)), cwd=work, check=False,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   text=True, timeout=timeout)
        if completed.returncode != 0:
            raise RuntimeError(name + " failed (rc=" + str(completed.returncode) + "): " +
                               completed.stdout[-2000:])
        return completed.stdout

    tool = None
    for candidate in (shutil.which("verilator"),
                      "/opt/testharness/toolchains/verilator-v5.008/bin/verilator",
                      "/root/tools/verilator-v5.008/bin/verilator"):
        if candidate and Path(candidate).is_file():
            tool = candidate
            report["verilator"] = run([tool, "--version"], "verilator-version").strip()
            break
    if tool is None:
        raise RuntimeError("no verilator on the remote host")

    try:
        collected = {}
        for lanes, ar in args.points:
            name = "l%d-a%d" % (lanes, ar)
            mdir = work / name
            command = [tool, "--binary", "--timing", "-Wno-fatal", "-Wno-TIMESCALEMOD",
                       "-Wno-UNUSED", "-Wno-UNOPTFLAT", "-Wno-WIDTHTRUNC", "-Wno-WIDTHEXPAND",
                       "-Wno-PINCONNECTEMPTY", "-Wno-CASEINCOMPLETE"]
            # Everything is flattened into one snapshot directory on the remote
            # host, so the include path is that directory rather than the repo
            # layout INCLUDE_DIRS names locally.
            command.append("-I" + str(snapshots))
            command += ["-GNCH=%d" % args.channels, "-GPE_LANES=%d" % lanes,
                        "-GAR_PROVISION=%d" % ar]
            command += [str(staged[source]) for source in (*VENDOR, *SOURCES)]
            command += ["--top-module", TOP, "-Mdir", str(mdir), "-o", TOP]
            run(command, name + "-verilate")
            text = run([mdir / TOP, "+measure"], name + "-simulate")
            runs = parse_runs(text)
            if not runs:
                raise RuntimeError(name + " produced no MEASURE records")
            digests = {}
            for record in runs:
                key = (record["numfmt"], record["m"], record["n"])
                digests.setdefault(key, set()).add(record["digest"])
            bad = [key for key, values in digests.items() if len(values) > 1]
            if bad:
                raise RuntimeError(name + " changed arithmetic across AR depth: " + str(bad))
            collected[(lanes, ar)] = runs
            report["points"].append({"lanes": lanes, "ar": ar, "records": len(runs),
                                     "digest_stable": True})
            (out / (name + ".log")).write_text(text, encoding="utf-8")
            print("BASIS_POINT lanes=%d ar=%d records=%d" % (lanes, ar, len(runs)), flush=True)
        report["records"] = {("%d/%d" % point): runs for point, runs in
                             ((p, len(r)) for p, r in collected.items())}
        report["analysis"] = analyse(collected)
        report["status"] = "PASS"
    except Exception as error:  # noqa: BLE001 - recorded in the artifact, then re-raised
        report.update(status="FAIL", error=str(error))
        raise
    finally:
        (out / "results.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        shutil.rmtree(work, ignore_errors=True)
    print("CODEC_BASIS " + json.dumps(report["analysis"]["codec_value"], indent=2), flush=True)
    return 0


def dispatch(args):
    root = Path(__file__).resolve().parents[2]
    proxy = root / "verif/regress/remote/testharness_proxy.py"
    files = [root / source for source in (*SOURCES, *VENDOR, *(h for h, _ in INCLUDES))]
    for path in [proxy, *files]:
        if not path.is_file():
            raise RuntimeError("required input missing: " + str(path))
    tag = ("ai-gemm-codec-basis-" +
           datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ-") +
           uuid.uuid4().hex[:12])

    def proxy_path(path):
        if os.name != "nt":
            return str(path)
        if len(path.drive) != 2 or path.drive[1] != ":":
            raise RuntimeError("WSL proxy requires a drive-qualified input: " + str(path))
        return "/mnt/" + path.drive[0].lower() + path.as_posix()[2:]

    launcher = ["wsl.exe", "--exec", "python3"] if os.name == "nt" else [sys.executable]
    command = [*launcher, proxy_path(proxy), "py", proxy_path(Path(__file__).resolve()),
               "--tag", tag, "--threads", "1", "--pull",
               "--env", "AI_GEMM_BASIS_CHANNELS=" + str(args.channels),
               "--env", "AI_GEMM_BASIS_LANES=" + args.lanes,
               "--env", "AI_GEMM_BASIS_AR=" + args.ar]
    for path in files:
        command.extend(("--data", proxy_path(path)))
    print("PROXY_ONLY " + shlex.join(command), flush=True)
    print("PULL_OUTPUT " + str(root / "remote-runs" / tag / "output"), flush=True)
    return 0 if args.dry_run else subprocess.run(command, cwd=root, check=False).returncode


def main():
    parser = argparse.ArgumentParser(
        description="Remote-only provisioning research basis for the AI-island policy codec")
    parser.add_argument("--channels", type=int,
                        default=int(os.environ.get("AI_GEMM_BASIS_CHANNELS", "1")),
                        help="DRAM stripe channels (default 1: no striping, isolates provisioning)")
    parser.add_argument("--lanes", default=os.environ.get("AI_GEMM_BASIS_LANES",
                        ",".join(map(str, DEFAULT_LANES))),
                        help="comma-separated PeLanes provisioning points (>= 8; must include 8)")
    parser.add_argument("--ar", default=os.environ.get("AI_GEMM_BASIS_AR",
                        ",".join(map(str, DEFAULT_AR))),
                        help="comma-separated MaxAROut provisioning points in [1,8] (must include 2)")
    parser.add_argument("--dry-run", action="store_true",
                        help="print the proxy command without running it")
    args = parser.parse_args()
    if args.channels not in (1, 2, 4, 8):
        parser.error("--channels must be 1, 2, 4 or 8")

    def points(text, name, low, high):
        try:
            values = sorted({int(part) for part in text.split(",") if part.strip()})
        except ValueError:
            parser.error("--" + name + " must be a comma-separated integer list")
        if not values or any(not low <= value <= high for value in values):
            parser.error("--" + name + " values must lie in [%d,%d]" % (low, high))
        if any(value & (value - 1) for value in values) and name == "lanes":
            parser.error("--lanes values must be powers of two")
        return values

    # PeLanes below BytesPerBeat=8 deadlock the sequencer, so they are refused
    # rather than measured and explained away.
    lanes = points(args.lanes, "lanes", 8, 256)
    ar = points(args.ar, "ar", 1, 8)
    if BASELINE[0] not in lanes or BASELINE[1] not in ar:
        parser.error("the shipped baseline point (lanes 8, ar 2) must be included")
    args.points = [(l, a) for l in lanes for a in ar]
    if os.environ.get("TH_DATA_DIR"):
        if args.dry_run:
            parser.error("--dry-run is a local dispatch option")
        return remote(args)
    return dispatch(args)


if __name__ == "__main__":
    sys.exit(main())
