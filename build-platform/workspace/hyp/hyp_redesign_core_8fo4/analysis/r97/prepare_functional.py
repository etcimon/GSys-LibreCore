# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Finalize private r97 closures; verify every source, including the baseline replacement."""
import hashlib
import json
from pathlib import Path
import shutil

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[5]
BASE = ROOT / "build-platform/workspace/build/hyp8-r97-flu-1793294051"
REL = "build-platform/workspace/hyp/hyp_redesign_core_8fo4/core/ooo/g6lc_flu_reserve.sv"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


records = {}
runner = BASE / "scripts/run_hyp8_memory.py"
if not runner.exists():
    shutil.copy2(ROOT / "verif/regress/remote/run_hyp8_memory.py", runner)
assert sha(runner) == sha(ROOT / "verif/regress/remote/run_hyp8_memory.py")
for name, source, rtl in (
    ("baseline-verified", "baseline", HERE / "g6lc_flu_reserve.before.sv"),
    ("candidate-final", "candidate", ROOT / REL),
):
    out = BASE / name
    fresh = not out.exists()
    if fresh:
        shutil.copytree(BASE / source, out)
    manifest = json.loads((out / "manifest.json").read_text())
    assert REL in manifest["files"]
    for rel, digest in manifest["files"].items():
        if rel != REL:
            assert sha(out / rel) == digest, rel
    if fresh:
        shutil.copy2(rtl, out / REL)
        manifest["files"][REL] = sha(out / REL)
        manifest["r97_variant"] = name
        (out / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    assert sha(out / REL) == sha(rtl)
    for rel, digest in manifest["files"].items():
        assert sha(out / rel) == digest, rel
    bench = "verif/tb/core/tb_g6lc_hyp8_control.sv"
    assert sha(out / bench) == sha(ROOT / bench)
    records[name] = dict(path=out.as_posix(), manifest_sha256=sha(out / "manifest.json"),
                         rtl_sha256=sha(out / REL), bench_sha256=sha(out / bench))
records["runner"] = dict(path=runner.as_posix(), sha256=sha(runner))
with (HERE / "functional-inputs-final.json").open("x", encoding="utf-8") as f:
    json.dump(records, f, indent=2)
print(json.dumps(records, indent=2))
