#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    root = Path(os.environ['TH_RUN_DIR'])
    out = Path(os.environ['TH_OUT_DIR'])
    repaired = Path(os.environ['REPAIRED_RR_OUTPUT'])
    observer = Path(os.environ['ORIGINAL_OBSERVER_OUTPUT'])
    fixed_models = json.loads((repaired / 'models.json').read_text())
    baseline = next(m for m in fixed_models if m['tag'] == 'g6lc64_smt2-rr0')
    runtime_info = json.loads((repaired / 'runtime.json').read_text())
    runtime = Path(runtime_info['privateRoot'])
    assert sha(runtime / 'include/verilated_funcs.h') == runtime_info['fixedHeaderSha256']
    for fixed in fixed_models:
        dependencies = '\n'.join(p.read_text(errors='replace') for p in Path(fixed['exe']).parent.glob('*.d'))
        assert str(runtime / 'include/verilated_funcs.h') in dependencies
        assert str(Path(runtime_info['originalRoot']) / 'include/verilated_funcs.h') not in dependencies
    assert sha(Path(baseline['exe'])) == baseline['sha256']
    original = json.loads((observer / 'model.json').read_text())
    original_exe = Path(original['exe'])
    assert sha(original_exe) == original['sha256']
    inputs = json.loads((observer / 'inputs.json').read_text())
    assert inputs['baselineSha256'] == baseline['originalSha256']
    sources = json.loads((observer / 'sources.json').read_text())
    source_root = Path(original.get('sourceRoot', str(observer.parent / 'repo')))
    for name, digest in sources.items():
        assert sha(source_root / name) == digest, name
    model = root / 'model'
    model.mkdir()
    generated_hashes = {}
    for pattern in ['*.cpp', '*.h', '*.mk', '*.dat']:
        for path in original_exe.parent.glob(pattern):
            shutil.copy2(path, model / path.name)
            generated_hashes[path.name] = sha(path)
    assert not (model / 'verilated_funcs.h').exists()
    command = ['make', '-C', str(model), '-f', 'Variane_testharness.mk', '-B', '-j4', 'VERILATOR_ROOT=' + str(runtime)]
    with (out / 'build.log').open('w') as log:
        build = subprocess.run(command, env=dict(os.environ, VPATH=str(source_root)), stdout=log, stderr=subprocess.STDOUT, timeout=900)
    if build.returncode:
        raise RuntimeError('observer runtime rebuild failed')
    dependencies = '\n'.join(p.read_text(errors='replace') for p in model.glob('*.d'))
    assert str(runtime / 'include/verilated_funcs.h') in dependencies
    assert str(Path(runtime_info['originalRoot']) / 'include/verilated_funcs.h') not in dependencies
    exe = model / 'Variane_testharness'
    digest = sha(exe)
    (out / 'generated-inputs.json').write_text(json.dumps(generated_hashes, indent=2))
    (out / 'sources.json').write_text(json.dumps(sources, indent=2))
    (out / 'model.json').write_text(json.dumps(dict(original, exe=str(exe), sha256=digest, sourceRoot=str(source_root), originalSha256=original['sha256'], derivedFrom=str(original_exe), runtime=runtime_info, rebuild=command), indent=2))
    (out / 'inputs.json').write_text(json.dumps(dict(inputs, baseline=baseline['exe'], baselineSha256=baseline['sha256'], originalBaselineSha256=inputs['baselineSha256'], runtimeHeaderSha256=runtime_info['fixedHeaderSha256']), indent=2))
    replay = json.loads(Path(os.environ['REPLAY_CORE_RESULTS']).read_text())
    assert [r['tag'] for r in replay] == ['n1-control', 'n2-witness', 'redirect-chain', 'n2-48k-norvc', 'n2-48k-rvc']
    results = []
    for record in replay:
        work = out / record['tag']
        work.mkdir()
        elf = Path(record['command'][-1])
        assert sha(elf) == record['elfSha256']
        run_command = [baseline['exe'], *record['command'][1:]]
        with (work / 'sim.log').open('w') as log:
            run = subprocess.run(run_command, cwd=work, env={'PATH': '/usr/bin:/bin', 'CVA6_TRACE_SPEC': 'exit cookie off=0x1000 val=1; exit cookie off=0x1000 val=3'}, stdout=log, stderr=subprocess.STDOUT, timeout=240)
        assert sha(Path(baseline['exe'])) == baseline['sha256']
        text = (work / 'sim.log').read_text(errors='replace')
        cookies = re.findall(r'\[cookie-exit\] t=(\d+) \[1000\]=0x([0-9a-fA-F]+)', text)
        ok = run.returncode == 0 and len(cookies) == 1 and int(cookies[0][1], 16) == 1 and '%Error' not in text and 'Assertion failed' not in text
        results.append(dict(record, status='pass' if ok else 'fail', rc=run.returncode, cookie=cookies, command=run_command, modelSha256=baseline['sha256'], runtimeHeaderSha256=runtime_info['fixedHeaderSha256']))
        (out / 'results.json').write_text(json.dumps(results, indent=2))
        print(results[-1], flush=True)
    if any(r['status'] != 'pass' for r in results):
        raise RuntimeError('corrected-runtime full-core replay failed')


if __name__ == '__main__':
    main()
