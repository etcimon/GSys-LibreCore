#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import zipfile

PREFIX = "/opt/testharness/repo/"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def prepare(root, archive, qualify_ooo=False):
    root = root.resolve()
    scripts = {}
    inputs = {}
    targets = {}
    for stage in ("lint", "synth"):
        path = root / f"build-platform/workspace/build/remote/remote-{stage}.sh"
        body = path.read_text(encoding="utf-8")
        scripts[stage] = body.encode()
        targets[stage] = re.findall(r'cat > "\$RUNROOT/([\w-]+)\.f"', body)
        assert targets[stage], f"missing generated {stage} manifests"
        for token in re.findall(re.escape(PREFIX) + r'[^\s\"\'<>;+]+', body):
            path = root / token[len(PREFIX):]
            assert path.resolve().is_relative_to(root), path
            if path.is_dir():
                files = [p for p in path.rglob("*")
                         if p.is_file() and p.suffix in (".svh", ".vh", ".sv", ".v")]
            else:
                files = [path]
            for source in files:
                assert source.resolve().is_relative_to(root), source
                inputs[source.relative_to(root).as_posix()] = source.read_bytes()
    # Same-directory `include "x.sv" files are resolved by the tools relative
    # to the including file and never appear in the generated scripts.
    pending = list(inputs)
    while pending:
        name = pending.pop()
        for included in re.findall(r'`include\s+"([^"/\\]+)"', inputs[name].decode(errors="replace")):
            sibling = (root / name).parent / included
            key = sibling.relative_to(root).as_posix() if sibling.is_file() else None
            if key and key not in inputs:
                inputs[key] = sibling.read_bytes()
                pending.append(key)
    manifest = {"sources": {name: sha(data) for name, data in inputs.items()},
                "scripts": {stage: sha(data) for stage, data in scripts.items()},
                "targets": targets, "sharedMirrorModified": False}
    for name, digest in manifest["sources"].items():
        assert sha((root / name).read_bytes()) == digest, f"source changed while capturing: {name}"
    if qualify_ooo:
        target = 'g6lc64_smt2_ooo_int'
        assert all(value == [target] for value in targets.values()), 'generate the integer OoO target first'
        name = f'core/include/{target}_config_pkg.sv'
        body = inputs[name].decode()
        changes = {"NrCores: unsigned'(1)": "NrCores: unsigned'(2)",
                   'CohPolicy: config_pkg::COH_FILTERED': 'CohPolicy: config_pkg::COH_OOO'}
        manifest['qualificationOnly'] = True
        manifest['overrides'] = changes
        manifest['originalSourceSha256'] = {name: sha(inputs[name])}
        manifest['originalScripts'] = dict(manifest['scripts'])
        for old, new in changes.items():
            assert body.count(old) == 1, old
            body = body.replace(old, new)
        inputs[name] = body.encode()
        manifest['sources'][name] = sha(inputs[name])
        for stage in scripts:
            body = scripts[stage].decode()
            assert body.count('+define+G6LC_FETCH_B') == 1
            body = body.replace('+define+G6LC_FETCH_B',
                                '+define+G6LC_FETCH_B\n+define+G6LC_OOO_COH_QUALIFY')
            scripts[stage] = body.encode()
            manifest['scripts'][stage] = sha(scripts[stage])
    with archive.open("xb") as output, zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as pack:
        for name, data in inputs.items():
            pack.writestr("snapshot/" + name, data)
        for stage, data in scripts.items():
            pack.writestr(f"scripts/{stage}.sh", data)
        pack.writestr("manifest.json", json.dumps(manifest, indent=2))
    print(json.dumps({"archive": str(archive), "sources": len(inputs), "targets": targets}))


def execute():
    data = Path(os.environ["TH_DATA_DIR"])
    out = Path(os.environ["TH_OUT_DIR"]).resolve()
    archives = list(data.glob("*.zip"))
    assert len(archives) == 1, "exactly one captured gate archive is required"
    with zipfile.ZipFile(archives[0]) as pack:
        for member in pack.infolist():
            name = PurePosixPath(member.filename)
            assert not name.is_absolute() and ".." not in name.parts
            destination = out / name
            assert destination.resolve().is_relative_to(out)
            destination.parent.mkdir(parents=True, exist_ok=True)
            with destination.open("xb") as output:
                output.write(pack.read(member))
    manifest = json.loads((out / "manifest.json").read_text())
    snapshot = out / "snapshot"
    for name, digest in manifest["sources"].items():
        assert sha((snapshot / name).read_bytes()) == digest, name
    assembly = []
    for source in sorted(data.glob("*.S")):
        assert not re.search(r'^\s*#\s*(if|ifdef|ifndef|include|define|undef|else|elif|endif)\b',
                             source.read_text(), re.M), "raw assembly fixture contains CPP directives"
        command = ["riscv-none-elf-gcc", "-x", "assembler", "-march=rv64imac_zicsr", "-mabi=lp64",
                   "-c", str(source), "-o", str(out / (source.stem + ".o"))]
        process = subprocess.run(command, capture_output=True, text=True, timeout=60)
        (out / (source.stem + "-assemble.log")).write_text(process.stdout + process.stderr)
        assembly.append({"source": source.name, "sourceSha256": sha(source.read_bytes()),
                         "command": command, "rc": process.returncode, "simulated": False})
    (out / "assembly.json").write_text(json.dumps(assembly, indent=2))
    assert all(row["rc"] == 0 for row in assembly), "assembly compilation failed"
    results = []
    for stage in ("lint", "synth"):
        script_path = out / "scripts" / f"{stage}.sh"
        original = script_path.read_bytes()
        assert sha(original) == manifest["scripts"][stage]
        body = original.decode().replace(PREFIX.rstrip("/"), snapshot.as_posix())
        old = f'RUNROOT="$HOME/.cache/g6lc-{stage}"'
        assert body.count(old) == 1
        body = body.replace(old, f'RUNROOT="{out.as_posix()}/{stage}"')
        assert PREFIX not in body
        runner = out / f"run-{stage}.sh"
        runner.write_text(body)
        log_path = out / f"{stage}.log"
        with log_path.open("w") as log:
            try:
                process = subprocess.run(["bash", str(runner)], cwd=snapshot,
                                         stdout=log, stderr=subprocess.STDOUT,
                                         timeout=int(os.environ.get('REVIEW_GATE_STAGE_TIMEOUT', '5400')))
                rc = process.returncode
            except subprocess.TimeoutExpired:
                rc = 124
        rows = re.findall(r'^RESULT (\S+) rc=(\d+) warnings=(\d+) errors=(\d+)',
                          log_path.read_text(errors="replace"), re.M)
        expected = manifest["targets"][stage]
        complete = len(rows) == len(expected) and sorted(row[0] for row in rows) == sorted(expected)
        results.append({"stage": stage, "rc": rc, "complete": complete,
                        "results": [{"target": row[0], "rc": int(row[1]),
                                     "warnings": int(row[2]), "errors": int(row[3])}
                                    for row in rows],
                        "passed": rc == 0 and complete and all(int(row[1]) == 0 and
                                                               int(row[3]) == 0 for row in rows),
                        "scriptSha256": sha(body.encode())})
        (out / "results.json").write_text(json.dumps(results, indent=2))
        print(json.dumps(results[-1]), flush=True)
    for name, digest in manifest["sources"].items():
        assert sha((snapshot / name).read_bytes()) == digest, f"captured source modified: {name}"
    return 0 if all(row["passed"] for row in results) else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--prepare", type=Path)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[3])
    parser.add_argument('--qualify-ooo', action='store_true')
    args = parser.parse_args()
    if args.prepare:
        prepare(args.root, args.prepare, args.qualify_ooo)
    else:
        raise SystemExit(execute())
