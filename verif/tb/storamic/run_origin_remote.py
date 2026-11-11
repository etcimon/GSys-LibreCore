# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""origin-profile / origin-queue: remote component-bench qualification.

Promoted from the local provenance checks in run_origin.py. run_origin.py is a
local-only tool (it shells out to a PATH verilator and writes result.json); this
runner reuses its exact per-profile source lists, markers and oracle-negative
cases but builds through the shared build_model() so the owned remote runtime,
compiler identity and manifest hashing apply.

Both benches are self-contained component checks (no full CPU, no program ROM):

- origin-profile: tb_g6lc_storamic_origin_profile exercises
  g6lc_storamic_origin_supported / g6lc_storamic_data_prot across scalar config
  mutations. Positives ORIGIN_PROFILE_PASS; +oracle_negative must reject with
  "negative-shared-writer"; +oracle_debug must reject with
  "negative-debug-authority".
- origin-queue: tb_g6lc_storamic_origin_queue drives the real lsu_bypass /
  store_unit store path and checks data_prot tagging. Positive
  ORIGIN_QUEUE_PASS; +oracle_negative must reject with "negative-oracle".

Sources are uploaded flat by basename into data/; every input below is a flat
basename already present in data/ (the two bench files and
g6lc64_ooo_config_pkg.sv are added by run_remote.py for these stages).
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess


def _sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


WNO = ["-Wno-TIMESCALEMOD", "-Wno-UNUSED", "-Wno-WIDTHTRUNC", "-Wno-WIDTHEXPAND",
       "-Wno-PINCONNECTEMPTY", "-Wno-CASEINCOMPLETE", "-Wno-UNOPTFLAT",
       "-Wno-DECLFILENAME", "-Wno-MODDUP", "-Wno-LITENDIAN", "-Wno-EOFNEWLINE"]

PROFILE_INPUTS = ["config_pkg.sv", "tb_g6lc_storamic_origin_profile.sv"]
# g6lc_core_types.svh is pulled in by the bench's `include (resolved from
# data/ via the bench's own directory); it is uploaded but not a top input.
QUEUE_INPUTS = [
    "config_pkg.sv", "g6lc64_ooo_config_pkg.sv", "riscv_pkg.sv",
    "ariane_pkg.sv", "g6lc_ooo_pkg.sv", "lsu_bypass.sv", "store_buffer.sv",
    "cva6_fifo_v3.sv", "amo_buffer.sv", "store_unit.sv",
    "tb_g6lc_storamic_origin_queue.sv",
]


def run(data, out, stages, manifest, builds, outcomes, verilator, build_model):
    want_profile = "origin-profile" in stages
    want_queue = "origin-queue" in stages
    if not (want_profile or want_queue):
        return
    env = dict(os.environ)
    for key in ("MAKEFLAGS", "MFLAGS", "CXX", "CC", "CXXFLAGS", "CFLAGS",
                "CPPFLAGS", "LDFLAGS", "OBJCACHE", "VERILATOR_ROOT", "VPATH"):
        env.pop(key, None)
    if manifest["runtime"].get("kind") == "g6lc-fork-native":
        env["VERILATOR_ROOT"] = manifest["runtime"]["root"]
    manifest["origin_stages"] = {
        "profile_inputs": PROFILE_INPUTS,
        "queue_inputs": QUEUE_INPUTS,
        "profile_bench_sha256": _sha(data / "tb_g6lc_storamic_origin_profile.sv"),
        "queue_bench_sha256": _sha(data / "tb_g6lc_storamic_origin_queue.sv"),
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2))

    def build(tag, top, inputs):
        model = out / ("origin-" + tag)
        model.mkdir()
        command = [str(verilator), "--binary", "--timing", "--threads", "1",
                   "--assert", "-Wno-fatal", *WNO,
                   "--top-module", top, "--Mdir", str(model), "-o", "test",
                   "-I" + str(data)]
        command += [str(data / name) for name in inputs]
        command += manifest["runtime"].get("verilator_options", [])
        (out / ("origin-" + tag + "-command.json")).write_text(
            json.dumps(command))
        identity = build_model(command, model,
                               out / ("origin-" + tag + "-build.log"), manifest)
        builds.append(identity | {"origin_stage": tag})
        return model / "test"

    def sim(tag, exe, args=()):
        try:
            result = subprocess.run([str(exe), *args], env=env,
                                    cwd=exe.parent, capture_output=True,
                                    text=True, timeout=120)
            text = result.stdout + result.stderr
            rc = result.returncode
        except subprocess.TimeoutExpired:
            text, rc = "TIMEOUT", None
        (out / ("origin-" + tag + ".log")).write_text(text)
        return rc, text

    results = {}
    if want_profile:
        exe = build("profile", "tb_g6lc_storamic_origin_profile", PROFILE_INPUTS)
        rc, text = sim("profile-pos", exe)
        results["origin-profile-pos"] = (
            rc == 0 and "ORIGIN_PROFILE_PASS" in text and "%Error" not in text)
        rc, text = sim("profile-neg", exe, ["+oracle_negative"])
        results["origin-profile-negative"] = (
            rc != 0 and "negative-shared-writer" in text)
        rc, text = sim("profile-dbgneg", exe, ["+oracle_debug"])
        results["origin-profile-debug-negative"] = (
            rc != 0 and "negative-debug-authority" in text)
    if want_queue:
        exe = build("queue", "tb_g6lc_storamic_origin_queue", QUEUE_INPUTS)
        rc, text = sim("queue-pos", exe)
        results["origin-queue-pos"] = (
            rc == 0 and "ORIGIN_QUEUE_PASS" in text and "%Error" not in text)
        rc, text = sim("queue-neg", exe, ["+oracle_negative"])
        results["origin-queue-negative"] = (
            rc != 0 and "negative-oracle" in text)
    for tag, ok in results.items():
        outcomes.append({"origin_stage": tag, "pass": bool(ok)})
    failed = [tag for tag, ok in results.items() if not ok]
    if failed:
        raise RuntimeError("origin stage verdicts failed: " +
                           ", ".join(failed))
