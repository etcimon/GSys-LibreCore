#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon

import argparse
import copy
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import time
import uuid

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
FORMATS = {0: "INT8", 1: "INT4", 3: "FP8_E4M3", 4: "FP8_E5M2",
           5: "FP16", 6: "BF16", 7: "FP32"}
LIVE_SOURCES = (
    "corev_apu/include/g6lc_ai_island_cfg_pkg.sv",
    "corev_apu/ai_island/include/g6lc_ai_desc_pkg.sv",
    "core/cvxif_g6lc_ai/include/g6lc_ai_instr_pkg.sv",
    "corev_apu/ai_island/g6lc_ai_cap_window.sv",
)


def require(ok, message):
    if not ok:
        raise ValueError(message)


def save(path, value):
    path.write_text(json.dumps(value, indent=2, allow_nan=False) + "\n", encoding="utf-8")


def digest(path):
    with path.open("rb") as stream:
        hasher = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(block)
        return hasher.hexdigest()


def dependencies():
    sys.path.insert(0, str(ROOT / "ai-tensor/python"))
    from ai_tensor import c_abi
    from ai_tensor.numfmt import gemm_native, pack_bits
    spec = importlib.util.spec_from_file_location("g6lc_policy_runner", ROOT / "verif/regress/ai-policy-codec.py")
    policy = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(policy)
    return c_abi, gemm_native, pack_bits, policy


def make_jobs(pack_bits):
    jobs, samples = [], {}
    anchors = {3: (0x80, 0x38, 0x30, 0x40, 0x7f, None),
               4: (0x80, 0x3c, 0x38, 0x40, 0x7d, 0x7c),
               5: (0x8000, 0x3c00, 0x3800, 0x4000, 0x7d01, 0x7c00),
               6: (0x8000, 0x3f80, 0x3f00, 0x4000, 0x7f81, 0x7f80),
               7: (0x80000000, 0x3f800000, 0x3f000000, 0x40000000, 0x7f800001, 0x7f800000)}

    def add(name, fmt, a, b, lda=None, ldb=None, opcode=0):
        m, n, k = len(a), len(b), len(a[0])
        require(all(len(row) == k for row in a + b), "generator shape mismatch")
        lda, ldb = lda or k, ldb or k
        sentinel = 0xD if fmt == 1 else 0x5A
        aa = [row + [sentinel] * (lda - k) for row in a]
        bb = [row + [sentinel] * (ldb - k) for row in b]
        jobs.append({"id": name, "m": m, "n": n, "k": k, "numfmt": fmt,
                     "lda": lda, "ldb": ldb, "opcode_class": opcode,
                     "a_hex": pack_bits(aa, fmt, ld=lda).hex(),
                     "b_hex": pack_bits(bb, fmt, ld=ldb).hex()})
        flat = [value for row in a for value in row]
        samples[name] = pack_bits([flat[:8]], fmt).hex() if len(flat) >= 8 else ""

    for fmt, label in FORMATS.items():
        if fmt in (0, 1):
            pool = [0, 1, 255, 127, 128, 3, 249, 42] if fmt == 0 else [0, 1, 15, 7, 8, 3, 9, 6]
        else:
            sign, one, half, two, _, _ = anchors[fmt]
            pool = [0, sign, 1, one, one + 1, half, sign | one, two + 3]
        for shape, m, n, k, lda, ldb in (("work", 32, 24, 48, 51, 53),
                                       ("asymmetric", 3, 5, 7, 9, 11)):
            a = [[pool[(i * 5 + t * 3 + i * t) % len(pool)] for t in range(k)] for i in range(m)]
            b = [[pool[(j * 7 + t * 5 + 3 + j * t) % len(pool)] for t in range(k)] for j in range(n)]
            for opcode in range(4):
                add(label + "-" + shape + "-class" + str(opcode), fmt, a, b, lda, ldb, opcode)
        if fmt >= 3:
            sign, one, half, _, nan, inf = anchors[fmt]
            add(label + "-signed-zero", fmt, [[0, sign], [sign, 0]], [[one, one], [sign | one, one]])
            add(label + "-subnormal", fmt, [[1, 2, sign | 1, 3], [3, sign | 2, 1, 0]],
                [[one, half, one, half], [one, one, one, one]], opcode=1)
            add(label + "-canonical-nan", fmt, [[nan, one, 0, sign], [sign | nan, 1, one, 0]],
                [[one, one, one, one]], opcode=2)
            if inf is not None:
                add(label + "-infinity", fmt, [[inf], [sign | inf]], [[one], [sign | one]], opcode=3)
                add(label + "-inf-times-zero", fmt, [[inf], [sign | inf]], [[0]], opcode=3)
    add("FP32-two-rounding-not-fma", 7, [[0xbf800000, 0x3f800001]], [[0x3f800000, 0x3f7ffffe]])
    add("FP32-add-rne-tie", 7, [[0x4b800000, 0x3f800000]], [[0x3f800000, 0x3f800000]])
    add("FP32-product-rne-underflow", 7, [[1], [3]], [[0x3f000000]])
    for fmt in (2, 8):
        jobs.append({"id": "unsupported-" + str(fmt), "m": 3, "n": 5, "k": 7,
                     "numfmt": fmt, "lda": 9, "ldb": 11, "opcode_class": 0,
                     "a_hex": "", "b_hex": ""})
    return {"schema": "g6q.tensor-eval.v1", "jobs": jobs}, samples


def unpack_model(image, layout):
    require(len(image) == layout["desc_bytes"], "descriptor byte extent mismatch")
    values, occupied = {}, set()
    for name, field in layout["fields"].items():
        offset, size = field["offset"], field["size"]
        require(type(offset) is int and type(size) is int and size in (2, 4, 8) and
                offset >= 0 and offset + size <= len(image), "descriptor field geometry mismatch")
        extent = set(range(offset, offset + size))
        require(not occupied & extent, "descriptor fields overlap")
        occupied.update(extent)
        require(field["bit_low"] == 8 * offset and field["bit_high"] == 8 * (offset + size) - 1,
                "descriptor field bit/byte layout mismatch")
        values[name] = int.from_bytes(image[offset:offset + size], "little")
    require(len(occupied) == len(image), "descriptor field coverage mismatch")
    return values


def check_layout(layout, abi):
    require(layout["desc_bytes"] == abi.DESC_BYTES == 64, "Desc64 size disagreement")
    require(layout["version"] == abi.CONTRACT_VERSION, "descriptor version disagreement")
    require(layout["operand_b_k_major"] is True, "B must be explicitly K-major")
    require(layout["ops"]["OP_GEMM"] == abi.OP_GEMM, "GEMM opcode disagreement")
    require(layout["flags_layout"]["numfmt"] == {"shift": abi.FLAG_NUMFMT_SHIFT, "mask": abi.FLAG_NUMFMT_MASK},
            "NUMFMT flags layout disagreement")
    pointers = {"ptr_a": 0x123456789abcdef0, "ptr_b": 0x23456789abcdef01,
                "ptr_c": 0x3456789abcdef012, "ptr_done": 0x456789abcdef0123}
    for lda, ldb in ((None, None), (9, 11)):
        image = abi.pack_desc64(3, 5, 7, **pointers, flags=0x654321, lda=lda, ldb=ldb)
        want = dict(pointers, version=abi.CONTRACT_VERSION, op=abi.OP_GEMM, flags=0x654321,
                    m=3, n=5, k=7, ld_ab=(lda or 7) | ((ldb or 7) << 16), ptr_scale=0)
        require(unpack_model(image, layout) == want, "non-square Desc64 field/stride layout mismatch")


def check_descriptor(job, outcome, layout, abi):
    fmt = job["numfmt"]
    if fmt > layout["flags_layout"]["numfmt"]["mask"]:
        require(outcome["descriptor_hex"] == "", "unrepresentable format has a descriptor")
        return
    image = bytes.fromhex(outcome["descriptor_hex"])
    values = unpack_model(image, layout)
    require(values["version"] == layout["version"] and values["op"] == layout["ops"]["OP_GEMM"],
            "descriptor opcode/version mismatch; semantic class is not a descriptor opcode")
    for key in ("m", "n", "k"):
        require(values[key] == job[key], "descriptor geometry mismatch: " + key)
    require(values["ld_ab"] == job["lda"] | (job["ldb"] << 16), "both strides must follow K")
    flags = layout["flags_layout"]
    expected_flags = fmt << flags["numfmt"]["shift"]
    if fmt == 1:
        require(flags["ew"]["mask"] & 1, "INT4 width flag unavailable")
        expected_flags |= 1 << flags["ew"]["shift"]
    require(values["flags"] == expected_flags, "descriptor arithmetic flags mismatch")
    kwargs = {key: values[key] for key in ("ptr_a", "ptr_b", "ptr_c", "ptr_done", "flags")}
    packed = abi.pack_desc64(job["m"], job["n"], job["k"], **kwargs, lda=job["lda"], ldb=job["ldb"])
    require(packed == image, "independent Desc64 byte image mismatch")


def check_result(request, samples, result, trace, abi, gemm_native, policy, target, mask):
    require(result["schema"] == "g6q.tensor-eval-result.v1" and
            result["backend"] == "b3-descriptor-executor", "incorrect functional backend/schema")
    for key in ("qemu_guest", "rtl_cycles", "fp_exception_flags"):
        require(result[key] is False, "unsupported fidelity claim: " + key)
    require(result["source"]["target_id"] == target, "source profile mislabeled")
    model = result["model"]
    require(model["target"]["id"] == target, "model target mismatch")
    island = model["soc"]["ai_island"]
    require(island["config"]["dtype_mask"] == mask, "source grant mask changed; no override permitted")
    layout = island["desc_layout"]
    check_layout(layout, abi)
    require(len(result["jobs"]) == len(request["jobs"]) == result["job_count"], "result job count mismatch")
    successful, by_format = [], {}
    for job, outcome in zip(request["jobs"], result["jobs"]):
        require(outcome["id"] == job["id"], "result identity/order mismatch")
        for key in ("numfmt", "m", "n", "k", "lda", "ldb", "opcode_class"):
            require(type(outcome[key]) is int and outcome[key] == job[key], "result metadata mismatch: " + key)
        require(outcome["ldc"] == job["n"] and outcome["source"] == result["source"], "result stride/source mismatch")
        granted = job["numfmt"] in FORMATS and bool(mask & (1 << job["numfmt"]))
        require(outcome["executed"] is granted and outcome["rejected"] is (not granted),
                "execute/reject mismatch: " + job["id"])
        status = "ST_OK" if granted else "ST_BAD_FMT"
        require(outcome["status_name"] == status and outcome["status"] == layout["statuses"][status],
                "status not from source model: " + job["id"])
        if granted:
            expected = gemm_native(bytes.fromhex(job["a_hex"]), bytes.fromhex(job["b_hex"]),
                                   job["m"], job["n"], job["k"], job["numfmt"],
                                   lda=job["lda"], ldb=job["ldb"], dtype_mask=mask)
            require(outcome["C_hex"] == expected.hex(), "native C32 byte mismatch: " + job["id"])
            if "canonical-nan" in job["id"] or "inf-times-zero" in job["id"]:
                require(expected == bytes.fromhex("0000c07f") * (job["m"] * job["n"]), "canonical NaN anchor")
            anchors = {"FP32-two-rounding-not-fma": "00000000", "FP32-add-rne-tie": "0000804b",
                       "FP32-product-rne-underflow": "0000000002000000"}
            if job["id"] in anchors:
                require(expected.hex() == anchors[job["id"]], "independent rounding anchor failed")
            successful.append(job)
        else:
            require(outcome["C_hex"] == "", "rejected job returned C data")
        check_descriptor(job, outcome, layout, abi)
        counts = by_format.setdefault(str(job["numfmt"]), {"executed": 0, "rejected": 0})
        counts["executed" if granted else "rejected"] += 1
    require(result["executed_count"] == len(successful) and
            result["failed_count"] == len(request["jobs"]) - len(successful), "aggregate count mismatch")
    policy.validate_trace(trace)
    require(trace["source"] == result["source"], "trace source provenance mismatch")
    require(len(trace["records"]) == len(successful), "trace must contain only successful jobs")
    for job, record in zip(successful, trace["records"]):
        for key in ("id", "m", "n", "k", "numfmt", "opcode_class"):
            require(record[key] == job[key], "trace job metadata/order mismatch")
        require(record["native_sample_hex"] == samples[job["id"]] and
                record["sample_valid"] is bool(samples[job["id"]]) and record["exact_zero"] is False,
                "trace native samples include padding or invalid proof: " + job["id"])
    return {"status": "PASS", "target": target, "dtype_mask": mask, "by_numfmt": by_format,
            "jobs": len(request["jobs"]), "executed": len(successful),
            "rejected": result["failed_count"], "trace_records": len(trace["records"]),
            "descriptor_bytes_exact": True, "C32_bytes_exact": True,
            "source": result["source"], "qemu_guest": False, "rtl_cycles": False}


def negative_checks(trace, layout, policy, abi):
    passed = []
    def rejects(name, function):
        try:
            function()
        except (ValueError, KeyError, TypeError):
            passed.append(name)
        else:
            raise ValueError("negative check accepted " + name)
    for key, value, name in (("exact_zero", True, "external-zero-proof"), ("m", 257, "oversize-shape"),
                             ("m", 3.0, "float-shape"), ("m", True, "boolean-shape"),
                             ("numfmt", 2, "SP24"), ("numfmt", 8, "reserved-format"),
                             ("opcode_class", 4, "nonsemantic-opcode"),
                             ("native_sample_hex", "00", "truncated-sample"),
                             ("native_sample_hex", "zz", "nonhex-sample"),
                             ("sample_valid", 1, "nonboolean-valid"), ("unknown", 0, "unknown-field")):
        bad = copy.deepcopy(trace)
        bad["records"][0][key] = value
        rejects(name, lambda bad=bad: policy.validate_trace(bad))
    for name, text in (("malformed-json", "{"), ("duplicate-json", '{"x":1,"x":2}'),
                       ("nonfinite-json", '{"x":NaN}')):
        rejects(name, lambda text=text: policy.closed_json(text))
    bad = copy.deepcopy(layout)
    bad["fields"]["n"], bad["fields"]["k"] = bad["fields"]["k"], bad["fields"]["n"]
    rejects("non-square-field-layout", lambda: check_layout(bad, abi))
    bad_version = dict(layout, version=abi.CONTRACT_VERSION - 1)
    rejects("version-layout", lambda: check_layout(bad_version, abi))
    bad_b = dict(layout, operand_b_k_major=False)
    rejects("B-layout", lambda: check_layout(bad_b, abi))
    return passed


def run(command, log, env):
    command = [str(value) for value in command]
    print("RUN " + shlex.join(command), flush=True)
    with log.open("w", encoding="utf-8") as stream:
        stream.write("COMMAND " + shlex.join(command) + "\n")
        stream.flush()
        result = subprocess.run(command, cwd=ROOT, env=env, stdout=stream,
                                stderr=subprocess.STDOUT, check=False)
        stream.write("\nRETURN_CODE " + str(result.returncode) + "\n")
    require(result.returncode == 0, "command failed; see " + str(log))


def collect_replay(log, destination, policy, target, count):
    pulls = [line.removeprefix("PULL_OUTPUT ") for line in log.read_text(encoding="utf-8").splitlines()
             if line.startswith("PULL_OUTPUT ")]
    require(len(pulls) == 1, "missing/ambiguous proxy output directory")
    pulled = Path(pulls[0]).resolve()
    require(pulled.is_dir() and pulled.is_relative_to((ROOT / "remote-runs").resolve()),
            "proxy output must be contained in remote-runs")
    require(not any(path.is_symlink() for path in pulled.rglob("*")), "proxy output contains symlinks")
    shutil.copytree(pulled, destination)
    summaries = list(destination.glob("policy-results-*/results.json"))
    require(len(summaries) == 1, "missing/ambiguous remote policy report")
    report = policy.closed_json(summaries[0].read_text(encoding="utf-8"))
    require(report["status"] == "PASS" and report["lint"] == "PASS" and report["simulation"] == "PASS",
            "remote policy report did not pass")
    profiles = {}
    for name, steering in report["steering"].items():
        require(steering["status"] == "PASS", "remote steering profile failed: " + name)
        metrics = policy.closed_json((summaries[0].parent / ("steering-" + name) / "efficiency.json").read_text(encoding="utf-8"))
        records = [record for record in metrics["records"] if record["type"] == "EXTERNAL_POLICY_REPLAY"]
        totals = [record for record in records if record.get("format") == "ALL"]
        require(len(totals) == 1 and totals[0]["records"] == count, "replay record count mismatch")
        for record in records:
            require(record["source_target"] == target and record["resource_profile"] == "future-array-hypothesis" and
                    record["trace_functional_backend"] == "b3-descriptor-executor" and
                    record["scheduling_model_not_actual_fp_array"] == 1 and record["qemu_guest"] == 0 and
                    record["rtl_cycles"] == 0 and record["scalar_pipe3_rates_match_array_hypothesis"] == 0,
                    "replay fidelity/source label mismatch")
        profiles[name] = records
    require({"sram128", "sram512"} <= set(profiles), "missing default SRAM replay profiles")
    return {"status": "PASS", "log": str(log), "artifacts": str(destination),
            "resource_profile": "future-array-hypothesis", "profiles": profiles}


def main():
    parser = argparse.ArgumentParser(description="GSys LibreCore native tensor cross-check; host B3 software, not guest or RTL cycles")
    parser.add_argument("--binary", type=Path, help="existing g6lc-qemu binary; never installs/builds tools")
    parser.add_argument("--replay-policy", action="store_true", help="also replay both successful traces through remote RTL policy wrapper")
    parser.add_argument("--policy-parameters", choices=("default", "extremes"), default="default")
    parser.add_argument("--policy-synth", choices=("auto", "off", "required"), default="off")
    args = parser.parse_args()
    binary = (args.binary or ROOT / ("g6lc_qemu/target/debug/g6lc-qemu" + (".exe" if os.name == "nt" else ""))).resolve()
    require(binary.is_file() and os.access(binary, os.X_OK), "existing executable required: " + str(binary))
    parent = ROOT / "build-platform/workspace/build"
    require(parent.is_dir() and parent.resolve() == parent, "build parent must exist without symlink redirection")
    tag = "ai-native-eval-" + datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:12]
    out = parent / tag
    out.mkdir()
    print("AI_NATIVE_OUTPUT " + str(out), flush=True)
    report = {"status": "RUNNING", "backend": "b3-descriptor-executor", "qemu_guest": False,
              "rtl_cycles": False, "fp_exception_flags": False, "output": str(out),
              "replay_resource_profile": "future-array-hypothesis; not actual scalar FP pipe3 1 MAC/10 cycles",
              "profiles": {}}
    start = time.monotonic()
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    env["PYTHONPATH"] = str(ROOT / "ai-tensor/python") + os.pathsep + env.get("PYTHONPATH", "")
    inputs = [Path(__file__).resolve(), Path(__file__).with_suffix(".sh"), binary,
              ROOT / "verif/regress/ai-policy-codec.py", ROOT / "verif/tb/ai_island/policy_efficiency.cpp",
              ROOT / "g6lc_qemu/tools/ai_tensor_bridge.py", ROOT / "ai-tensor/python/ai_tensor/c_abi.py",
              ROOT / "ai-tensor/python/ai_tensor/numfmt.py"]
    try:
        abi, gemm_native, pack_bits, policy = dependencies()
        request, samples = make_jobs(pack_bits)
        request_path = out / "requests.json"
        save(request_path, request)
        manifest = out / "live-discovery-not-compiled.f"
        live_paths = [ROOT / source for source in LIVE_SOURCES]
        fixture = ROOT / "g6lc_qemu/fixtures/ai"
        inputs.extend(live_paths)
        profiles = (("live-source-contract", "g6lc64_ai", 3,
                     ROOT / "core/include/g6lc64_ai_config_pkg.sv", manifest,
                     ROOT / "corev_apu/bootrom/ariane-ai.dts"),
                    ("software-fixture-not-live-silicon", "tensor-software-exploration", 0xfb,
                     fixture / "ai_soc_config_pkg.sv", fixture / "eval-manifest.f", fixture / "board.dts"))
        inputs.extend(fixture / name for name in ("eval_g6lc_ai_island_cfg_pkg.sv", "eval_g6lc_ai_desc_pkg.sv", "g6lc_ai_instr_pkg.sv"))
        for _, _, _, config, flist, dts in profiles:
            inputs.extend((config, dts))
            if flist != manifest:
                inputs.append(flist)
        for path in inputs:
            require(path.is_file(), "required input missing: " + str(path))
        manifest.write_text("// SPDX-License-Identifier: MIT\n// Copyright (c) 2026 Etienne Cimon\n" +
                            "\n".join(path.as_posix() for path in live_paths) + "\n", encoding="utf-8")
        inputs.append(manifest)
        report["input_sha256"] = {str(path): digest(path) for path in inputs}
        for name, target, mask, config, flist, dts in profiles:
            result_path, trace_path = out / (name + "-result.json"), out / (name + "-trace.json")
            command = [sys.executable, "-B", ROOT / "g6lc_qemu/tools/ai_tensor_bridge.py", "evaluate",
                       "--binary", binary, "--request", request_path, "--result", result_path,
                       "--policy-trace-out", trace_path, "--target", target,
                       "--config", config, "--flist", flist, "--dts", dts]
            run(command, out / (name + "-evaluate.log"), env)
            result = policy.closed_json(result_path.read_text(encoding="utf-8"))
            trace = policy.load_trace(trace_path)
            report["profiles"][name] = check_result(request, samples, result, trace, abi, gemm_native,
                                                    policy, target, mask)
            report["profiles"][name]["negative_checks"] = negative_checks(trace, result["model"]["soc"]["ai_island"]["desc_layout"], policy, abi)
            print("NATIVE_PROFILE PASS " + name + " " + json.dumps(report["profiles"][name]["by_numfmt"]), flush=True)
            if args.replay_policy:
                log = out / (name + "-policy.log")
                run([sys.executable, "-B", ROOT / "verif/regress/ai-policy-codec.py", "--trace", trace_path,
                     "--parameters", args.policy_parameters, "--synth", args.policy_synth], log, env)
                report["profiles"][name]["policy_replay"] = collect_replay(
                    log, out / (name + "-policy-output"), policy, target, len(trace["records"]))
        require(all(digest(path) == report["input_sha256"][str(path)] for path in inputs), "inputs changed during evaluation")
        report["status"] = "PASS"
    except Exception as error:
        report["status"] = "FAIL"
        report["error"] = str(error)
        print("AI_NATIVE_EVAL FAIL " + str(error), file=sys.stderr)
    finally:
        report["elapsed_seconds"] = time.monotonic() - start
        report["artifact_sha256"] = {path.relative_to(out).as_posix(): digest(path)
                                     for path in out.rglob("*") if path.is_file()}
        save(out / "summary.json", report)
        print("SUMMARY " + str(out / "summary.json"), flush=True)
    print("AI_NATIVE_EVAL " + report["status"], flush=True)
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
