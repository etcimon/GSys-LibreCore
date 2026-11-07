#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Local bounded formal and coarse synthesis on a frozen route snapshot."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot", required=True)
    parser.add_argument("--output-root", required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    workspace = (root / "build-platform/workspace").resolve()
    snapshot = Path(args.snapshot).resolve()
    out = Path(args.output_root).resolve()
    if not out.is_relative_to(workspace) or not snapshot.is_relative_to(workspace):
        parser.error("snapshot and output must be contained in build-platform/workspace")
    manifest = json.loads((snapshot / "result.json").read_text(encoding="utf-8"))
    source = snapshot / "source"
    for name, digest in manifest["sources"].items():
        path = source / (name.removeprefix("generated:") if name.startswith("generated:") else name)
        if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise RuntimeError("snapshot source changed: " + name)
    out.mkdir(parents=True, exist_ok=False)
    inputs = [source / n for n in (
        "g6lc_storamic/rtl/include/g6lc_storamic_pkg.sv",
        "corev_apu/storamic/g6lc_storamic_ctrl_bridge.sv",
        "corev_apu/storamic/g6lc_storamic_checkpoint_route.sv")]
    formal = source / "verif/tb/storamic/formal_g6lc_storamic_checkpoint_route.sv"
    top = "formal_g6lc_storamic_checkpoint_route"
    synth_wrapper = out / "synth.sv"
    synth_wrapper.write_text(formal.read_text(encoding="utf-8").split(
        "  // Reference lifetime", 1)[0] + "endmodule\n", encoding="utf-8")
    report = {"qualification": False, "status": "incomplete", "scope": "local-route-component",
              "snapshot_manifest_sha256": hashlib.sha256((snapshot / "result.json").read_bytes()).hexdigest(),
              "script_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), "checks": []}
    for name in ("yosys", "yosys-smtbmc", "yices-smt2"):
        tool = shutil.which(name)
        if not tool:
            parser.error(name + " unavailable")
        report[name] = hashlib.sha256(Path(tool).read_bytes()).hexdigest()

    def save():
        (out / "result.json").write_text(json.dumps(report, indent=2), encoding="utf-8")

    def run(command, name):
        with (out / (name + ".log")).open("w") as log:
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=180)
        return result.returncode, (out / (name + ".log")).read_text(encoding="utf-8")

    def frontend(enabled, bad, wrapper):
        return (f"read_slang --top {top} -DSYNTHESIS -DFORMAL -G Enabled={enabled} "
                f"-G BadOracle={bad} -I{source} " + " ".join(map(str, inputs + [wrapper])))

    save()
    try:
        for enabled in (0, 1):
            name = f"synth-{enabled}"
            command = frontend(enabled, 0, synth_wrapper)
            command += f"; hierarchy -top {top}; proc; flatten; opt; memory_collect; opt"
            command += "; check -assert; scc -expect 0; select -assert-none t:$dlatch t:$adlatch; stat"
            command += "; write_json " + str(out / (name + ".json"))
            (out / (name + ".ys")).write_text(command, encoding="utf-8")
            rc, _ = run(["yosys", "-p", command], name)
            if rc:
                raise RuntimeError(name)
            report["checks"].append(name)
            save()
        for enabled, bad in ((0, 0), (1, 0), (1, 1)):
            name = f"formal-{enabled}-bad{bad}"
            smt = out / (name + ".smt2")
            command = frontend(enabled, bad, formal)
            command += f"; prep -top {top}; flatten; async2sync; dffunmap; write_smt2 -wires {smt}"
            (out / (name + ".ys")).write_text(command, encoding="utf-8")
            rc, _ = run(["yosys", "-p", command], name + "-build")
            if rc:
                raise RuntimeError(name + "-build")
            rc, text = run(["yosys-smtbmc", "-s", "yices", "-t", "16", "--noprogress", str(smt)], name)
            expected = "Status: FAILED" if bad else "Status: PASSED"
            if (rc != 0) != bool(bad) or expected not in text:
                raise RuntimeError(name)
            report["checks"].append(name)
            if enabled and not bad:
                rc, text = run(["yosys-smtbmc", "-s", "yices", "-t", "16", "-c",
                                "--noprogress", str(smt)], name + "-cover")
                if rc or "Status: PASSED" not in text:
                    raise RuntimeError(name + "-cover")
                report["checks"].append(name + "-cover")
            save()
        report["status"] = "pass"
    except (subprocess.SubprocessError, RuntimeError) as error:
        report["status"] = "fail"
        report["error"] = str(error)
        raise
    finally:
        save()


if __name__ == "__main__":
    main()
