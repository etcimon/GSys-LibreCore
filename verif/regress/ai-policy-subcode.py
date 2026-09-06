#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon

import argparse
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import uuid


SOURCES = (
    "core/include/config_pkg.sv",
    "corev_apu/ai_island/include/g6lc_ai_policy_pkg.sv",
    "corev_apu/ai_island/g6lc_ai_policy_subcode.sv",
    "corev_apu/ai_island/g6lc_ai_policy_codec.sv",
    "corev_apu/ai_island/g6lc_ai_policy_steer.sv",
    "verif/tb/ai_island/tb_g6lc_ai_policy_subcode.sv",
    "verif/tb/ai_island/policy_subcode_main.cpp",
)
TOP = "tb_g6lc_ai_policy_subcode"
SYNTH_TOP = "tb_g6lc_ai_policy_subcode_on"
DISABLED_TOP = "tb_g6lc_ai_policy_subcode_instance"
FORMAL_TOP = "tb_g6lc_ai_policy_subcode_control"
CACHE_SYNTH_TOP = "tb_g6lc_ai_policy_subcode_cache_on"
CACHE_FORMAL_TOP = "tb_g6lc_ai_policy_subcode_cache_control"
VARIANTS = (
    ("default", {}),
    ("read512", {"ReadBytesPerCycle": 512}),
    ("read-min-reduction-max", {
        "ReadBytesPerCycle": 1,
        "FormatStepCycles": 0xFEDCBA98,
        "FormatMinReductionLog2": 0x99999999,
    }),
    ("read-max-mixed-steps", {
        "ReadBytesPerCycle": 4096,
        "MinSavingsCycles": 31,
        "SwitchCycles": 17,
        "FormatStepCycles": 0x84218421,
        "FormatMinReductionLog2": 0x32103210,
        "GroupShapeLog2": 0x652120,
    }),
    ("custom-groups", {
        "ReadBytesPerCycle": 1,
        "MinSavingsCycles": 0,
        "SwitchCycles": 0,
        "GroupShapeLog2": 0x4490CA,
    }),
)


REPLAY_SCHEMA = "g6lc.policy-subcode-replay.v1"
REPLAY_TSV_SCHEMA = "g6lc.policy-subcode-replay.tsv.v1"
REPLAY_MAX_BYTES = 256 * 1024
REPLAY_PARAMETERS = ("ReadBytesPerCycle", "MinSavingsCycles", "SwitchCycles",
                     "FormatStepCycles", "FormatMinReductionLog2", "GroupShapeLog2")
REPLAY_FIELDS = ("m", "n", "k", "numfmt", "code", "balance", "baseline_topology", "subcode",
                 "selected_topology", "baseline_cycles", "selected_cycles")


def validate_replay(replay):
    def require(condition, message):
        if not condition:
            raise ValueError("policy subcode replay: " + message)

    def bounded(value, low, high):
        return type(value) is int and low <= value <= high

    require(type(replay) is dict and set(replay) == {"schema", "parameters", "records"}, "closed root fields required")
    require(replay["schema"] == REPLAY_SCHEMA, "wrong schema; B3 workload traces are not calibration replays")
    parameters = replay["parameters"]
    require(type(parameters) is dict and set(parameters) == set(REPLAY_PARAMETERS), "closed parameter fields required")
    read = parameters["ReadBytesPerCycle"]
    require(bounded(read, 1, 4096) and read & (read - 1) == 0, "read bandwidth must be power-of-two 1..4096")
    for key in ("MinSavingsCycles", "SwitchCycles"):
        require(bounded(parameters[key], 0, 65535), key + " must be unsigned 16-bit")
    for key in ("FormatStepCycles", "FormatMinReductionLog2"):
        require(bounded(parameters[key], 0, 2**32 - 1), key + " must be unsigned 32-bit")
    require(all(1 <= ((parameters["FormatStepCycles"] >> (4 * fmt)) & 15) <= 15 for fmt in range(8)),
            "every format step must be 1..15")
    require(all(((parameters["FormatMinReductionLog2"] >> (4 * fmt)) & 15) <= 9 for fmt in range(8)),
            "minimum reduction must be 0..9")
    groups = parameters["GroupShapeLog2"]
    require(bounded(groups, 0, 2**24 - 1), "group shapes must be unsigned 24-bit")
    for group in range(4):
        shape = (groups >> (6 * group)) & 63
        r, c = shape >> 3, shape & 7
        require(r <= 4 and c <= 4 and r + c <= 4, "illegal group shape")
    records = replay["records"]
    require(type(records) is list and 1 <= len(records) <= 1024, "records must contain 1..1024 entries")
    for index, record in enumerate(records):
        require(type(record) is dict and set(record) == set(REPLAY_FIELDS), "closed record fields required")
        for axis in ("m", "n", "k"):
            require(bounded(record[axis], 1, 256), "record " + str(index) + " invalid " + axis)
        for key in ("numfmt", "code", "subcode"):
            require(bounded(record[key], 0, 7), key + " must be unsigned 3-bit")
        require(bounded(record["balance"], 0, 3), "balance must be unsigned 2-bit")
        for key in ("baseline_cycles", "selected_cycles"):
            require(bounded(record[key], 0, 2**32 - 1), key + " must be unsigned 32-bit")
        fmt = record["numfmt"]
        for key in ("baseline_topology", "selected_topology"):
            packed = record[key]
            require(bounded(packed, 0, 2**23 - 1), key + " must be unsigned 23-bit")
            if fmt == 2:
                require(packed == 0, "unknown SP24 topology must be zero")
                continue
            r, c = (packed >> 18) & 7, (packed >> 15) & 7
            d, slots, bits = (packed >> 11) & 15, (packed >> 7) & 15, (packed >> 4) & 7
            expected_bits = (3, 2, 3, 3, 3, 4, 4, 5)[fmt]
            require((packed >> 22) == 1 and slots == ((0x67788098 >> (4 * fmt)) & 15) and
                    bits == expected_bits and r <= 4 and c <= 4 and r + c <= 4 and r + c + d == slots,
                    "invalid topology or nondefault slot table")
            require(record["m"] % (1 << r) == 0 and record["n"] % (1 << c) == 0,
                    "output-tail geometry is not valid")
            rows, cols = 1 << r, 1 << c
            gain = 16 * (2 * rows * cols - rows - cols) // (2 * rows * cols)
            require(((packed >> 21) & 1) == int(r + c != 0) and (packed & 15) == gain,
                    "inconsistent topology apply/reuse fields")
        eligible = fmt != 2 and record["code"] in (0, 3, 5, 6)
        if not eligible:
            require(record["subcode"] == 0 and record["baseline_cycles"] == 0 and record["selected_cycles"] == 0 and
                    record["selected_topology"] == record["baseline_topology"], "ineligible result must pass baseline unchanged")
        else:
            require(record["baseline_cycles"] > 0 and record["selected_cycles"] >= 32,
                    "eligible costs must include evaluator overhead")
            if record["subcode"] == 0:
                require(record["selected_topology"] == record["baseline_topology"] and
                        record["selected_cycles"] == record["baseline_cycles"] + 32,
                        "baseline winner must preserve topology and add 32 cycles")
    return replay


def decode_replay(raw):
    if type(raw) is not bytes or len(raw) > REPLAY_MAX_BYTES:
        raise ValueError("policy subcode replay: input exceeds 256 KiB or is not bytes")

    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError("policy subcode replay: duplicate JSON key " + key)
            result[key] = value
        return result

    def constant(value):
        raise ValueError("policy subcode replay: nonfinite number " + value)

    try:
        replay = json.loads(raw.decode("utf-8"), object_pairs_hook=pairs, parse_constant=constant)
    except (UnicodeError, RecursionError) as error:
        raise ValueError("policy subcode replay: invalid JSON encoding/depth") from error
    return validate_replay(replay)


def bounded_replay_bytes(path):
    path = Path(path)
    if not path.is_file():
        raise ValueError("policy subcode replay: input must be a regular file")
    with path.open("rb") as stream:
        raw = stream.read(REPLAY_MAX_BYTES + 1)
    if len(raw) > REPLAY_MAX_BYTES:
        raise ValueError("policy subcode replay: input exceeds 256 KiB")
    return raw


def replay_tsv(replay, source_sha256):
    validate_replay(replay)
    if type(source_sha256) is not str or re.fullmatch(r"[0-9a-f]{64}", source_sha256) is None:
        raise ValueError("policy subcode replay: invalid source SHA256")
    header = [REPLAY_TSV_SCHEMA, source_sha256, str(len(replay["records"]))]
    header.extend(str(replay["parameters"][key]) for key in REPLAY_PARAMETERS)
    lines = ["\t".join(header)]
    lines.extend("\t".join(str(record[key]) for key in REPLAY_FIELDS) for record in replay["records"])
    result = ("\n".join(lines) + "\n").encode("ascii")
    if len(result) > REPLAY_MAX_BYTES:
        raise ValueError("policy subcode replay: serialized data exceeds 256 KiB")
    return result


def replay_selftest():
    record = dict(zip(REPLAY_FIELDS, (1, 1, 1, 0, 0, 1, 4211760, 0, 4211760, 1, 33)))
    valid = {"schema": REPLAY_SCHEMA, "parameters": dict(zip(REPLAY_PARAMETERS,
             (128, 2, 2, 0x11111111, 0, 0x4420CA))), "records": [record]}
    raw = json.dumps(valid).encode("utf-8")
    if decode_replay(raw) != valid:
        raise RuntimeError("replay JSON roundtrip selftest failed")
    source_hash = hashlib.sha256(raw).hexdigest()
    serialized = replay_tsv(valid, source_hash)
    expected = (REPLAY_TSV_SCHEMA + "\t" + source_hash + "\t1\t128\t2\t2\t286331153\t0\t4464842\n" +
                "1\t1\t1\t0\t0\t1\t4211760\t0\t4211760\t1\t33\n").encode("ascii")
    if serialized != expected:
        raise RuntimeError("replay TSV field ordering selftest failed")
    tests = 2
    for code in (1, 2, 4, 7):
        fallback = json.loads(raw)
        fallback["records"][0].update(code=code, baseline_cycles=0, selected_cycles=0)
        validate_replay(fallback)
        tests += 1
    unknown = json.loads(raw)
    unknown["records"][0].update(numfmt=2, baseline_topology=0, selected_topology=0,
                                 baseline_cycles=0, selected_cycles=0)
    validate_replay(unknown)
    tests += 1
    extremes = json.loads(raw)
    extremes["parameters"].update(ReadBytesPerCycle=4096, MinSavingsCycles=65535, SwitchCycles=65535,
                                   FormatStepCycles=0xFFFFFFFF, FormatMinReductionLog2=0x99999999,
                                   GroupShapeLog2=0x652120)
    extremes["records"][0].update(baseline_cycles=15, selected_cycles=47)
    validate_replay(extremes)
    tests += 1

    def reject(value):
        nonlocal tests
        try:
            decode_replay(value if type(value) is bytes else json.dumps(value).encode("utf-8"))
        except (ValueError, TypeError):
            tests += 1
            return
        raise RuntimeError("replay validator accepted malformed selftest")

    def changed():
        return json.loads(raw)

    for records in ([], [record] * 1025, {}, None):
        bad = changed()
        bad["records"] = records
        reject(bad)
    for key, value in (("m", -1), ("m", 0), ("n", 257), ("k", 65536), ("m", True), ("k", 1.0),
                       ("numfmt", 8), ("code", -1), ("balance", 4), ("subcode", 8),
                       ("baseline_topology", 1 << 23), ("baseline_topology", 4211760 ^ (1 << 7)),
                       ("selected_topology", 4211760 ^ (1 << 4)), ("baseline_cycles", -1),
                       ("selected_cycles", 1 << 32), ("selected_cycles", 32)):
        bad = changed()
        bad["records"][0][key] = value
        reject(bad)
    bad = changed()
    bad["records"][0]["baseline_topology"] = (1 << 22) | (1 << 21) | (1 << 18) | (7 << 11) | (8 << 7) | (3 << 4) | 4
    reject(bad)
    for key, value in (("ReadBytesPerCycle", 0), ("ReadBytesPerCycle", 3), ("ReadBytesPerCycle", 8192),
                       ("ReadBytesPerCycle", True), ("MinSavingsCycles", -1), ("SwitchCycles", 65536),
                       ("FormatStepCycles", 0), ("FormatStepCycles", 1 << 32),
                       ("FormatMinReductionLog2", 0xA), ("GroupShapeLog2", 1 << 24), ("GroupShapeLog2", 63)):
        bad = changed()
        bad["parameters"][key] = value
        reject(bad)
    for section, key in ((None, "schema"), ("parameters", "SwitchCycles"), ("records", "m")):
        bad = changed()
        target = bad if section is None else bad[section][0] if section == "records" else bad[section]
        del target[key]
        reject(bad)
        bad = changed()
        target = bad if section is None else bad[section][0] if section == "records" else bad[section]
        target["unexpected"] = 1
        reject(bad)
    bad = changed()
    bad["schema"] = "g6lc.policy-workload.v1"
    reject(bad)
    reject(raw.replace(b'"m": 1', b'"m": 1, "m": 2'))
    reject(raw.replace(b'"ReadBytesPerCycle": 128', b'"ReadBytesPerCycle": 128, "ReadBytesPerCycle": 128'))
    reject(raw.replace(b'"records":', b'"records": [], "records":'))
    reject(raw.replace(b'"m": 1', b'"m": NaN'))
    reject(raw.replace(b'"m": 1', b'"m": Infinity'))
    reject(b"\xff")
    reject(b" " * (REPLAY_MAX_BYTES + 1))
    maximum = changed()
    maximum["records"] = [record] * 1024
    maximum_raw = json.dumps(maximum, separators=(",", ":")).encode("utf-8")
    if len(decode_replay(maximum_raw)["records"]) != 1024 or replay_tsv(maximum, source_hash).count(b"\n") != 1025:
        raise RuntimeError("replay maximum record count selftest failed")
    if decode_replay(raw + b" " * (REPLAY_MAX_BYTES - len(raw))) != valid:
        raise RuntimeError("replay exact byte limit selftest failed")
    print("REPLAY_VALIDATOR PASS tests=" + str(tests + 2) + " pure_python=1 byte_limit=262144 record_limit=1024", flush=True)


def arguments():
    parser = argparse.ArgumentParser(
        description="GSys LibreCore policy subcode controller: remote-only RTL scoreboard and explicit resource model"
    )
    parser.add_argument("--seed", default=os.environ.get("AI_POLICY_SUBCODE_SEED", "0x6c737562636f6465"))
    parser.add_argument("--parameters", choices=("default", "read512", "extremes"),
                        default=os.environ.get("AI_POLICY_SUBCODE_PARAMETERS", "extremes"))
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--replay", type=Path, metavar="FILE",
                        help="bounded g6lc.policy-subcode-replay.v1 JSON; local proxy dispatch only, not a B3 trace")
    parser.add_argument("--replay-selftest", action="store_true",
                        help="pure-Python replay validator/serialization tests; no tools or source execution")
    parser.add_argument("--synth-only", action="store_true",
                        help="explicit local Yosys only; never runs local Verilator")
    parser.add_argument("--yosys", type=Path, metavar="PATH",
                        help="existing Yosys executable, required for --synth-only; no fallback/install")
    parser.add_argument("--formal", choices=("off", "required"), default="off",
                        help="optional 36-cycle evaluator and 72-cycle cache control proofs with reachability")
    args = parser.parse_args()
    if args.replay and (args.synth_only or os.environ.get("TH_DATA_DIR")):
        parser.error("--replay is local proxy-dispatch only and incompatible with --synth-only")
    if args.replay_selftest and (args.replay or args.synth_only or args.yosys or args.formal != "off" or
                                args.dry_run or os.environ.get("TH_DATA_DIR")):
        parser.error("--replay-selftest cannot be combined with replay, execution, or synthesis options")
    if args.synth_only:
        if not args.yosys or args.dry_run or os.environ.get("TH_DATA_DIR"):
            parser.error("--synth-only requires --yosys PATH and rejects --dry-run/remote execution")
    elif args.yosys or args.formal != "off":
        parser.error("--yosys/--formal require --synth-only")
    try:
        seed = int(args.seed, 0)
    except ValueError:
        parser.error("seed must be an unsigned 64-bit integer")
    if not 0 <= seed < 2**64:
        parser.error("seed must be an unsigned 64-bit integer")
    args.seed = str(seed)
    return args


def dispatch(args):
    root = Path(__file__).resolve().parents[2]
    proxy = root / "verif/regress/remote/testharness_proxy.py"
    files = [root / source for source in SOURCES]
    for path in [proxy, *files]:
        if not path.is_file():
            raise RuntimeError("required input missing: " + str(path))
    tag = "ai-policy-subcode-" + datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:12]

    def proxy_path(path):
        if os.name != "nt":
            return str(path)
        if len(path.drive) != 2 or path.drive[1] != ":":
            raise RuntimeError("WSL proxy requires a drive-qualified input: " + str(path))
        return "/mnt/" + path.drive[0].lower() + path.as_posix()[2:]

    launcher = ["wsl.exe", "--exec", "python3"] if os.name == "nt" else [sys.executable]
    command = [*launcher, proxy_path(proxy), "py", proxy_path(Path(__file__).resolve()),
               "--tag", tag, "--threads", "1", "--pull",
               "--env", "AI_POLICY_SUBCODE_SEED=" + args.seed,
               "--env", "AI_POLICY_SUBCODE_PARAMETERS=" + args.parameters]
    if args.replay:
        raw = bounded_replay_bytes(args.replay)
        replay = decode_replay(raw)
        source_hash = hashlib.sha256(raw).hexdigest()
        serialized = replay_tsv(replay, source_hash)
        parent = root / "build-platform/workspace/build"
        if not parent.is_dir() or parent.resolve() != parent:
            raise RuntimeError("replay staging parent must exist without symlink redirection")
        stage = parent / tag
        stage.mkdir()
        source = stage / (tag + ".json")
        artifact = stage / (tag + ".tsv")
        source.write_bytes(raw)
        artifact.write_bytes(serialized)
        files.extend((source, artifact))
        command.extend(("--env", "AI_POLICY_SUBCODE_REPLAY=" + artifact.name))
        print("REPLAY_STAGE " + json.dumps({"source_sha256": source_hash,
              "tsv_sha256": hashlib.sha256(serialized).hexdigest(), "records": len(replay["records"]),
              "artifact": str(artifact), "source_execution_verified": False}), flush=True)
    for path in files:
        command.extend(("--data", proxy_path(path)))
    print("PROXY_ONLY " + shlex.join(command), flush=True)
    print("PULL_OUTPUT " + str(root / "remote-runs" / tag / "output"), flush=True)
    return 0 if args.dry_run else subprocess.run(command, cwd=root, check=False).returncode


WORKLOAD_SHAPES = {
    "dense_prefill": (0, ((128, 256, 256), (256, 256, 256), (128, 128, 128))),
    "dense_decode": (3, ((1, 256, 256), (4, 256, 256), (1, 128, 129))),
    "routed_experts": (5, ((3, 256, 256), (7, 256, 256), (17, 256, 256),
                            (33, 256, 255), (65, 256, 256))),
    "diffusion_matrices": (0, ((256, 256, 256), (256, 64, 64), (256, 256, 80), (235, 65, 256))),
}
FIXTURE_BITS = {0: 8, 1: 4, 3: 8, 4: 8, 5: 16, 6: 16, 7: 32}


def workload_fixture_report(text, parameters):
    def require(condition, message):
        if not condition:
            raise RuntimeError("handcrafted TILE report: " + message)

    def integer(value, minimum=0):
        return type(value) is int and value >= minimum

    def closed_pairs(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "duplicate JSON field " + key)
            result[key] = value
        return result

    def finite_constant(value):
        raise RuntimeError("handcrafted TILE report: nonfinite JSON value " + value)

    records = [json.loads(line[14:], object_pairs_hook=closed_pairs, parse_constant=finite_constant)
               for line in text.splitlines() if line.startswith("WORKLOAD_TILE ")]
    marker = re.search(r"^WORKLOAD_FIXTURES PASS jobs=105 reports=28 formats=7 checks=\d+$", text, re.M)
    require(marker is not None, "missing fixture scoreboard marker")
    require(len(records) == 28, "expected 28 separate workload/format totals")
    expected_keys = {(name, fmt) for name in WORKLOAD_SHAPES for fmt in FIXTURE_BITS}
    row_fields = {
        "name", "scope", "baseline", "fmt", "code", "balance", "jobs", "macs",
        "baseline_compute_cycles", "selected_compute_cycles", "evaluator_cycles", "switch_cycles",
        "shared_external_cycles", "baseline_cycles", "selected_cycles", "time_reduction_percent",
        "baseline_macs_per_cycle", "selected_macs_per_cycle", "throughput_delta_percent",
        "regression", "improved_jobs", "regressed_jobs", "unchanged_jobs", "winner_usage", "tiles",
    }
    tile_fields = {"m", "n", "k", "baseline_topology", "selected_topology", "subcode",
                   "baseline_compute_cycles", "selected_resource_cycles", "selected_compute_cycles", "external_cycles"}
    read_bytes = parameters.get("ReadBytesPerCycle", 128)
    switch_cycles = parameters.get("SwitchCycles", 2)
    min_savings = parameters.get("MinSavingsCycles", 2)
    format_steps = parameters.get("FormatStepCycles", 0x11111111)
    seen = set()
    for row in records:
        require(type(row) is dict and set(row) == row_fields, "unexpected row schema")
        require(type(row["name"]) is str and integer(row["fmt"]), "invalid name/format")
        key = row["name"], row["fmt"]
        require(key in expected_keys and key not in seen, "unexpected/duplicate workload and format")
        seen.add(key)
        code, shapes = WORKLOAD_SHAPES[row["name"]]
        require(row["scope"] == "handcrafted TILE fixtures; not full operator/model capture" and
                row["baseline"] == "current_allocator", "incorrect baseline or capture claim")
        require(integer(row["code"]) and row["code"] == code and
                integer(row["balance"]) and row["balance"] == 1, "fixture policy/balance mismatch")
        require(type(row["tiles"]) is list and len(row["tiles"]) == len(shapes), "tile count mismatch")
        bits = FIXTURE_BITS[row["fmt"]]
        step = (format_steps >> (4 * row["fmt"])) & 15
        usage = [0] * 8
        sums = dict.fromkeys(("macs", "baseline_compute_cycles", "selected_compute_cycles",
                              "shared_external_cycles", "switch_cycles", "improved_jobs",
                              "regressed_jobs", "unchanged_jobs"), 0)
        for tile, shape in zip(row["tiles"], shapes):
            require(type(tile) is dict and set(tile) == tile_fields and
                    all(integer(value) for value in tile.values()), "invalid tile schema/integer")
            require(tuple(tile[axis] for axis in ("m", "n", "k")) == shape, "unmatched tile shape")
            require(tile["subcode"] < 8, "invalid winner")
            m, n, k = shape

            def resource_cost(packed):
                require(packed < 2**23 and (packed >> 22) == 1, "invalid packed topology")
                r, c, d = (packed >> 18) & 7, (packed >> 15) & 7, (packed >> 11) & 15
                slots = (packed >> 7) & 15
                require(r <= 4 and c <= 4 and r + c <= 4 and r + c + d == slots and
                        1 <= slots <= 9 and (1 << ((packed >> 4) & 7)) == bits and
                        m % (1 << r) == 0 and n % (1 << c) == 0, "invalid topology geometry/format")
                depth = 1 << d
                full, tail = divmod(k, depth)

                def service(elements):
                    row_bytes = (elements * bits + 7) // 8
                    return max(step, (((1 << r) + (1 << c)) * row_bytes + read_bytes - 1) // read_bytes)

                return (m >> r) * (n >> c) * (full * service(depth) + (service(tail) if tail else 0))

            require(tile["baseline_compute_cycles"] == resource_cost(tile["baseline_topology"]),
                    "baseline allocator cost mismatch")
            require(tile["selected_resource_cycles"] == resource_cost(tile["selected_topology"]),
                    "selected resource cost mismatch")
            tax = 32 + (switch_cycles if tile["subcode"] else 0)
            require(tile["selected_compute_cycles"] == tile["selected_resource_cycles"] + tax,
                    "evaluation/switch cost not included")
            if tile["subcode"] == 0:
                require(tile["selected_topology"] == tile["baseline_topology"], "baseline winner changed topology")
            else:
                require(tile["selected_compute_cycles"] + min_savings < tile["baseline_compute_cycles"],
                        "alternative violates strict savings threshold")
            external = ((m + n) * ((k * bits + 7) // 8) + 8 * m * n + 7) // 8
            require(tile["external_cycles"] == external, "external cost mismatch")
            sums["macs"] += m * n * k
            sums["baseline_compute_cycles"] += tile["baseline_compute_cycles"]
            sums["selected_compute_cycles"] += tile["selected_compute_cycles"]
            sums["shared_external_cycles"] += external
            sums["switch_cycles"] += tax - 32
            delta = tile["selected_compute_cycles"] - tile["baseline_compute_cycles"]
            sums["improved_jobs"] += delta < 0
            sums["regressed_jobs"] += delta > 0
            sums["unchanged_jobs"] += delta == 0
            usage[tile["subcode"]] += 1
        sums.update(jobs=len(shapes), evaluator_cycles=32 * len(shapes),
                    baseline_cycles=sums["baseline_compute_cycles"] + sums["shared_external_cycles"],
                    selected_cycles=sums["selected_compute_cycles"] + sums["shared_external_cycles"])
        require(all(integer(row[field]) and row[field] == value for field, value in sums.items()),
                "aggregate total mismatch")
        require(type(row["winner_usage"]) is list and len(row["winner_usage"]) == 8 and
                all(integer(value) for value in row["winner_usage"]) and row["winner_usage"] == usage,
                "winner histogram mismatch")
        base, selected, macs = sums["baseline_cycles"], sums["selected_cycles"], sums["macs"]
        metrics = {"time_reduction_percent": 100 * (1 - selected / base),
                   "throughput_delta_percent": 100 * (base / selected - 1),
                   "baseline_macs_per_cycle": macs / base, "selected_macs_per_cycle": macs / selected}
        require(all(type(row[field]) in (int, float) and math.isfinite(row[field]) and
                    math.isclose(row[field], value, rel_tol=1e-8, abs_tol=1e-6)
                    for field, value in metrics.items()), "throughput/time metric mismatch")
        require(type(row["regression"]) is bool and row["regression"] == (selected > base),
                "regression was hidden or mislabeled")
    require(seen == expected_keys, "missing workload/format pairs")
    return {"status": "PASS", "result": marker.group(0),
            "scope": "handcrafted TILE fixtures; not full operator/model capture",
            "baseline": "current_allocator", "records": records}


def performance_feedback(records):
    if not records or any(type(row.get(key)) is not int or row[key] <= 0
                          for row in records for key in ("baseline_cycles", "selected_cycles")):
        raise RuntimeError("performance feedback requires positive matched cycle counts")
    ratios = [row["selected_cycles"] / row["baseline_cycles"] for row in records]
    normalized_time = sum(ratios) / len(ratios)
    regressions = sum(row["selected_cycles"] > row["baseline_cycles"] for row in records)
    improvements = sum(row["selected_cycles"] < row["baseline_cycles"] for row in records)
    return {
        "status": "NOT_QUALIFIED",
        "model_screen_pass": regressions == 0 and improvements > 0,
        "improved_workload_format_pairs": improvements,
        "regressed_workload_format_pairs": regressions,
        "normalization": "equal workload-family/format weight after own-baseline normalization",
        "normalized_time_reduction_percent": 100 * (1 - normalized_time),
        "normalized_throughput_delta_percent": 100 * (1 / normalized_time - 1),
        "held_out_model_capture": False,
        "live_pe_consumer_verified": False,
        "physical_timing_verified": False,
        "decision": "retain production-off gate; synthetic correctness is not MAC/s qualification",
    }


def feedback_selftest():
    for costs, expected in (((80, 90), True), ((80, 120), False), ((100, 100), False)):
        report = performance_feedback([{"baseline_cycles": 100, "selected_cycles": value} for value in costs])
        if report["model_screen_pass"] != expected or report["status"] != "NOT_QUALIFIED":
            raise RuntimeError("performance feedback promotion boundary failed")
    for records in ([], [{"baseline_cycles": 0, "selected_cycles": 1}]):
        try:
            performance_feedback(records)
        except RuntimeError:
            continue
        raise RuntimeError("performance feedback accepted invalid counts")
    print("FEEDBACK PASS positive, regression, tie and invalid-count controls; no synthetic promotion", flush=True)


def remote(args):
    data = Path(os.environ["TH_DATA_DIR"]).resolve()
    parent = Path(os.environ["TH_OUT_DIR"]).resolve()
    if not data.is_dir() or not parent.is_dir():
        raise RuntimeError("proxy data/output parents must exist")
    out = Path(tempfile.mkdtemp(prefix="policy-subcode-results-", dir=parent))
    work = Path(tempfile.mkdtemp(prefix="g6lc-policy-subcode-build-"))
    snapshots = out / "sources"
    snapshots.mkdir()
    report = {
        "status": "RUNNING", "seed": args.seed, "parameter_mode": args.parameters,
        "scope": "subcode controller and actual steering sidecar RTL; conflict-free MAC/cycle model, not measured GEMM/SoC throughput",
        "external_cost": "ceil(((M+N)*ceil(K*element_bits/8)+8*M*N)/8), shared by baseline and selected",
        "formal": {"status": "NOT_RUN", "claim": "none", "reason": "simulation mode"},
        "sha256": {}, "variants": [],
    }
    try:
        for source in SOURCES:
            original = data / Path(source).name
            if not original.is_file():
                raise RuntimeError("missing remote source: " + str(original))
            target = snapshots / original.name
            shutil.copy2(original, target)
            report["sha256"][source] = hashlib.sha256(target.read_bytes()).hexdigest()
        report["runner_sha256"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        shutil.copy2(Path(__file__), snapshots / "ai-policy-subcode.py")
        captured = None
        replay_name = os.environ.get("AI_POLICY_SUBCODE_REPLAY")
        if replay_name:
            if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,120}\.tsv", replay_name) is None:
                raise RuntimeError("invalid staged replay basename")
            raw = bounded_replay_bytes(data / (replay_name[:-4] + ".json"))
            captured = decode_replay(raw)
            source_hash = hashlib.sha256(raw).hexdigest()
            serialized = bounded_replay_bytes(data / replay_name)
            if serialized != replay_tsv(captured, source_hash):
                raise RuntimeError("staged replay TSV differs from validated source JSON/provenance")
            (snapshots / replay_name).write_bytes(serialized)
            (snapshots / (replay_name[:-4] + ".json")).write_bytes(raw)
            report["replay"] = {"status": "RUNNING", "variant": "captured-replay",
                                "parameters": captured["parameters"], "records": len(captured["records"]),
                                "source_sha256": source_hash, "tsv_sha256": hashlib.sha256(serialized).hexdigest(),
                                "source_execution_verified": False, "b3_trace": False,
                                "scope": "captured calibration expectations vs independent C++ and actual controller RTL; "
                                         "not proof of source workload execution or MAC/s qualification"}

        def run(command, name, required=True):
            command = list(map(str, command))
            print("RUN " + shlex.join(command), flush=True)
            result = subprocess.run(command, cwd=snapshots, capture_output=True, text=True,
                                    check=False, timeout=900)
            text = result.stdout + result.stderr
            (out / (name + ".log")).write_text(
                "COMMAND " + shlex.join(command) + "\n" + text +
                "\nRETURN_CODE " + str(result.returncode) + "\n", encoding="utf-8")
            if required and (result.returncode or "%Warning" in text):
                print(text[-16000:], flush=True)
                raise RuntimeError(name + " failed or emitted Verilator warnings")
            return result.returncode, text

        candidates = [shutil.which("verilator"),
                      "/opt/testharness/toolchains/verilator-v5.008/bin/verilator",
                      "/root/tools/verilator-v5.008/bin/verilator"]
        tool = None
        for index, candidate in enumerate(dict.fromkeys(candidates)):
            if not candidate or not Path(candidate).is_file() or not os.access(candidate, os.X_OK):
                continue
            rc, version = run([candidate, "--version"], "version-" + str(index), required=False)
            if rc == 0 and re.search(r"\bVerilator\s+5\.008\b", version):
                tool = candidate
                report["verilator"] = version.strip()
                break
        if tool is None:
            raise RuntimeError("Verilator 5.008 unavailable on remote host; no implicit installs or fallback version")
        sv = [snapshots / Path(source).name for source in SOURCES if source.endswith(".sv")]
        variants = VARIANTS if args.parameters == "extremes" else tuple(
            variant for variant in VARIANTS if variant[0] == args.parameters)
        if not variants:
            raise RuntimeError("no selected parameter profile")
        for name, parameters in variants:
            variant = {"name": name, "parameters": parameters, "status": "RUNNING"}
            report["variants"].append(variant)
            overrides = ["-G" + key + "=" + ("24" if key == "GroupShapeLog2" else "32") +
                         "'h" + format(value, "x") for key, value in parameters.items()]
            run([tool, "--lint-only", "--assert", "--top-module", TOP, *overrides, *sv], name + "-lint")
            mdir = work / name
            run([tool, "--cc", "--exe", "--build", "--assert", "-j", "2", "--top-module", TOP,
                 "--Mdir", mdir, "-CFLAGS", "-std=c++17 -Wall -Wextra -Werror", *overrides, *sv,
                 snapshots / "policy_subcode_main.cpp"], name + "-build")
            _, text = run([mdir / ("V" + TOP), args.seed], name + "-simulation")
            marker = re.search(r"^PASS policy_subcode cases=\d+ eligible=\d+ ineligible=\d+ checks=\d+$", text, re.M)
            if marker is None:
                raise RuntimeError(name + " missing scoreboard pass marker")
            integration = re.search(
                r"^INTEGRATION PASS accepts=\d+ results=\d+ cancellations=\d+ cycles=\d+ "
                r"formats=255 families=15 ages=0\.\.35 burst=128 legacy_equivalence=all_outputs$", text, re.M)
            if integration is None:
                raise RuntimeError(name + " missing actual steering integration pass marker")
            models = [json.loads(line[6:]) for line in text.splitlines() if line.startswith("MODEL ")]
            expected = {(family, fmt) for family in ("bulk", "decode", "routed", "sparse")
                        for fmt in (0, 1, 3, 4, 5, 6, 7)}
            if len(models) != 28 or {(row["family"], row["fmt"]) for row in models} != expected:
                raise RuntimeError(name + " incomplete per-family/format model totals")
            fixtures = workload_fixture_report(text, parameters)
            variant.update(status="PASS", result=marker.group(0), integration=integration.group(0), model_totals=models,
                           workload_fixtures=fixtures, performance_feedback=performance_feedback(fixtures["records"]),
                           coverage=[line for line in text.splitlines() if line.startswith("COVERAGE ")])
            print(text, flush=True)
        report["cache_tests"] = []
        for profile, parameters in variants:
            name = "cache-" + profile
            variant = {"name": name, "parameters": dict(parameters, CacheEn=1), "status": "RUNNING"}
            report["cache_tests"].append(variant)
            overrides = ["-GCacheEn=1'b1", *["-G" + key + "=" + ("24" if key == "GroupShapeLog2" else "32") +
                         "'h" + format(value, "x") for key, value in parameters.items()]]
            run([tool, "--lint-only", "--assert", "--top-module", TOP, *overrides, *sv], name + "-lint")
            mdir = work / name
            run([tool, "--cc", "--exe", "--build", "--assert", "-j", "2", "--top-module", TOP,
                 "--Mdir", mdir, "-CFLAGS", "-std=c++17 -Wall -Wextra -Werror", *overrides, *sv,
                 snapshots / "policy_subcode_main.cpp"], name + "-build")
            _, text = run([mdir / ("V" + TOP), args.seed], name + "-simulation")
            marker = re.search(r"^CACHE PASS hits=\d+ misses=\d+ steer_hits=\d+ checks=\d+ "
                               r"hit_cycles=1 miss_cycles=32 key_bits=all cancel_ages=0\.\.31 "
                               r"legacy_equivalence=all_outputs$", text, re.M)
            if marker is None:
                raise RuntimeError(name + " missing cache scoreboard pass marker")
            variant.update(status="PASS", result=marker.group(0),
                           scope="directed controller cache latency, cost and cancellation tests; not workload throughput")
            print(text, flush=True)
        if captured is not None:
            parameters = captured["parameters"]
            overrides = ["-G" + key + "=" + ("24" if key == "GroupShapeLog2" else "32") +
                         "'h" + format(parameters[key], "x") for key in REPLAY_PARAMETERS]
            name = "captured-replay"
            mdir = work / name
            run([tool, "--lint-only", "--assert", "--top-module", TOP, *overrides, *sv], name + "-lint")
            run([tool, "--cc", "--exe", "--build", "--assert", "-j", "2", "--top-module", TOP,
                 "--Mdir", mdir, "-CFLAGS", "-std=c++17 -Wall -Wextra -Werror", *overrides, *sv,
                 snapshots / "policy_subcode_main.cpp"], name + "-build")
            _, text = run([mdir / ("V" + TOP), args.seed, "--replay", snapshots / replay_name], name + "-simulation")
            marker = ("REPLAY PASS count=" + str(len(captured["records"])) + " source_sha256=" +
                      report["replay"]["source_sha256"] +
                      " reference=independent rtl=checked source_execution_verified=0")
            if text.splitlines().count(marker) != 1:
                raise RuntimeError("captured replay lacks exact record count/provenance PASS marker")
            report["replay"].update(status="PASS", result=marker)
            print(text, flush=True)
        report["status"] = "PASS"
    except Exception as error:
        report.update(status="FAIL", error=str(error))
        if report.get("replay", {}).get("status") == "RUNNING":
            report["replay"]["status"] = "FAIL"
        raise
    finally:
        (out / "results.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print("RESULTS " + str(out / "results.json"), flush=True)
    return 0


def yosys_quote(path):
    return '"' + Path(path).as_posix().replace('"', '\\"') + '"'


def local_synthesis(args):
    root = Path(__file__).resolve().parents[2]
    parent = root / "build-platform/workspace/build"
    if not parent.is_dir() or parent.resolve() != parent:
        raise RuntimeError("local synthesis build parent must exist without symlink redirection")
    tool = args.yosys.expanduser().resolve()
    if not tool.is_file() or not os.access(tool, os.X_OK):
        raise RuntimeError("--yosys must name an existing executable; no fallback or install")
    out = parent / ("ai-policy-subcode-synth-" +
                    datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ-") +
                    uuid.uuid4().hex[:12])
    out.mkdir()
    env = dict(os.environ)
    if os.name == "nt":
        env["PATH"] = os.pathsep.join((str(tool.parent), str(tool.parent.parent / "lib"), env.get("PATH", "")))
        env["YOSYSHQ_ROOT"] = tool.parent.parent.as_posix().rstrip("/") + "/"
    env.update({name: str(out) for name in ("TMP", "TEMP", "TMPDIR")})
    report = {"status": "RUNNING", "mode": "local-synthesis-only", "sha256": {},
              "scope": "isolated controller generic cells, not technology area/timing or SoC proof",
              "formal": {"status": "NOT_RUN", "claim": "none", "reason": "--formal off"}}
    print("LOCAL_SYNTH_ONLY " + str(out), flush=True)

    def run(command, name, required=True, timeout=900):
        command = list(map(str, command))
        print("RUN " + shlex.join(command), flush=True)
        log = out / (name + ".log")
        with log.open("w", encoding="utf-8") as stream:
            stream.write("COMMAND " + shlex.join(command) + "\n")
            stream.flush()
            try:
                result = subprocess.run(command, cwd=out, env=env, stdout=stream,
                                        stderr=subprocess.STDOUT, check=False, timeout=timeout)
            except subprocess.TimeoutExpired:
                stream.write("\nTIMEOUT_SECONDS " + str(timeout) + "\n")
                raise RuntimeError(name + " timed out; no proof/synthesis claim") from None
            stream.write("\nRETURN_CODE " + str(result.returncode) + "\n")
        text = log.read_text(encoding="utf-8", errors="replace")
        if required and result.returncode:
            print(text[-16000:], flush=True)
            raise RuntimeError(name + " failed; see " + str(log))
        return result.returncode, text

    try:
        files = []
        for source in SOURCES:
            path = root / source
            if not path.is_file():
                raise RuntimeError("required input missing: " + str(path))
            target = out / path.name
            shutil.copy2(path, target)
            report["sha256"][source] = hashlib.sha256(target.read_bytes()).hexdigest()
            if path.suffix == ".sv":
                files.append(target.name)
        runner = Path(__file__).resolve()
        shutil.copy2(runner, out / runner.name)
        report["runner_sha256"] = hashlib.sha256((out / runner.name).read_bytes()).hexdigest()
        _, report["yosys_version"] = run([tool, "-V"], "yosys-version")
        modules = [[]]
        if os.environ.get("YOSYS_SLANG_PLUGIN"):
            modules.append(["-m", os.environ["YOSYS_SLANG_PLUGIN"]])
        modules.append(["-m", "slang"])
        frontend = None
        for index, plugin in enumerate(modules):
            command = [tool, *plugin, "-Q", "-T"]
            rc, text = run([*command, "-p", "help read_slang"], "frontend-" + str(index), required=False)
            if rc == 0 and "No such command" not in text and "read_slang" in text:
                frontend = command
                break
        if frontend is None:
            raise RuntimeError("specified Yosys lacks read_slang; no installation or tool fallback")
        report["yosys_command"] = list(map(str, frontend))
        sources = " ".join(files)
        report["synthesis"] = {}
        for top in (SYNTH_TOP, DISABLED_TOP, CACHE_SYNTH_TOP):
            netlist = out / (top + ".json")
            script = ("read_slang --top " + top + " " + sources +
                      "; synth -top " + top + " -flatten; check -assert; write_json " +
                      yosys_quote(netlist) + "; stat")
            run([*frontend, "-p", script], "synth-" + top)
            design = json.loads(netlist.read_text(encoding="utf-8"))
            module = design["modules"][top]
            cells = module.get("cells", {})
            if any("latch" in cell["type"].lower() for cell in cells.values()):
                raise RuntimeError(top + " retained latches")
            if any(cell["type"] in design["modules"] or not cell["type"].startswith("$")
                   for cell in cells.values()):
                raise RuntimeError(top + " contains unflattened/unknown cells")
            sequential = sum("dff" in cell["type"].lower() for cell in cells.values())
            if top == DISABLED_TOP:
                if cells:
                    raise RuntimeError("Enabled=0 retained cells")
                for name, port in module["ports"].items():
                    if port["direction"] == "output" and any(bit != "0" for bit in port["bits"]):
                        raise RuntimeError("Enabled=0 output is not constant zero: " + name)
            elif not cells or not sequential:
                raise RuntimeError("enabled top lost its sequential implementation")
            report["synthesis"][top] = {"status": "PASS", "cells": len(cells),
                                        "sequential_cells": sequential, "latches": 0}
            print("SYNTH PASS " + top + " " + json.dumps(report["synthesis"][top]), flush=True)
        if args.formal == "required":
            report["formal"] = {"status": "RUNNING", "claim": "none", "cycles": 36}
            rc, text = run([*frontend, "-p", "help sat"], "sat-probe", required=False)
            if rc or "No such command" in text or any(flag not in text for flag in
                    ("-seq", "-set-init-zero", "-set-assumes", "-prove-asserts", "-verify", "-falsify")):
                raise RuntimeError("required bounded SAT controls unavailable")
            netlist = out / "formal-control.json"
            sat = "sat -seq 36 -set-init-zero -set-assumes"
            script = ("read_slang -DFORMAL --top " + FORMAL_TOP + " " + sources +
                      "; prep -top " + FORMAL_TOP + " -flatten; async2sync; opt; check -assert; " +
                      "write_json " + yosys_quote(netlist) + "; " + sat + " -prove-asserts -verify")
            _, text = run([*frontend, "-p", script], "formal-control-36", timeout=180)
            if "SAT proof finished - no model found: SUCCESS!" not in text:
                raise RuntimeError("bounded control proof lacks explicit success marker")
            design = json.loads(netlist.read_text(encoding="utf-8"))
            assertions = sum(cell["type"] == "$assert" or
                             (cell["type"] == "$check" and cell["parameters"].get("FLAVOR") == "assert")
                             for cell in design["modules"][FORMAL_TOP].get("cells", {}).values())
            if assertions < 4:
                raise RuntimeError("bounded control proof retained fewer than four assertions")
            script = ("read_json " + yosys_quote(netlist) + "; " + sat +
                      " -prove valid_o 0 -falsify -show-inputs -show-outputs -dump_vcd " +
                      yosys_quote(out / "reachable-result-36.vcd"))
            _, text = run([*frontend, "-p", script], "reachable-result-36", timeout=180)
            if "SAT proof finished - model found: FAIL!" not in text:
                raise RuntimeError("no reachable completed-result witness within 36 cycles")
            report["formal"] = {
                "status": "PASS", "cycles": 36, "assertions": assertions, "result": "REACHABLE",
                "scope": "fixed eligible INT4 16x16x17 fixture; arbitrary start/enable/flush/reset/testmode; "
                         "bounded control safety and completion reachability, not induction, datapath or integration proof",
                "initial_state": "set-init-zero, initial sampled reset assumed low; async2sync clock-step model",
            }
            print("FORMAL PASS " + json.dumps(report["formal"]), flush=True)
            report["cache_formal"] = {"status": "RUNNING", "claim": "none", "cycles": 72}
            netlist = out / "formal-cache-control.json"
            sat = "sat -seq 72 -set-init-zero -set-assumes"
            script = ("read_slang -DFORMAL --top " + CACHE_FORMAL_TOP + " " + sources +
                      "; prep -top " + CACHE_FORMAL_TOP + " -flatten; async2sync; opt; check -assert; " +
                      "write_json " + yosys_quote(netlist) + "; " + sat + " -prove-asserts -verify")
            _, text = run([*frontend, "-p", script], "formal-cache-control-72", timeout=180)
            if "SAT proof finished - no model found: SUCCESS!" not in text:
                raise RuntimeError("bounded cache proof lacks explicit success marker")
            design = json.loads(netlist.read_text(encoding="utf-8"))
            assertions = sum(cell["type"] == "$assert" or
                             (cell["type"] == "$check" and cell["parameters"].get("FLAVOR") == "assert")
                             for cell in design["modules"][CACHE_FORMAL_TOP].get("cells", {}).values())
            if assertions < 5:
                raise RuntimeError("bounded cache proof retained fewer than five assertions")
            script = ("read_json " + yosys_quote(netlist) + "; " + sat +
                      " -prove cache_hit_o 0 -falsify -show-inputs -show-outputs -dump_vcd " +
                      yosys_quote(out / "reachable-cache-hit-72.vcd"))
            _, text = run([*frontend, "-p", script], "reachable-cache-hit-72", timeout=180)
            if "SAT proof finished - model found: FAIL!" not in text:
                raise RuntimeError("no reachable cache-hit witness within 72 cycles")
            report["cache_formal"] = {
                "status": "PASS", "cycles": 72, "assertions": assertions, "result": "CACHE_HIT_REACHABLE",
                "scope": "INT4 16x16 fixture, arbitrary K=17/18, start/enable/flush/cancel/reset/testmode; "
                         "bounded cache control and hit reachability only; "
                         "not induction, numerical datapath, arbitrary full-key or steering integration proof",
                "initial_state": "set-init-zero, initial sampled reset assumed low; async2sync clock-step model",
            }
            print("CACHE_FORMAL PASS " + json.dumps(report["cache_formal"]), flush=True)
        else:
            print("FORMAL NOT_RUN explicitly disabled; no formal claim", flush=True)
        report["status"] = "PASS"
    except Exception as error:
        report.update(status="FAIL", error=str(error))
        if report["formal"]["status"] == "RUNNING":
            report["formal"].update(status="FAIL", claim="none")
        if report.get("cache_formal", {}).get("status") == "RUNNING":
            report["cache_formal"].update(status="FAIL", claim="none")
        raise
    finally:
        (out / "results.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print("RESULTS " + str(out / "results.json"), flush=True)
    return 0


def main():
    args = arguments()
    if args.replay_selftest:
        replay_selftest()
        return 0
    if args.replay or os.environ.get("AI_POLICY_SUBCODE_REPLAY"):
        replay_selftest()
    feedback_selftest()
    if args.synth_only:
        return local_synthesis(args)
    if os.environ.get("TH_DATA_DIR"):
        if args.dry_run:
            raise RuntimeError("--dry-run is local proxy-dispatch only")
        return remote(args)
    return dispatch(args)


if __name__ == "__main__":
    sys.exit(main())
