"""SPDX-FileCopyrightText: 2026 Etienne Cimon
SPDX-License-Identifier: MIT

Host consumer for the tb_g6lc_ai_gemm_backend `+measure` sweep.

The sweep is the project's only RTL-*measured* evidence for the one policy knob
that has a live hardware consumer: `prefetch_depth`, which GEMM consumes as
`g6lc_ai_gemm_seq.ar_max_i` (the outstanding-AR cap).  Everything here is
therefore deliberately narrow: it reads RTL counters out of a simulation log,
compares AR depths with exact rational arithmetic, and refuses to turn
simulated cycles into a throughput claim.
"""

import argparse
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import re

import policy_calibration as calibration


SCHEMA = "g6lc.policy-measure.v1"
CYCLE_SOURCE = "free_running_rtl_counter"
FORMAT_NAMES = calibration.FORMAT_NAMES
CONSUMER = "g6lc_ai_gemm_seq.ar_max_i (policy prefetch_depth)"
MAX_AR = 8
MAX_LOG_BYTES = 8 * 1024 * 1024
DEFAULT_REFERENCE_AR = 1
# Default gate: 1% of the reference MAC/cycle.  On a 64-MAC fixture whose
# completion time is a few hundred cycles, one cycle of quantisation is already
# a few tenths of a percent, so anything under a percent is noise dressed up as
# a result.  Compared exactly and inclusively (delta >= threshold passes).
DEFAULT_MIN_IMPROVEMENT = Fraction(1, 100)
ENVIRONMENT = {"simulator": "verilator",
               "note": "RTL simulation cycles for one TB memory model; not silicon"}
CLOCK = {"silicon_measured": False, "wall_clock_measured": False}
LIMITATIONS = (
    "Cycles are Verilator RTL simulation cycles for one testbench memory model: not silicon, not wall clock, not QEMU.",
    "One fixed 2x2x16 job per numeric format; an AR/prefetch-depth result on that shape does not generalise to large tiles.",
    "The memory side is the same testbench DRAM slave for every depth; a real DDR controller has different latency and queueing.",
    "Jobs run back to back against a stateful memory model, so one (format, depth) observation carries refresh/page-state noise; only the worst case across repeated observations is treated as evidence.",
    "No frequency is measured anywhere; a MAC/s figure exists only as a projection at a clock the caller declares.",
    "The measured knob is the sequencer AR cap only. This artifact enables no production gate and recommends no RTL default change by itself.",
)

BEGIN_RE = re.compile(r"^MEASURE_BEGIN schema=(\S+) tb=(\S+) cycle_source=(\S+) "
                      r"class=(\d+) nch=(\d+) dpf=(\d+) ar_max=(\d+)(?: pass=(\d+))?$")
RUN_RE = re.compile(r"^MEASURE fmt=(\d+) ar=(\d+) m=(\d+) n=(\d+) k=(\d+) macs=(\d+) cycles=(\d+) "
                    r"pmu_cycles=(\d+) r_beats=(\d+) w_beats=(\d+) c0=([0-9a-fA-F]{1,16}) c1=([0-9a-fA-F]{1,16})$")
END_RE = re.compile(r"^MEASURE_END runs=(\d+) formats=(\d+) ar_max=(\d+)$")


def require(condition, message):
    if not condition:
        raise ValueError("policy measure: " + message)


def scaled(value, scale=1000):
    """Round an exact Fraction to `scale`ths, half away from zero. No floats."""
    numerator, denominator = value.numerator * scale, value.denominator
    sign = -1 if numerator < 0 else 1
    return sign * ((2 * abs(numerator) + denominator) // (2 * denominator))


def percent(value):
    """Exact fraction rendered as a signed percentage to 1/1000 of a percent."""
    milli = scaled(value * 100)
    return "%s%d.%03d%%" % ("-" if milli < 0 else "+", abs(milli) // 1000, abs(milli) % 1000)


def digest(c0, c1):
    return hashlib.sha256((c0.lower() + ":" + c1.lower()).encode("ascii")).hexdigest()


def parse_log(text):
    """Split a TB log into sweep blocks + records. Every MEASURE* line is strict."""
    require(isinstance(text, str), "log must be text")
    blocks, records, open_block = [], [], None
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line.startswith("MEASURE"):
            continue
        where = " at log line " + str(number)
        begin, run, end = BEGIN_RE.match(line), RUN_RE.match(line), END_RE.match(line)
        require(begin or run or end, "unrecognised MEASURE line" + where)
        if begin:
            require(open_block is None, "MEASURE_BEGIN inside an open sweep block" + where)
            schema, tb, source = begin.group(1), begin.group(2), begin.group(3)
            require(schema == SCHEMA, "expected schema " + SCHEMA + ", got " + schema + where)
            require(source == CYCLE_SOURCE,
                    "cycles must come from the RTL free-running counter, not " + source + where)
            # `pass=` is the repeat index of an otherwise identical sweep. Each
            # pass is its own block, so a repeated (format, depth) pair never
            # collides, and the spread between passes is the noise floor.
            open_block = {"index": len(blocks), "tb": tb, "dram_class": int(begin.group(4)),
                          "channels": int(begin.group(5)), "dot_pipe_float": begin.group(6) != "0",
                          "ar_max": int(begin.group(7)),
                          "repeat": int(begin.group(8)) if begin.group(8) else 0, "runs": 0}
            require(1 <= open_block["ar_max"] <= MAX_AR, "block ar_max must be in [1,8]" + where)
            blocks.append(open_block)
        elif run:
            require(open_block is not None, "MEASURE record outside a sweep block" + where)
            fields = [int(run.group(index)) for index in range(1, 11)]
            record = dict(zip(("numfmt", "ar_max", "m", "n", "k", "useful_macs", "cycles",
                               "pmu_cycles", "r_beats", "w_beats"), fields))
            record["block"] = open_block["index"]
            record["numfmt_name"] = FORMAT_NAMES.get(record["numfmt"], "?")
            record["result_digest"] = digest(run.group(11), run.group(12))
            validate_record(record, open_block, where)
            open_block["runs"] += 1
            records.append(record)
        else:
            require(open_block is not None, "MEASURE_END without MEASURE_BEGIN" + where)
            require(int(end.group(3)) == open_block["ar_max"], "MEASURE_END ar_max disagrees with MEASURE_BEGIN" + where)
            require(int(end.group(1)) == open_block["runs"],
                    "MEASURE_END runs=" + end.group(1) + " but " + str(open_block["runs"]) + " records were emitted" + where)
            open_block = None
    require(open_block is None, "unterminated sweep block: no MEASURE_END")
    require(blocks and records, "no sweep block with records found; missing MEASURE_BEGIN/MEASURE schema")
    require(len({block["tb"] for block in blocks}) == 1, "one artifact covers one testbench only")
    validate_coverage(blocks, records)
    return blocks, records


def validate_record(record, block, where):
    require(record["numfmt"] in FORMAT_NAMES, "unknown numeric format " + str(record["numfmt"]) + where)
    require(1 <= record["ar_max"] <= block["ar_max"], "ar_max outside the block's [1,ar_max]" + where)
    for key in ("m", "n", "k"):
        require(record[key] >= 1, key + " must be positive" + where)
    require(record["useful_macs"] > 0, "zero useful MACs is not a measurement" + where)
    require(record["useful_macs"] == record["m"] * record["n"] * record["k"],
            "useful_macs must be exactly m*n*k" + where)
    for key in ("cycles", "pmu_cycles"):
        require(record[key] > 0, "nonpositive " + key + " cannot be an RTL completion time" + where)
    require(record["r_beats"] > 0, "a GEMM job that read nothing did not run" + where)
    require(record["w_beats"] > 0, "a GEMM job that wrote no C did not run" + where)


def validate_coverage(blocks, records):
    seen, geometry, digests = set(), {}, {}
    for record in records:
        key = (record["block"], record["numfmt"], record["ar_max"])
        require(key not in seen, "duplicate (numfmt, ar_max) pair in one sweep block: " + str(key))
        seen.add(key)
        shape = (record["m"], record["n"], record["k"], record["useful_macs"])
        require(geometry.setdefault(record["numfmt"], shape) == shape,
                "numfmt " + str(record["numfmt"]) + " was measured on two different shapes")
        # AR depth is a memory-side prefetch cap: it must never change arithmetic.
        require(digests.setdefault(record["numfmt"], record["result_digest"]) == record["result_digest"],
                "result digest differs across ar_max for numfmt " + str(record["numfmt"]) +
                "; AR depth changed the arithmetic")
    for block in blocks:
        legal = set(range(1, block["ar_max"] + 1))
        formats = {record["numfmt"] for record in records if record["block"] == block["index"]}
        require(formats, "sweep block " + str(block["index"]) + " has no records")
        for fmt in sorted(formats):
            observed = {record["ar_max"] for record in records
                        if record["block"] == block["index"] and record["numfmt"] == fmt}
            require(observed == legal, "numfmt " + str(fmt) + " in block " + str(block["index"]) +
                    " is missing ar values " + str(sorted(legal - observed)))


def rates(records):
    return {(record["block"], record["numfmt"], record["ar_max"]):
            Fraction(record["useful_macs"], record["cycles"]) for record in records}


def paired_deltas(records, reference_ar):
    """Exact paired delta of every (block, numfmt, ar) against the reference ar."""
    require(type(reference_ar) is int and 1 <= reference_ar <= MAX_AR, "reference ar must be in [1,8]")
    rate = rates(records)
    result = {}
    for key, value in rate.items():
        block, fmt, _ = key
        base = rate.get((block, fmt, reference_ar))
        require(base is not None, "reference ar=" + str(reference_ar) +
                " is absent for numfmt " + str(fmt) + " in block " + str(block))
        result[key] = (value, (value - base) / base)
    return result


def per_format(records, reference_ar):
    """Per format: every depth's delta observed once per sweep block (repeats)."""
    table = paired_deltas(records, reference_ar)
    result = {}
    for fmt in sorted({key[1] for key in table}):
        blocks = sorted({key[0] for key in table if key[1] == fmt})
        depths = {}
        for ar in sorted({key[2] for key in table if key[1] == fmt}):
            observed = [table[(block, fmt, ar)] for block in blocks if (block, fmt, ar) in table]
            require(len(observed) == len(blocks),
                    "numfmt " + str(fmt) + " ar=" + str(ar) + " is not observed in every sweep block")
            depths[ar] = observed
        result[fmt] = {"blocks": blocks, "depths": depths}
    return result


def best_depth(depths, reference_ar):
    """Largest worst-case delta wins; ties go to the shallowest depth. No gain -> reference."""
    ranked = sorted(((min(delta for _, delta in observed), -ar) for ar, observed in depths.items()),
                    reverse=True)
    return -ranked[0][1] if ranked[0][0] > 0 else reference_ar


def recommend(table, reference_ar, min_improvement):
    require(isinstance(min_improvement, Fraction) and min_improvement > 0,
            "minimum improvement must be a positive Fraction")
    formats, changed = {}, False
    for fmt, entry in sorted(table.items()):
        depths, blocks = entry["depths"], entry["blocks"]
        worst = {ar: min(delta for _, delta in observed) for ar, observed in depths.items()}
        # Consistency, not best-of: the winner must clear the gate in EVERY
        # repeated observation, so one lucky block cannot carry a depth.
        eligible = sorted((value, -ar) for ar, value in worst.items()
                          if ar != reference_ar and value >= min_improvement)
        winner = -eligible[-1][1] if eligible else None
        best = best_depth(depths, reference_ar)
        if winner is None:
            reason = ("no depth clears " + percent(min_improvement) + " in all " + str(len(blocks)) +
                      " observation(s); best worst-case delta is " +
                      percent(max(worst.values())) + " at ar=" + str(best))
        else:
            reason = ("ar=" + str(winner) + " beats ar=" + str(reference_ar) + " by at least " +
                      percent(worst[winner]) + " in all " + str(len(blocks)) + " observation(s)")
            changed = True
        formats[FORMAT_NAMES[fmt]] = {
            "numfmt": fmt, "observations": len(blocks), "best_ar": best,
            "recommended_ar": winner, "prefetch_depth": winner,
            "minimum_delta_percent": {str(ar): percent(value) for ar, value in sorted(worst.items())},
            "minimum_delta_percent_milli": {str(ar): scaled(value * 100) for ar, value in sorted(worst.items())},
            "reason": reason,
        }
    return {"consumer": CONSUMER, "reference_ar": reference_ar,
            "min_improvement": str(min_improvement),
            "min_improvement_percent": percent(min_improvement),
            "boundary": "inclusive: delta >= min_improvement passes",
            "recommended_change": changed,
            "meaning": "recommended_change=true means the recommended prefetch depth differs from the "
                       "measured reference depth. It is not a claim that an RTL default must change, and "
                       "it enables no production gate.",
            "per_format": formats}


def throughput(records, reference_ar):
    table = paired_deltas(records, reference_ar)
    rows = []
    for record in sorted(records, key=lambda r: (r["block"], r["numfmt"], r["ar_max"])):
        rate, delta = table[(record["block"], record["numfmt"], record["ar_max"])]
        rows.append({"block": record["block"], "numfmt": record["numfmt"],
                     "numfmt_name": record["numfmt_name"], "ar_max": record["ar_max"],
                     "cycles": record["cycles"], "mac_per_cycle": str(rate),
                     "mac_per_cycle_milli": scaled(rate),
                     "delta_vs_reference_percent": percent(delta),
                     "delta_vs_reference_percent_milli": scaled(delta * 100)})
    return {"unit": "useful_mac_per_simulated_cycle", "reference_ar": reference_ar,
            "measured": True, "per_record": rows}


def mac_per_second(records, frequency_hz):
    """Only ever a projection, and only when a clock is explicitly declared."""
    require(frequency_hz is not None,
            "MAC/s refused: simulated cycles carry no time. Declare a clock with --frequency-hz "
            "and the result is labelled a projection, never a measurement")
    require(type(frequency_hz) is int and frequency_hz > 0, "declared clock must be a positive integer in Hz")
    rate = rates(records)
    rows = [{"block": block, "numfmt": fmt, "numfmt_name": FORMAT_NAMES[fmt], "ar_max": ar,
             "mac_per_second": str(value * frequency_hz),
             "mac_per_second_milli": scaled(value * frequency_hz)}
            for (block, fmt, ar), value in sorted(rate.items())]
    return {"kind": "projection_from_simulated_cycles_at_declared_clock",
            "declared_clock_hz": frequency_hz, "silicon_measured": False, "wall_clock_measured": False,
            "note": "projection: RTL simulation cycles scaled by a clock the caller declared; "
                    "not a silicon, wall-clock, QEMU or production throughput measurement",
            "per_record": rows}


def build(raw, verilator_version, reference_ar=DEFAULT_REFERENCE_AR,
          min_improvement=DEFAULT_MIN_IMPROVEMENT, frequency_hz=None):
    require(type(raw) is bytes and 0 < len(raw) <= MAX_LOG_BYTES, "log must be non-empty bytes under 8 MiB")
    version = calibration.text(verilator_version, "verilator_version")
    require(re.fullmatch(r"[0-9]+\.[0-9]+(\.[0-9]+)?", version) is not None,
            "verilator_version must be a plain version such as 5.008")
    blocks, records = parse_log(raw.decode("utf-8", errors="strict"))
    table = per_format(records, reference_ar)
    result = {
        "schema": SCHEMA,
        "harness": {"tb": blocks[0]["tb"], "verilator_version": version,
                    "log_sha256": hashlib.sha256(raw).hexdigest()},
        "environment": dict(ENVIRONMENT),
        "clock": dict(CLOCK),
        "blocks": blocks,
        "records": records,
        "throughput": throughput(records, reference_ar),
        "equivalence": {"checked": all(len(entry["depths"]) > 1 for entry in table.values()),
                        "digests_matched": True, "reference_ar": reference_ar,
                        "note": "an artifact is only produced when every ar_max in a format yields the same C"},
        "recommendation": recommend(table, reference_ar, min_improvement),
        "limitations": list(LIMITATIONS),
    }
    if frequency_hz is not None:
        result["mac_per_second_projection"] = mac_per_second(records, frequency_hz)
    result["tool_sha256"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    return result


def repo_root():
    return Path(__file__).resolve().parents[3]


def protect_outputs(out, logs):
    """Never write over a source file, and never write into a source tree."""
    calibration.protect_outputs([out], list(logs) + [Path(__file__)])
    require(out.suffix == ".json", "the artifact must be written as a .json file")
    try:
        relative = out.resolve().relative_to(repo_root())
    except ValueError:
        return out
    require(relative.parts[:3] == ("build-platform", "workspace", "build"),
            "in-repo artifacts belong under build-platform/workspace/build/, not in a source tree")
    return out


def summary(result):
    harness, recommendation = result["harness"], result["recommendation"]
    lines = [SCHEMA + ": " + harness["tb"] + " verilator " + harness["verilator_version"] +
             " log=" + harness["log_sha256"][:12] +
             " blocks=" + str(len(result["blocks"])) + " runs=" + str(len(result["records"])),
             "environment: " + result["environment"]["note"] +
             " (silicon_measured=false, wall_clock_measured=false)",
             "equivalence: C identical across every ar_max (reference ar=" +
             str(result["equivalence"]["reference_ar"]) + "): " +
             ("yes" if result["equivalence"]["digests_matched"] else "no")]
    for row in result["throughput"]["per_record"]:
        lines.append("  block=%d %-8s ar=%d cycles=%-5d %-8s MAC/cyc (%d/1000) delta=%s"
                     % (row["block"], row["numfmt_name"], row["ar_max"], row["cycles"],
                        row["mac_per_cycle"], row["mac_per_cycle_milli"],
                        row["delta_vs_reference_percent"]))
    for name, entry in sorted(recommendation["per_format"].items()):
        lines.append("  " + name + ": best_ar=" + str(entry["best_ar"]) +
                     " recommended_ar=" + str(entry["recommended_ar"]) + " -- " + entry["reason"])
    projection = result.get("mac_per_second_projection")
    lines.append("mac_per_second: " + ("projection at " + str(projection["declared_clock_hz"]) +
                 " Hz (declared, not measured)" if projection else
                 "not emitted (no declared clock; simulated cycles are not a rate)"))
    lines.append("recommended_change=" + ("true" if recommendation["recommended_change"] else "false") +
                 ": " + ("a depth other than the reference clears the threshold in every observation "
                         "(this is a tuning input, not an RTL default change and not a gate)"
                         if recommendation["recommended_change"] else
                         "no AR depth beats the reference consistently enough on these fixed small workloads"))
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Measured GEMM AR-depth (policy prefetch_depth) evidence from a tb_g6lc_ai_gemm_backend +measure log")
    parser.add_argument("--log", required=True, type=Path, help="TB stdout capture containing MEASURE_BEGIN/MEASURE/MEASURE_END")
    parser.add_argument("--verilator-version", required=True, help="the simulator that produced the log, e.g. 5.008")
    parser.add_argument("--out", type=Path,
                        default=repo_root() / "build-platform/workspace/build/policy-measure.json")
    parser.add_argument("--reference-ar", type=int, default=DEFAULT_REFERENCE_AR)
    parser.add_argument("--min-improvement", default=str(DEFAULT_MIN_IMPROVEMENT),
                        help="minimum MAC/cycle improvement as an exact fraction, inclusive (default 1/100)")
    parser.add_argument("--frequency-hz", type=int, default=None,
                        help="declare a clock to also emit a labelled MAC/s projection; omitted by default")
    args = parser.parse_args(argv)
    try:
        threshold = Fraction(args.min_improvement)
        args.out.parent.mkdir(parents=True, exist_ok=True)
        protect_outputs(args.out, [args.log])
        raw = args.log.read_bytes()
        result = build(raw, args.verilator_version, args.reference_ar, threshold, args.frequency_hz)
        args.out.write_text(json.dumps(result, indent=2, sort_keys=True, allow_nan=False) + "\n",
                            encoding="utf-8")
        print(summary(result))
        print("artifact: " + str(args.out))
    except (ValueError, ZeroDivisionError, OSError, UnicodeError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
