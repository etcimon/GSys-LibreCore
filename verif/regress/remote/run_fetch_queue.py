#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Run a copied live-IQ diagnostic through testharness_proxy.py py --data inputs."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


EXPECTED_HEADER_SHA256 = "dfbc2c4aa3c1065d4465027c893c9677de10da4cfe7fb152e485eb32b8125166"
DEFAULT_RUNTIME_JSON = "/opt/testharness/runs/review-private-runtime-rebuild-20260915/output/runtime.json"


def main():
    data = Path(os.environ["TH_DATA_DIR"])
    out = Path(os.environ["TH_OUT_DIR"])
    names = ["config_pkg.sv", "g6lc64_smt2_config_pkg.sv", "riscv_pkg.sv", "ariane_pkg.sv", "g6lc_fetch_pkg.sv",
             "cva6_fifo_v3.sv", "instr_queue.sv", "tb_g6lc_fetch_queue.sv"]
    sources = []
    hashes = {}
    source_dir = out / "source"
    source_dir.mkdir()
    for name in names:
        src = data / name
        if not src.is_file():
            raise RuntimeError(f"missing uploaded source: {name}")
        dst = source_dir / name
        shutil.copy2(src, dst)
        hashes[name] = hashlib.sha256(dst.read_bytes()).hexdigest()
        sources.append(str(dst))
    (out / "sources.json").write_text(json.dumps(hashes, indent=2) + "\n")

    runtime_json = Path(os.environ.get("REVIEW_RUNTIME_JSON", DEFAULT_RUNTIME_JSON))
    runtime_identity = json.loads(runtime_json.read_text())
    runtime = Path(runtime_identity["privateRoot"])
    header_sha = hashlib.sha256((runtime / "include/verilated_funcs.h").read_bytes()).hexdigest()
    if runtime_identity["fixedHeaderSha256"] != EXPECTED_HEADER_SHA256 or header_sha != EXPECTED_HEADER_SHA256:
        raise RuntimeError(f"private runtime header mismatch: {header_sha}")
    canaries = json.loads((runtime_json.parent / "canaries.json").read_text())
    if [(c["tag"], c["rc"]) for c in canaries] != [("original", 1), ("fixed", 0)]:
        raise RuntimeError(f"unexpected runtime canaries: {canaries}")
    shutil.copy2(runtime_json, out / "runtime.json")
    shutil.copy2(runtime_json.parent / "canaries.json", out / "canaries.json")
    private_header = str(runtime / "include/verilated_funcs.h")
    original_header = str(Path(runtime_identity["originalRoot"]) / "include/verilated_funcs.h")

    verilator = shutil.which("verilator")
    if not verilator:
        raise RuntimeError("Verilator missing from proxy environment")
    results = []
    for slots, issue, harts, rvc in [(4, 2, 2, 1), (2, 1, 1, 1), (8, 2, 2, 1),
                                     (2, 1, 1, 0), (2, 2, 2, 0)]:
        work = out / f"s{slots}-i{issue}-h{harts}-c{rvc}"
        work.mkdir()
        command = [verilator, "--cc", "--main", "--exe", "--timing", "--assert", "--threads", "1",
                   "-Wno-fatal", "--top-module", "tb_g6lc_fetch_queue",
                   f"-GSLOTS={slots}", f"-GISSUE={issue}", f"-GHARTS={harts}", f"-GRVC={rvc}",
                   "--Mdir", str(work), "-o", "queue-test", *sources]
        (work / "build-command.json").write_text(json.dumps(command) + "\n")
        with (work / "verilate.log").open("w") as log:
            build = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=180)
        if build.returncode:
            print((work / "verilate.log").read_text()[-10000:])
            return build.returncode
        make_command = ["make", "-C", str(work), "-f", "Vtb_g6lc_fetch_queue.mk", "-j4",
                        "VERILATOR_ROOT=" + str(runtime)]
        (work / "make-command.json").write_text(json.dumps(make_command) + "\n")
        with (work / "build.log").open("w") as log:
            build = subprocess.run(make_command, stdout=log, stderr=subprocess.STDOUT, timeout=180)
        if build.returncode:
            print((work / "build.log").read_text()[-10000:])
            return build.returncode
        deps = "".join(p.read_text(errors="replace") for p in work.rglob("*.d"))
        deps_ok = private_header in deps and original_header not in deps
        exe = work / "queue-test"
        record = {"slots": slots, "issue": issue, "harts": harts, "rvc": rvc,
                  "runtimeHeaderSha256": header_sha, "privateRuntimeDeps": deps_ok,
                  "executableSha256": hashlib.sha256(exe.read_bytes()).hexdigest()}
        if deps_ok:
            result = subprocess.run([str(exe)], capture_output=True, text=True,
                                    env={"PATH": "/usr/bin:/bin"}, timeout=30)
            text = result.stdout + result.stderr
            (work / "sim.log").write_text(text)
            negative = subprocess.run([str(exe), "+oracle_negative"], capture_output=True, text=True,
                                      env={"PATH": "/usr/bin:/bin"}, timeout=30)
            neg_text = negative.stdout + negative.stderr
            (work / "sim-negative.log").write_text(neg_text)
            print(f"s{slots}/i{issue}/h{harts}/c{rvc}: {text[-3000:]}", flush=True)
            record["rc"] = result.returncode
            record["negativeRc"] = negative.returncode
            record["negativeDetected"] = (negative.returncode != 0
                                          and "order/data mismatch" in neg_text
                                          and "FETCH_QUEUE_PASS" not in neg_text)
            record["pass"] = (result.returncode == 0 and text.count("FETCH_QUEUE_PASS ") == 1
                              and record["negativeDetected"])
        else:
            record["pass"] = False
            print(f"s{slots}/i{issue}/h{harts}/c{rvc}: dep check failed "
                  f"(private header not found or original header present)", flush=True)
        results.append(record)
    (out / "result.json").write_text(json.dumps({"strictQualification": False,
        "kind": "rtl-leaf-diagnostic", "results": results}, indent=2) + "\n")
    return 0 if all(r["pass"] for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
