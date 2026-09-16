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
    data = Path(os.environ['TH_DATA_DIR'])
    base = Path('/opt/testharness/runs/review-redirect-accept-20260915')
    repo = root / 'repo'
    shutil.copytree(base / 'repo', repo)
    sources = json.loads((base / 'output/sources.json').read_text())
    for name, digest in sources.items():
        assert sha(repo / name) == digest, name
    for name in ['core/cva6.sv', 'core/Flist.cva6', 'core/fetch_B/frontend.sv', 'core/fetch_B/g6lc_fetch_pkg.sv', 'core/smt_legacy/g6lc_smt_pc_bank.sv', 'corev_apu/tb/g6lc_tb.cpp']:
        shutil.copy2(data / Path(name).name, repo / name)
        sources[name] = sha(repo / name)
    (out / 'sources.json').write_text(json.dumps(sources, indent=2))
    model = root / 'model'
    cmd = ['bash', '-c', '. /opt/testharness/env.sh; export CVA6_REPO_DIR="$1" SOFT_LADDER_VERLIB="$2" SOFT_LADDER_VERILATOR_THREADS=1 SOFT_LADDER_BUILD_TARGET=g6lc64_smt2 SOFT_LADDER_BUILD_JOBS=4; bash verif/regress/soft-ladder-build-harness.sh B', 'restart', str(repo), str(model)]
    with (out / 'build.log').open('w') as log:
        build = subprocess.run(cmd, cwd=repo, stdout=log, stderr=subprocess.STDOUT, timeout=900)
    if build.returncode:
        raise RuntimeError('restart candidate build failed')
    for name, digest in sources.items():
        assert sha(repo / name) == digest, name
    exe = model / 'Variane_testharness'
    digest = sha(exe)
    (out / 'model.json').write_text(json.dumps({'exe': str(exe), 'sha256': digest, 'build': cmd}, indent=2))
    print('MODEL', str(exe), digest, flush=True)
    tool = '/opt/testharness/toolchains/xpack-riscv-none-elf-gcc-14.2.0-3/bin/riscv-none-elf-'
    witness_root = Path('/opt/testharness/runs/review-dual-ipi-checked-20260915/output')
    payloads = [
        ('n1-control', Path('/opt/testharness/runs/review-operand-trace-20260915/output/positive.elf'), 'f6690e5bdb9fd19bb38bc36506601161d055bade632bf78a4595cbe890e29011'),
        ('n2-witness', witness_root / 'activation.elf', 'b9ef289534cf45be350e56f3eff3778ef5f74af5bbf2c25e863bd07eab2b1010'),
        ('redirect-chain', Path('/opt/testharness/runs/review-redirect-chain-before-20260915/output/norvc-n1/checked.elf'), '829fbeaa72f43f2a13e4951da478d80c581ec20a866b3039d7e6158e62a82019'),
    ]
    replay_results = os.environ.get('REVIEW_REPLAY_RESULTS')
    if replay_results:
        prior = json.loads(Path(replay_results).read_text())
        assert [r['tag'] for r in prior] == ['n1-control', 'n2-witness', 'redirect-chain', 'n2-48k-norvc', 'n2-48k-rvc']
        payloads = [(r['tag'], Path(r['command'][-1]), r['elfSha256']) for r in prior]
    source = (witness_root / 'activation.S').read_text()
    for compressed in ([] if replay_results else [False, True]):
        tag = 'n2-48k-rvc' if compressed else 'n2-48k-norvc'
        work = out / (tag + '-payload')
        work.mkdir()
        asm = work / 'checked.S'
        asm.write_text(source.replace('.option norvc', '.option rvc') if compressed else source)
        linker = work / 'checked.ld'
        shutil.copy2(base / 'output/checked/checked.ld', linker)
        elf = work / 'checked.elf'
        compile_cmd = [tool+'gcc', '-march=rv64imac_zicsr', '-mabi=lp64', '-nostdlib', '-static', '-Wl,--no-relax', '-T', str(linker), '-DNWORKERS=2', '-DNBYTES=49152', str(asm), '-o', str(elf)]
        subprocess.run(compile_cmd, check=True, capture_output=True)
        dis = subprocess.check_output([tool+'objdump', '-d', str(elf)], text=True)
        widths = re.findall(r'^\s*[0-9a-f]+:\s+([0-9a-f]+)\s', dis, re.M)
        assert widths and (compressed or all(len(w) == 8 for w in widths))
        (work / 'disassembly.txt').write_text(dis)
        (work / 'compile.json').write_text(json.dumps(compile_cmd, indent=2))
        payloads.append((tag, elf, sha(elf)))
    results = []
    for tag, elf, expected in payloads:
        assert sha(elf) == expected
        assert sha(exe) == digest
        work = out / tag
        work.mkdir()
        run_cmd = [str(exe), '-m', '1000000', '-s', '1', '+debug_disable', str(elf)]
        rules = 'exit cookie off=0x1000 val=1; exit cookie off=0x1000 val=3; log mem tag=done off=0x1090 max=1000'
        with (work / 'sim.log').open('w') as log:
            run = subprocess.run(run_cmd, cwd=work, env={'PATH': '/usr/bin:/bin', 'CVA6_TRACE_SPEC': rules}, stdout=log, stderr=subprocess.STDOUT, timeout=240)
        assert sha(elf) == expected
        assert sha(exe) == digest
        text = (work / 'sim.log').read_text(errors='replace')
        cookies = re.findall(r'\[cookie-exit\] t=(\d+) \[1000\]=0x([0-9a-fA-F]+)', text)
        clean = run.returncode == 0 and '%Error' not in text and 'Assertion failed' not in text
        status = 'pass' if clean and len(cookies) == 1 and int(cookies[0][1], 16) == 1 else 'no-verdict' if clean and not cookies else 'fail'
        results.append({'tag': tag, 'status': status, 'rc': run.returncode, 'cookie': cookies, 'elfSha256': expected, 'modelSha256': digest, 'command': run_cmd, 'strictQualification': False})
        (work / 'trace.txt').write_text('\n'.join(line for line in text.splitlines() if '[trace]' in line or '[cookie-exit]' in line))
        (out / 'results.json').write_text(json.dumps(results, indent=2))
        print(results[-1], flush=True)


if __name__ == '__main__':
    main()
