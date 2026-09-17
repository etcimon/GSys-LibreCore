#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def apply_l2_size_overlay(repo, data, target, depth):
    assert target in {'g6lc64_smt2','g6lc64_stream8'}
    baseline = 16 if target == 'g6lc64_smt2' else 8
    assert depth in {baseline,2}
    pins = {'core/fetch_B/instr_queue.sv':'7fba053f6744f4c907afe1e32a613b3832297edf8113c0fcd0f4c4402a3cc645',
            'core/fetch_B/frontend.sv':'626dfa089730ba0f2fe7ced73d8bc811ab24de83897461fa08cf7639e90cee39',
            'core/frontend/g6lc_bp_statcor.sv':'6064905a249a71dbed7abdf66d4a525c61eb39eadb391dee5767d82052990651',
            'corev_apu/coherence/g6lc_inval_bus.sv':'2cafee7fbcda6f30274461a4486fd613698e61ef67691e08dda94b2ff0592945',
            'corev_apu/coherence/g6lc_coherence_hub.sv':'2b9af41accb966d3d299125a2e45fc3c32883f29e8f65700004bfd2c15271f6d'}
    for name, expected in pins.items():
        supplied = data/Path(name).name
        assert sha(supplied)==expected, name
        shutil.copy2(supplied,repo/name)
    package=repo/f'core/include/{target}_config_pkg.sv'
    expected_pkg = '4c01537419ee3558b103acb15f48399daa2f83351b0a06da19f67702369be221' if target=='g6lc64_smt2' else 'b7d6be7d85d83f878ffcaa06b8f2902de6ce1537710a59c444e28204646c2768'
    assert sha(package)==expected_pkg
    original = 16 if target=='g6lc64_smt2' else 0
    declared = original if depth==baseline else 2
    before=f"L2MshrDepth: unsigned'({original})"
    text=package.read_text()
    assert text.count(before)==1
    package.write_text(text.replace(before,f"L2MshrDepth: unsigned'({declared})"))
    cluster=repo/'corev_apu/src/g6lc_cluster.sv'
    text=cluster.read_text()
    marker='  // Silence unused'
    assert text.count(marker)==1
    cores,harts=(1,2) if target=='g6lc64_smt2' else (2,1)
    probe=f'''`ifndef SYNTHESIS
//pragma translate_off
  localparam int unsigned G6lcSizeExpected = {depth};
  initial begin
    if (!CVA6Cfg.L2En || CVA6Cfg.L2MshrDepth != G6lcSizeExpected ||
        CVA6Cfg.L2ByteSize != 262144 || CVA6Cfg.L2SetAssoc != 8 ||
        CVA6Cfg.L2DataBanks != 4 || CVA6Cfg.NrCores != {cores} || CVA6Cfg.NrHarts != {harts})
      $fatal(1, "L2SIZE_CONFIG_MISMATCH");
    $display("L2SIZE_CONFIG target={target} depth=%0d bytes=%0d ways=%0d banks=%0d cores=%0d harts=%0d", CVA6Cfg.L2MshrDepth, CVA6Cfg.L2ByteSize, CVA6Cfg.L2SetAssoc, CVA6Cfg.L2DataBanks, CVA6Cfg.NrCores, CVA6Cfg.NrHarts);
  end
//pragma translate_on
`endif
'''
    cluster.write_text(text.replace(marker,probe+'\n'+marker))
    return {'target':target,'baselineDepth':baseline,'effectiveDepth':depth,'declaredDepth':declared,'packageSha256':sha(package),'retainedRtl':pins}


def iq_ring_review():
    root = Path(os.environ['TH_RUN_DIR'])
    out = Path(os.environ['TH_OUT_DIR'])
    data = Path(os.environ['TH_DATA_DIR'])
    prior = Path('/opt/testharness/runs/review-runtime-operand-model-20260915/output')
    identity = json.loads((prior / 'model.json').read_text())
    runtime_info = identity['runtime']
    runtime = Path(runtime_info['privateRoot'])
    fixed_sha = 'dfbc2c4aa3c1065d4465027c893c9677de10da4cfe7fb152e485eb32b8125166'
    assert sha(runtime / 'include/verilated_funcs.h') == fixed_sha
    canaries_path = Path('/opt/testharness/runs/review-private-runtime-rebuild-20260915/output/canaries.json')
    assert [(r['tag'], r['rc']) for r in json.loads(canaries_path.read_text())] == [('original', 1), ('fixed', 0)]
    repo = root / 'repo'
    shutil.copytree(Path(identity['sourceRoot']), repo)
    sources = json.loads((prior / 'sources.json').read_text())
    for name, digest in sources.items():
        assert sha(repo / name) == digest, name
    original_iq = sha(repo / 'core/fetch_B/instr_queue.sv')
    assert original_iq == '1ba9488cd76aa8ba5e0e423a16fdf13d97049bb850b0b7fd33713c1f2b7681cd'
    shutil.copy2(data / 'instr_queue.sv', repo / 'core/fetch_B/instr_queue.sv')
    predictor_source = None
    if os.environ.get('REVIEW_PREDICTOR_INTEGRATION') == '1':
        predictor_output = Path('/opt/testharness/runs/review-predictor-absolute-sc-20260916/output')
        predictor_source = json.loads((predictor_output / 'model.json').read_text())
        assert predictor_source['predictorCandidate'] and predictor_source['absoluteCorrector']
        predictor_manifest = json.loads((predictor_output / 'sources.json').read_text())
        for name in ['core/fetch_B/frontend.sv', 'core/frontend/g6lc_bp_statcor.sv']:
            candidate = Path(predictor_source['sourceRoot']) / name
            assert sha(candidate) == predictor_manifest[name], name
            shutil.copy2(candidate, repo / name)
    l2_size = None
    if os.environ.get('REVIEW_L2_SMT_DEPTH'):
        l2_size = apply_l2_size_overlay(repo, data, 'g6lc64_smt2', int(os.environ['REVIEW_L2_SMT_DEPTH']))
        (out/'l2-size.json').write_text(json.dumps(l2_size,indent=2))
    core = repo / 'core/cva6.sv'
    text = core.read_text()
    old_include = str(Path(identity['sourceRoot']) / 'verif/tb/core/g6lc_operand_trace.svh')
    assert text.count(old_include) == 1
    core.write_text(text.replace(old_include, str(repo / 'verif/tb/core/g6lc_operand_trace.svh')))
    build_script = repo / 'verif/regress/soft-ladder-build-harness.sh'
    text = build_script.read_text()
    assert text.count('VLT_WRAP=/tmp/soft-ladder-vlt-wrap') == 1
    build_script.write_text(text.replace('VLT_WRAP=/tmp/soft-ladder-vlt-wrap', 'VLT_WRAP="$VERLIB_DIR/tool-wrap"'))
    suffixes = {'.sv', '.svh', '.v', '.vh', '.h', '.hpp', '.c', '.cpp', '.mk', '.sh', '.py', '.tcl', '.ld', '.S', '.f', '.bin'}
    def closure():
        return {str(p.relative_to(repo)): sha(p) for p in repo.rglob('*')
                if p.is_file() and '.git' not in p.relative_to(repo).parts
                and (p.suffix in suffixes or p.name == 'Makefile' or p.name.startswith('Flist'))}
    closed_inputs = closure()
    model = root / 'model'
    command = ['bash', '-c', '. /opt/testharness/env.sh; export VERILATOR_ROOT="$3" CVA6_REPO_DIR="$1" SOFT_LADDER_VERLIB="$2" SOFT_LADDER_VERILATOR_THREADS=1 SOFT_LADDER_BUILD_TARGET=g6lc64_smt2 SOFT_LADDER_BUILD_JOBS=4; bash verif/regress/soft-ladder-build-harness.sh B', 'iq-ring', str(repo), str(model), str(runtime)]
    with (out / 'build.log').open('w') as log:
        build = subprocess.run(command, cwd=repo, stdout=log, stderr=subprocess.STDOUT, timeout=900)
    assert build.returncode == 0, 'candidate integration build failed'
    assert closure() == closed_inputs, 'source changed during build'
    dependencies = '\n'.join(p.read_text(errors='replace') for p in model.glob('*.d'))
    assert str(runtime / 'include/verilated_funcs.h') in dependencies
    assert str(Path(runtime_info['originalRoot']) / 'include/verilated_funcs.h') not in dependencies
    exe = model / 'Variane_testharness'
    digest = sha(exe)
    (out / 'sources.json').write_text(json.dumps(closed_inputs, indent=2))
    (out / 'runtime.json').write_text(json.dumps(runtime_info, indent=2))
    shutil.copy2(canaries_path, out / 'canaries.json')
    (out / 'model.json').write_text(json.dumps({'exe': str(exe), 'sha256': digest, 'build': command, 'sourceRoot': str(repo), 'priorObserver': identity, 'originalIqSha256': original_iq, 'candidateIqSha256': sha(data / 'instr_queue.sv'), 'predictorSourceModel': predictor_source, 'l2Size': l2_size, 'strictQualification': False}, indent=2))
    checker_path = data / 'run_operand_analysis.py'
    assert sha(checker_path) == '316891982cef598aafb7b4465d538a4badca50bda3f9c843324f7691c9ac1f60'
    spec = importlib.util.spec_from_file_location('iq_reference', checker_path)
    checker = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(checker)
    pkg = (repo / 'core/include/g6lc64_smt2_config_pkg.sv').read_text()
    size = int(re.search(r'localparam CVA6ConfigDcacheByteSize = (\d+);', pkg)[1])
    ways = int(re.search(r'localparam CVA6ConfigDcacheSetAssoc = (\d+);', pkg)[1])
    assert size % ways == 0 and (size // ways) & ((size // ways) - 1) == 0
    index_bits = (size // ways).bit_length() - 1
    results = []
    def run_case(tag, elf, elf_sha, enabled, cap):
        assert sha(exe) == digest and sha(elf) == elf_sha
        work = out / tag
        work.mkdir()
        cmd = [str(exe), '-m', str(cap), '-s', '1', '+debug_disable']
        if enabled:
            cmd += ['+g6lc_operand_trace=1', '+g6lc_operand_trace_limit=' + str(cap)]
        cmd += [str(elf)]
        with (work / 'sim.log').open('w') as log:
            run = subprocess.run(cmd, cwd=work, env={'PATH': '/usr/bin:/bin', 'CVA6_TRACE_SPEC': 'exit cookie off=0x1000 val=1; exit cookie off=0x1000 val=3'}, stdout=log, stderr=subprocess.STDOUT, timeout=240)
        text = (work / 'sim.log').read_text(errors='replace')
        if l2_size:
            assert text.count(f"L2SIZE_CONFIG target=g6lc64_smt2 depth={l2_size['effectiveDepth']} bytes=262144 ways=8 banks=4 cores=1 harts=2") == 1
        cookies = re.findall(r'\[cookie-exit\] t=(\d+) \[1000\]=0x([0-9a-fA-F]+)', text)
        ok = run.returncode == 0 and len(cookies) == 1 and int(cookies[0][1], 16) == 1 and '%Error' not in text and 'Assertion failed' not in text
        trace = work / 'operand-trace-0.log'
        retirement = {p.name: sha(p) for p in work.glob('trace_hart_*.dasm')}
        assert retirement
        ok = ok and (trace.is_file() and '[ot-end]' in trace.read_text() if enabled else not trace.exists())
        assert sha(exe) == digest and sha(elf) == elf_sha
        record = {'tag': tag, 'status': 'pass' if ok else 'fail', 'rc': run.returncode, 'cookie': cookies, 'command': cmd, 'modelSha256': digest, 'elfSha256': elf_sha, 'retirement': retirement, 'traceSha256': sha(trace) if trace.exists() else None, 'runtimeHeaderSha256': fixed_sha, 'strictQualification': False}
        results.append(record)
        (out / 'results.json').write_text(json.dumps(results, indent=2))
        assert ok, record
        return record, work
    analyses = {}
    for encoding in ['rvi', 'rvc']:
        inputs_root = Path('/opt/testharness/runs/review-runtime-' + encoding + '-trace-20260915/output')
        inputs = json.loads((inputs_root / 'inputs.json').read_text())
        for role in ['positive', 'witness']:
            elf = inputs_root / 'positive.elf' if role == 'positive' else Path(inputs['witness'])
            elf_sha = inputs['positiveSha256'] if role == 'positive' else inputs['witnessSha256']
            off, _ = run_case(encoding + '-' + role + '-off', elf, elf_sha, False, 30000)
            on, work = run_case(encoding + '-' + role + '-on', elf, elf_sha, True, 30000)
            assert off['retirement'] == on['retirement'] and off['cookie'] == on['cookie']
            image = checker.image_words(inputs_root / (role + '.dis'))
            events = checker.read_events(work / 'operand-trace-0.log')
            analysis = checker.analyze(events, image, index_bits)
            analyses[encoding + '-' + role] = analysis
            (out / 'analysis.json').write_text(json.dumps(analyses, indent=2))
            assert analysis['status'] == 'pass' and not analysis['skipped'], analysis
            if role == 'positive':
                mutated = copy.deepcopy(events)
                next(e for e in mutated if e['kind'] == 'alu' and e['lane'] == 1)['a'] ^= 1
                negative = checker.analyze(mutated, image, index_bits)
                assert negative.get('contract') == 'execution-operand-a'
                analyses[encoding + '-negative'] = {'detected': negative['contract']}
            else:
                repeat, _ = run_case(encoding + '-witness-repeat', elf, elf_sha, True, 30000)
                assert repeat['traceSha256'] == on['traceSha256'] and repeat['retirement'] == on['retirement']
    for record in json.loads((prior / 'results.json').read_text()):
        if record['tag'] in ['redirect-chain', 'n2-48k-norvc', 'n2-48k-rvc']:
            run_case(record['tag'], Path(record['command'][-1]), record['elfSha256'], False, 1000000)
    assert closure() == closed_inputs
    (out / 'analysis.json').write_text(json.dumps(analyses, indent=2))


def main():
    if os.environ.get('REVIEW_IQ_RING') == '1': return iq_ring_review()
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
