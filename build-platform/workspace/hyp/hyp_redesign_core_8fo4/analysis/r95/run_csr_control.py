#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Remote-only controls on private copies of the verified CSR source snapshot."""
import hashlib
import json
import os
from pathlib import Path
import runpy
import shutil
import traceback
import zipfile


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    data = Path(os.environ["TH_DATA_DIR"])
    out = Path(os.environ["TH_OUT_DIR"])
    control = json.loads((data / "csr-controls-input.json").read_text())
    mode = os.environ["HYP8_CSR_CONTROL"]
    if mode not in ("baseline-small", "narrow", "prefix"):
        raise ValueError(mode)
    source = Path(control["remote_source"]).resolve()
    if not source.is_relative_to("/opt/testharness/runs"):
        raise ValueError("not an isolated run source")
    if sha(source / "manifest.json") != control["source_manifest_sha256"]:
        raise ValueError("original manifest identity mismatch")
    manifest = json.loads((source / "manifest.json").read_text())
    for rel, expected in manifest["files"].items():
        hit = (source / rel).resolve()
        if not hit.is_relative_to(source) or sha(hit) != expected:
            raise ValueError(f"original source mismatch: {rel}")
    runner = data / "run_hyp8_memory.py"
    archive = data / "sources.zip"
    if sha(runner) != control["runner_sha256"]:
        raise ValueError("runner identity mismatch")
    if sha(archive) != control["preimage_sha256"]:
        raise ValueError("preimage identity mismatch")
    copied = out.parent / "control-source"
    shutil.copytree(source, copied)  # Fails if a previous copy exists.
    hyp = copied / "build-platform/workspace/hyp/hyp_redesign_core_8fo4"
    changed = []
    if mode == "baseline-small":
        with zipfile.ZipFile(archive) as zf:
            names = zf.namelist()
            if len(names) != 6:
                raise ValueError("expected all six pre-repair files")
            for name in names:
                target = (hyp / name).resolve()
                if not target.is_relative_to(hyp.resolve()):
                    raise ValueError("unsafe archive path")
                target.write_bytes(zf.read(name))
                changed.append(target)
        os.environ["HYP8_EXTRA_DEFINES"] = "G6LC_HYP8_CSR_SMALL_ONLY"
    else:
        os.environ.pop("HYP8_EXTRA_DEFINES", None)
        if mode == "narrow":
            target = hyp / "core/ooo/g6lc_ooo_pkg.sv"
            before = "return (slots <= 2) ? 2 : $clog2(slots + 1);"
            after = "return 2;"
        else:
            target = hyp / "core/csr_buffer.sv"
            before = ("for (int unsigned step = 1; step < DEPTH; step <<= 1)\n"
                      "          below |= below << step;")
            after = "below |= below << 1;\n        below |= below << 2;"
        text = target.read_text()
        if text.count(before) != 1:
            raise ValueError("mutation site is not unique")
        target.write_text(text.replace(before, after))
        changed.append(target)
    for path in changed:
        manifest["files"][path.relative_to(copied).as_posix()] = sha(path)
    manifest["control"] = mode
    manifest["original_manifest_sha256"] = control["source_manifest_sha256"]
    (copied / "manifest.json").write_text(json.dumps(manifest, indent=2))
    shutil.copy2(copied / "manifest.json", out / "control-source-manifest.json")
    case = out / "case"
    case.mkdir()
    os.environ.update(TH_DATA_DIR=str(copied), TH_OUT_DIR=str(case),
                      HYP8_LEAF="csr-credit")
    rc = 1
    try:
        runpy.run_path(str(runner), run_name="__main__")
    except SystemExit as exc:
        rc = int(exc.code or 0)
    except Exception:
        traceback.print_exc()
    results_path = case / "results.json"
    results = json.loads(results_path.read_text()) if results_path.exists() else []
    text = (case / "sim.log").read_text() if (case / "sim.log").exists() else ""
    clean_build = bool(results) and not results[0]["warnings"] and not any(
        results[0]["openDiagnostics"].values())
    markers = ("CSR_CREDIT ports=",) if mode == "narrow" else (
        "csra_eq", "allocation", "alloc", "duplicate", "CSR_CREDIT ports=8")
    if mode == "baseline-small":
        passed = (rc == 0 and clean_build and
                  "HYP8_CSR_CREDIT_PASS cases=2" in text)
    else:
        passed = (rc != 0 and clean_build and len(results) == 2 and
                  results[1]["rc"] != 0 and
                  "HYP8_CSR_CREDIT_PASS" not in text and
                  any(marker.lower() in text.lower() for marker in markers))
    receipt = {
        "control": mode, "passed": passed, "rawRunnerRc": rc,
        "cleanBuild": clean_build,
        "originalManifestSha256": control["source_manifest_sha256"],
        "variantManifestSha256": sha(copied / "manifest.json"),
        "changed": {p.relative_to(copied).as_posix(): sha(p) for p in changed},
        "simulationResults": results,
    }
    (out / "control-result.json").write_text(json.dumps(receipt, indent=2))
    print(f"CSR_CONTROL_{'PASS' if passed else 'FAIL'} mode={mode} raw_rc={rc}")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
