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


def no_overlap():
    running = []
    for entry in Path('/proc').iterdir():
        if entry.name.isdecimal():
            try:
                if (entry / 'exe').resolve().name == 'Variane_testharness':
                    running.append(entry.name)
            except OSError:
                pass
    if running:
        raise RuntimeError('another harness is active: ' + ','.join(running))


def validate_controls(source, out):
    runs = json.loads((source / 'runs.json').read_text())
    for record in runs:
        work = Path(record.get('reusedFrom', str(source))) / record['tag']
        assert record['matchedControl'] and record['rc'] == 0
        assert sha(work / 'sim.log') == record['logSha256']
        for name, digest in record['existingRetirementTraces'].items():
            assert sha(work / name) == digest
        if record['observer']:
            trace = work / 'operand-trace-0.log'
            assert sha(trace) == record['traceSha256']
            assert '[ot-end]' in trace.read_text()
    witness_runs = [r for r in runs if not r['tag'].endswith('positive')]
    positive_runs = [r for r in runs if r['tag'].endswith('positive')]
    assert len(witness_runs) == 9 and len(positive_runs) == 2
    assert all(r['cookie'] == witness_runs[0]['cookie'] for r in witness_runs)
    assert all(r['existingRetirementTraces'] == witness_runs[0]['existingRetirementTraces'] for r in witness_runs)
    assert positive_runs[0]['cookie'] == positive_runs[1]['cookie']
    assert positive_runs[0]['existingRetirementTraces'] == positive_runs[1]['existingRetirementTraces']
    traces = [r['traceSha256'] for r in witness_runs if r['observer']]
    assert len(traces) == 3 and len(set(traces)) == 1
    result = {'sourceRun': str(source), 'serial': True, 'witnessControls': len(witness_runs), 'witnessExpectedCookie': witness_runs[0]['expectedCookie'], 'positiveControls': len(positive_runs), 'observerTraceSha256': traces[0], 'matched': True, 'strictQualification': False}
    (out / 'controls.json').write_text(json.dumps(result, indent=2))
    print(result, flush=True)


def inspect_windows(source, out):
    records = json.loads((source.parent / 'runs.json').read_text())
    record = next(r for r in records if r['tag'] == source.name)
    assert record['observer'] and record['matchedControl']
    command = list(record['command'])
    assert sha(Path(command[0])) == record['modelSha256']
    assert sha(Path(command[-1])) == record['elfSha256']
    command.insert(-1, '+fetch_win_trace')
    no_overlap()
    with (out / 'sim.log').open('w') as log:
        run = subprocess.run(command, cwd=out, env={'PATH': '/usr/bin:/bin', 'CVA6_TRACE_SPEC': 'exit cookie off=0x1000 val=1; exit cookie off=0x1000 val=3'}, stdout=log, stderr=subprocess.STDOUT, timeout=120)
    assert run.returncode == record['rc']
    assert sha(out / 'operand-trace-0.log') == record['traceSha256']
    assert {p.name: sha(p) for p in out.glob('trace_hart_*.dasm')} == record['existingRetirementTraces']
    windows = [line for line in (out / 'sim.log').read_text().splitlines() if line.startswith('[win]')]
    assert windows
    (out / 'windows.txt').write_text('\n'.join(windows) + '\n')
    (out / 'inspection.json').write_text(json.dumps({'source': str(source), 'command': command, 'matched': True, 'traceSha256': record['traceSha256']}, indent=2))


def main():
    if os.environ.get('OPERAND_INSPECT_RUN'):
        inspect_windows(Path(os.environ['OPERAND_INSPECT_RUN']), Path(os.environ['TH_OUT_DIR']))
        return
    if os.environ.get('OPERAND_VALIDATE_ONLY'):
        validate_controls(Path(os.environ['OPERAND_VALIDATE_ONLY']), Path(os.environ['TH_OUT_DIR']))
        return
    root = Path(os.environ['TH_RUN_DIR'])
    out = Path(os.environ['TH_OUT_DIR'])
    data = Path(os.environ['TH_DATA_DIR'])
    base = Path(os.environ.get('OPERAND_BASE', '/opt/testharness/runs/review-redirect-accept-20260915'))
    baseline = base / 'model/Variane_testharness'
    if os.environ.get('OPERAND_BASE') and not os.environ.get('OPERAND_BASE_SHA256'):
        raise ValueError('an overridden baseline requires an explicit model hash')
    baseline_sha = os.environ.get('OPERAND_BASE_SHA256', '3aa9014ddb244e7a7086909f43846f62a68f868e0243b20ff17cc52dfa67a502')
    witness_cookie = int(os.environ.get('OPERAND_WITNESS_COOKIE', '3'))
    if witness_cookie not in {1, 3}:
        raise ValueError('unknown witness verdict')
    witness = Path(os.environ.get('OPERAND_WITNESS_ELF', '/opt/testharness/runs/review-dual-ipi-checked-20260915/output/activation.elf'))
    if os.environ.get('OPERAND_WITNESS_ELF') and not os.environ.get('OPERAND_WITNESS_SHA256'):
        raise ValueError('an overridden witness requires its hash')
    witness_sha = os.environ.get('OPERAND_WITNESS_SHA256', 'b9ef289534cf45be350e56f3eff3778ef5f74af5bbf2c25e863bd07eab2b1010')
    rvc = os.environ.get('OPERAND_RVC', '0') == '1'
    cap = int(os.environ.get('OPERAND_CYCLE_LIMIT', '30000'))
    if cap < 10240 or cap > 1000000:
        raise ValueError('operand trace cycle cap outside 10240..1000000')
    assert sha(baseline) == baseline_sha
    assert sha(witness) == witness_sha
    previous = Path(os.environ['OPERAND_REUSE_CONTROLS']) if os.environ.get('OPERAND_REUSE_CONTROLS') else None
    tool = '/opt/testharness/toolchains/xpack-riscv-none-elf-gcc-14.2.0-3/bin/riscv-none-elf-'
    if previous:
        prior_inputs = json.loads((previous / 'inputs.json').read_text())
        positive = previous / 'positive.elf'
        positive_sha = prior_inputs['positiveSha256']
        compile_cmd = prior_inputs['compile']
        assert sha(positive) == positive_sha
        assert sha(data / 'mini_checked_work.S') == prior_inputs.get('positiveInputSha256', prior_inputs['positiveSourceSha256'])
        assert prior_inputs.get('positiveRvc', False) == rvc
        positive_source_sha = prior_inputs['positiveSourceSha256']
    else:
        linker = out / 'control.ld'
        linker.write_text('ENTRY(_start)\nSECTIONS { . = 0x80000000; .text : { *(.text.init) *(.text*) } . = 0x80001000; .tohost : { *(.tohost) } . = 0x80001080; .data : { *(.data*) } .bss : { *(.bss*) } }\n')
        positive = out / 'positive.elf'
        positive_source = out / 'positive.S'
        source_text = (data / 'mini_checked_work.S').read_text()
        positive_source.write_text(source_text.replace('.option norvc', '.option rvc') if rvc else source_text)
        positive_source_sha = sha(positive_source)
        compile_cmd = [tool+'gcc', '-march=rv64imac_zicsr', '-mabi=lp64', '-nostdlib', '-static', '-Wl,--no-relax', '-T', str(linker), '-DNWORKERS=1', '-DNBYTES=4096', str(positive_source), '-o', str(positive)]
        subprocess.run(compile_cmd, check=True, capture_output=True)
        positive_sha = sha(positive)
    for tag, elf in [('positive', positive), ('witness', witness)]:
        dis = subprocess.check_output([tool+'objdump', '-d', str(elf)], text=True)
        widths = re.findall(r'^\s*[0-9a-f]+:\s+([0-9a-f]+)\s', dis, re.M)
        assert widths and (any(len(w) == 4 for w in widths) if rvc else all(len(w) == 8 for w in widths)), tag
        (out / (tag + '.dis')).write_text(dis)
    (out / 'inputs.json').write_text(json.dumps({'baseline': str(baseline), 'baselineSha256': baseline_sha, 'witness': str(witness), 'witnessSha256': witness_sha, 'positiveSha256': positive_sha, 'positiveSourceSha256': positive_source_sha, 'positiveInputSha256': sha(data / 'mini_checked_work.S'), 'positiveRvc': rvc, 'compile': compile_cmd, 'observerSha256': sha(data / 'g6lc_operand_trace.svh'), 'strictQualification': False}, indent=2))
    runs = []

    def run(tag, exe, digest, elf, elf_sha, enabled, expected):
        no_overlap()
        assert sha(exe) == digest
        assert sha(elf) == elf_sha
        work = out / tag
        work.mkdir()
        command = [str(exe), '-m', str(cap), '-s', '1', '+debug_disable']
        if enabled:
            command += ['+g6lc_operand_trace=1', f'+g6lc_operand_trace_limit={cap}']
        command.append(str(elf))
        env = {'PATH': '/usr/bin:/bin', 'CVA6_TRACE_SPEC': 'exit cookie off=0x1000 val=1; exit cookie off=0x1000 val=3'}
        with (work / 'sim.log').open('w') as log:
            result = subprocess.run(command, cwd=work, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=120)
        assert sha(exe) == digest
        assert sha(elf) == elf_sha
        text = (work / 'sim.log').read_text(errors='replace')
        cookies = re.findall(r'\[cookie-exit\] t=(\d+) \[1000\]=0x([0-9a-fA-F]+)', text)
        trace = work / 'operand-trace-0.log'
        observed = result.returncode == 0 and len(cookies) == 1 and int(cookies[0][1], 16) == expected and '%Error' not in text and 'Assertion failed' not in text
        if enabled:
            observed = observed and trace.is_file() and '[ot-end]' in trace.read_text()
        else:
            observed = observed and not trace.exists()
        retirement = {p.name: sha(p) for p in work.glob('trace_hart_*.dasm')}
        observed = observed and bool(retirement)
        record = {'tag': tag, 'rc': result.returncode, 'cookie': cookies, 'expectedCookie': expected, 'matchedControl': observed, 'observer': enabled, 'modelSha256': digest, 'elfSha256': elf_sha, 'command': command, 'logSha256': sha(work / 'sim.log'), 'traceSha256': sha(trace) if trace.exists() else None, 'existingRetirementTraces': retirement}
        runs.append(record)
        (out / 'runs.json').write_text(json.dumps(runs, indent=2))
        print(record, flush=True)
        if not observed:
            raise RuntimeError('control failed; stop attribution: ' + tag)

    def observe(exe, digest):
        for n in range(3):
            run(f'observer-off-{n}', exe, digest, witness, witness_sha, False, witness_cookie)
        for n in range(3):
            run(f'observer-on-{n}', exe, digest, witness, witness_sha, True, witness_cookie)
        run('observer-positive', exe, digest, positive, positive_sha, True, 1)
        validate_controls(out, out)

    if previous:
        prior_runs = json.loads((previous / 'runs.json').read_text())[:4]
        assert [r['tag'] for r in prior_runs] == ['baseline-off-0', 'baseline-off-1', 'baseline-off-2', 'baseline-positive']
        for record in prior_runs:
            assert record['matchedControl'] and record['modelSha256'] == baseline_sha
            assert record['elfSha256'] == (positive_sha if record['tag'].endswith('positive') else witness_sha)
            assert sha(previous / record['tag'] / 'sim.log') == record['logSha256']
            for name, digest in record['existingRetirementTraces'].items():
                assert sha(previous / record['tag'] / name) == digest
            runs.append(dict(record, reusedFrom=str(previous)))
    else:
        for n in range(3):
            run(f'baseline-off-{n}', baseline, baseline_sha, witness, witness_sha, False, witness_cookie)
        run('baseline-positive', baseline, baseline_sha, positive, positive_sha, False, 1)
    if os.environ.get('OPERAND_REUSE_MODEL'):
        model_file = Path(os.environ['OPERAND_REUSE_MODEL'])
        prior_inputs = json.loads((model_file.parent / 'inputs.json').read_text())
        assert prior_inputs['baselineSha256'] == baseline_sha
        assert prior_inputs['observerSha256'] == sha(data / 'g6lc_operand_trace.svh')
        identity = json.loads(model_file.read_text())
        source_root = Path(identity.get('sourceRoot', str(model_file.parent.parent / 'repo')))
        sources = json.loads((model_file.parent / 'sources.json').read_text())
        for name, expected in sources.items():
            assert sha(source_root / name) == expected, name
        exe = Path(identity['exe'])
        assert sha(exe) == identity['sha256']
        (out / 'sources.json').write_text(json.dumps(sources, indent=2))
        (out / 'model.json').write_text(json.dumps(dict(identity, sourceRoot=str(source_root), reusedFrom=str(model_file)), indent=2))
        observe(exe, identity['sha256'])
        return
    repo = root / 'repo'
    shutil.copytree(base / 'repo', repo)
    sources = json.loads((base / 'output/sources.json').read_text())
    for name, digest in sources.items():
        assert sha(repo / name) == digest, name
    monitor = repo / 'verif/tb/core/g6lc_operand_trace.svh'
    shutil.copy2(data / monitor.name, monitor)
    core = repo / 'core/cva6.sv'
    original = core.read_bytes()
    nl = b'\r\n' if b'\r\n' in original else b'\n'
    needle = b'  //pragma translate_on\n\n\n  //RVFI INSTR'.replace(b'\n', nl)
    assert original.count(needle) == 1
    addition = (f'`ifndef SYNTHESIS\n`include "{monitor.as_posix()}"\n`endif\n').encode().replace(b'\n', nl)
    rewritten = original.replace(needle, addition + needle)
    assert rewritten.replace(addition, b'', 1) == original
    core.write_bytes(rewritten)
    tb = repo / 'corev_apu/tb/g6lc_tb.cpp'
    original_tb = tb.read_bytes()
    old = b'"iq_trace", nullptr'
    new = b'"iq_trace", "g6lc_operand_trace", nullptr'
    assert original_tb.count(old) == 1
    shutdown = b'  if (dtm) delete dtm;'
    assert original_tb.count(shutdown) == 1
    tb.write_bytes(original_tb.replace(old, new).replace(shutdown, b'  top->final();\n' + shutdown))
    for name in ['core/cva6.sv', 'corev_apu/tb/g6lc_tb.cpp', 'verif/tb/core/g6lc_operand_trace.svh']:
        sources[name] = sha(repo / name)
    (out / 'sources.json').write_text(json.dumps(sources, indent=2))
    model = root / 'model'
    build_cmd = ['bash', '-c', '. /opt/testharness/env.sh; export CVA6_REPO_DIR="$1" SOFT_LADDER_VERLIB="$2" SOFT_LADDER_VERILATOR_THREADS=1 SOFT_LADDER_BUILD_TARGET=g6lc64_smt2 SOFT_LADDER_BUILD_JOBS=4; bash verif/regress/soft-ladder-build-harness.sh B', 'trace', str(repo), str(model)]
    with (out / 'build.log').open('w') as log:
        build = subprocess.run(build_cmd, cwd=repo, stdout=log, stderr=subprocess.STDOUT, timeout=900)
    if build.returncode:
        raise RuntimeError('instrumented build failed; see build.log')
    for name, digest in sources.items():
        assert sha(repo / name) == digest, name
    exe = model / 'Variane_testharness'
    digest = sha(exe)
    (out / 'model.json').write_text(json.dumps({'exe': str(exe), 'sha256': digest, 'build': build_cmd, 'sourceRoot': str(repo), 'projectionCheck': 'removing only the observer include/guard restores baseline cva6.sv bytes'}, indent=2))
    observe(exe, digest)


if __name__ == '__main__':
    main()
