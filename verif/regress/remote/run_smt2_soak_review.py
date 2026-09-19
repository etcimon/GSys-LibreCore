"""Source-bound, sequential SMT2 soak evidence; no implicit build or firmware edits.

Copyright (c) 2026 Etienne Cimon
SPDX-License-Identifier: MIT
"""

from collections import deque
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def capture(command):
    result = subprocess.run(command, capture_output=True, text=True, timeout=30)
    return {'rc': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr}


def check_fetch_b_sources(verfiles):
    if re.search(r'[/\\](?:fetch_A|smt_legacy)[/\\]|Flist\.smt_legacy', verfiles):
        raise RuntimeError('generated model includes an excluded legacy source path')
    if '/core/fetch_B/frontend.sv' not in verfiles.replace('\\', '/'):
        raise RuntimeError('generated model does not record the fetch_B frontend')


def balance_metrics(flow, symbols, active_harts=(0, 1), iterations=512):
    active = set(active_harts)
    if not active or not active <= {0, 1} or iterations <= 0:
        raise ValueError('invalid balance configuration')
    begin = {symbols[f'balance_begin{h}']: h for h in (0, 1)}
    end = {symbols[f'balance_end{h}']: h for h in (0, 1)}
    events = {h: [] for h in active}
    starts, ends, seen = {}, {}, set()
    last_cycle = -1
    pattern = re.compile(r'^\[smt-flow\] retire cycle=(\d+) port=(\d+) id=\d+ gen=\d+ '
                         r'hart=(\d+) pc=([0-9a-fA-F]+) valid=([01]) drop=([01]) ex=([01])$')
    for line in flow.splitlines():
        if not line.startswith('[smt-flow] retire '):
            continue
        match = pattern.fullmatch(line)
        if not match:
            raise ValueError('malformed retirement event')
        cycle, port, hart = map(int, match.group(1, 2, 3))
        pc = int(match[4], 16)
        if cycle < last_cycle or (cycle, port) in seen or hart not in (0, 1):
            raise ValueError('invalid retirement order, duplicate or hart')
        seen.add((cycle, port))
        last_cycle = cycle
        if match.group(5, 6, 7) != ('1', '0', '0'):
            continue
        if pc in begin or pc in end:
            owner = begin[pc] if pc in begin else end[pc]
            target = starts if pc in begin else ends
            if owner != hart or hart not in active or hart in target:
                raise ValueError('ROI marker ownership or multiplicity')
            target[hart] = cycle
        if symbols['balance_loop'] <= pc < symbols['balance_loop_end']:
            if hart not in active or hart not in starts or hart in ends:
                raise ValueError('work retired outside its owned ROI')
            events[hart].append((cycle, pc))
    if set(starts) != active or set(ends) != active:
        raise ValueError('missing ROI markers')
    expected_pcs = [symbols[name] for name in ('balance_loop', 'balance_xor', 'balance_dec', 'balance_branch')] * iterations
    for h in active:
        if ends[h] <= starts[h] or [pc for _, pc in events[h]] != expected_pcs:
            raise ValueError('incomplete, duplicated or reordered fixed work')
    left, right = max(starts.values()), min(ends.values())
    if right <= left:
        raise ValueError('no simultaneous-work interval')
    common = {h: [c for c, _ in events[h] if left <= c <= right] for h in active}
    if any(not cycles for cycles in common.values()):
        raise ValueError('no useful service for an active worker')
    total = sum(map(len, common.values()))
    durations = {h: ends[h] - starts[h] + 1 for h in active}
    return {'activeHarts': sorted(active), 'iterations': iterations,
            'roiCycles': durations, 'bodyRetirements': {h: len(events[h]) for h in active},
            'commonWindow': [left, right], 'commonCycles': right - left + 1,
            'commonBodyRetirements': {h: len(c) for h, c in common.items()},
            'commonRetirementShare': {h: len(c) / total for h, c in common.items()},
            'maxCommonRetirementGap': {h: max(b - a for a, b in zip(
                [left, *cycles], [*cycles, right])) for h, cycles in common.items()},
            'bodyIPC': {h: len(events[h]) / durations[h] for h in active},
            'saturationQualified': False, 'boundedFairnessProven': False,
            'scope': 'checked fixed-work retirement service, not cycle-by-cycle readiness or Linux'}


def activation_controls(model, data, out):
    startup = os.environ.get('SMT2_REVIEW_STARTUP') == '1'
    before = os.environ.get('SMT2_REVIEW_STARTUP_BEFORE') == '1'
    lrsc = os.environ.get('SMT2_REVIEW_LRSC') == '1'
    balance = os.environ.get('SMT2_REVIEW_BALANCE') == '1'
    if balance and (not startup or before or lrsc):
        raise ValueError('balance requires startup mode without before/LRSC')
    consumer = os.environ.get('SMT2_REVIEW_LRSC_CONSUMER', 'rs1')
    if lrsc and (not startup or consumer not in ('rs1', 'rs2', 'alu')):
        raise ValueError('LR/SC controls require startup mode and a supported consumer')
    original = (data / ('smt_dual_active.S' if startup else 'mini_ipi_hart1_sp.S')).read_text()
    linker = data / 'link_verilator.ld'
    cap = int(os.environ.get('SMT2_REVIEW_MINI_CYCLES', '250000' if startup and before else '30000'))
    arms = (('rvc',) if before else ('rvc', 'norvc', 'oracle-negative')) if startup else ('ipi', 'no-ipi')
    if balance:
        arms = ('rvc', 'norvc', 'solo0', 'solo1', 'oracle-negative')
    selected = os.environ.get('SMT2_REVIEW_STARTUP_ARM')
    if selected:
        if selected not in arms:
            raise ValueError('unknown startup arm')
        arms = (selected,)
    records = []
    for arm in arms:
        work = out / arm
        work.mkdir()
        text = ('#define SMT_BALANCE\n' if balance else '#define SMT_LRSC_DEP\n' if lrsc else '#define SMT_BOOT_RENDEZVOUS\n' if startup else '') + original
        if balance and arm.startswith('solo'):
            text = '#define SMT_BALANCE_SOLO ' + arm[-1] + '\n' + text
        if lrsc and consumer != 'rs1':
            text = '#define SMT_LRSC_' + consumer.upper() + '\n' + text
        if arm == 'norvc':
            text = '.option norvc\n' + text
        if arm == 'oracle-negative':
            text = '#define SMT_BOOT_FAULT\n' + text
        if arm == 'no-ipi':
            for store in ('  sw   t1, 0(t0)', '  sw   t1, 4(t0)'):
                if text.count(store) != 1:
                    raise RuntimeError('IPI control site changed')
                text = text.replace(store, '  .word 0x00000013')
        asm = work / 'mini.S'
        asm.write_text(text)
        elf = work / 'mini.elf'
        command = ['riscv-none-elf-gcc', '-march=rv64imafdc_zicsr', '-mabi=lp64d',
                   '-nostdlib', '-nostartfiles', '-Wl,--no-relax', '-T', str(linker),
                   '-o', str(elf), str(asm)]
        compilation = capture(command)
        (work / 'compile.json').write_text(json.dumps({'command': command, **compilation}, indent=2))
        if compilation['rc']:
            raise RuntimeError('activation mini did not compile')
        text_hash = None
        if balance:
            image = work / 'text.bin'
            copied = capture(['riscv-none-elf-objcopy', '-O', 'binary', '--only-section=.text', str(elf), str(image)])
            if copied['rc']:
                raise RuntimeError('cannot bind balance instruction image')
            text_hash = digest(image)
        symbols = capture(['riscv-none-elf-nm', '-n', str(elf)])
        symbol_map = {name: int(value, 16) for value, name in re.findall(
            r'^([0-9a-fA-F]+)\s+\w\s+(\w+)$', symbols['stdout'], re.M)}
        address = re.findall(r'^([0-9a-fA-F]+)\s+\w\s+tohost$', symbols['stdout'], re.M)
        if len(address) != 1:
            raise RuntimeError('activation mini tohost is not unique')
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(('SOFT_', 'PEEL_', 'CVA6_', 'G6LC_'))}
        env['CVA6_TRAP_DUMP'] = '1'
        log_path = work / 'run.log'
        command = [str(model), '--seed=1', f'+time_out={cap}', f'+max-cycles={cap}',
                   '+debug_disable', '+quiet_axi', '+smt_progress',
                   '+tohost_addr=0x' + address[0], str(elf)]
        if balance or os.environ.get('SMT2_REVIEW_STARTUP_FLOW') == '1':
            command.insert(-1, '+smt_flow_trace')
        with log_path.open('w') as log:
            result = subprocess.run(command, cwd=work, env=env,
                                    stdout=log, stderr=subprocess.STDOUT, timeout=180)
        log = log_path.read_text(errors='replace')
        (work / 'flow.log').write_text('\n'.join(line for line in log.splitlines() if line.startswith('[smt-flow]')))
        progress = {int(h): int(n) for h, n in re.findall(r'\[smt-progress\].*hart=(\d+) retired=(\d+)', log)}
        terminated = bool(re.search(r'\[rvfi_tracer\] INFO: Simulation terminated', log))
        matched = (result.returncode == 0 and terminated and progress.get(0, 0) > 0
                   and progress.get(1, 0) > 0 and 'sp1=0x80007000' in log) if arm == 'ipi' else (
                   result.returncode == 0 and not terminated and 'after 30000 cycles' in log
                   and progress.get(0, 0) > 0 and progress.get(1) == 0)
        if startup:
            if before:
                matched = (result.returncode == 0 and not terminated and f'after {cap} cycles' in log
                           and progress.get(0, 0) > 0 and progress.get(1) == 0)
            else:
                trace = '\n'.join(p.read_text() for p in work.glob('trace_rvfi_hart_*.dasm'))
                stores = re.findall(r'\bmem (0x[0-9a-fA-F]+) (0x[0-9a-fA-F]+)', trace)
                verdict = 3 if arm == 'oracle-negative' else 1
                matched = (terminated and progress.get(0, 0) > 0 and progress.get(1, 0) > 0
                           and any(int(a, 16) == int(address[0], 16) and int(v, 16) == verdict for a, v in stores)
                           and ((result.returncode != 0) if verdict == 3 else result.returncode == 0))
        record = {'arm': arm, 'lrscConsumer': consumer if lrsc else None,
                  'rc': result.returncode, 'retiredByHart': progress,
                  'pins': [line for line in log.splitlines() if line.startswith(('[hangpc]', '[smt-progress]'))],
                  'explicitTermination': terminated, 'matched': matched,
                  'elapsedVerdicts': re.findall(r'\*\*\* (?:SUCCESS|FAILED).*', log),
                  'sourceSha256': digest(asm), 'elfSha256': digest(elf), 'textSha256': text_hash,
                  'modelSha256': digest(model), 'logSha256': digest(log_path),
                  'scope': 'dual-runnable fixed-work baseline, not Linux or adaptive policy' if balance else 'directed LR/SC result dependency' if lrsc else 'directed reset rendezvous' if startup else 'directed IPI activation, not OpenSBI completion'}
        if balance and arm != 'oracle-negative':
            active = (int(arm[-1]),) if arm.startswith('solo') else (0, 1)
            publications = {(int(a, 16), int(v, 16)) for a, v in re.findall(
                r'^3 .*?\bmem (0x[0-9a-fA-F]+) (0x[0-9a-fA-F]+)\s*$', trace, re.M)}
            expected = {(symbol_map['balance_state'] + h * 64 + offset, value)
                        for h in active for offset, value in ((8, 512 * (h + 1)), (16, 1))}
            record['publicationsChecked'] = expected <= publications
            record['matched'] = record['matched'] and record['publicationsChecked']
            try:
                record['balanceMetrics'] = balance_metrics(log, symbol_map, active)
            except ValueError as error:
                record.update(matched=False, metricsError=str(error))
            if arm == 'rvc' and record['matched']:
                quiet = work / 'observer-off'
                quiet.mkdir()
                off_command = [argument for argument in command if argument != '+smt_flow_trace']
                with (quiet / 'run.log').open('w') as output:
                    off = subprocess.run(off_command, cwd=quiet, env=env, stdout=output,
                                         stderr=subprocess.STDOUT, timeout=180)
                off_log = (quiet / 'run.log').read_text(errors='replace')
                on_traces = sorted(work.glob('trace_rvfi_hart_*.dasm'))
                off_traces = sorted(quiet.glob('trace_rvfi_hart_*.dasm'))
                equivalent = (off.returncode == result.returncode and len(on_traces) == len(off_traces) == 1
                              and digest(on_traces[0]) == digest(off_traces[0])
                              and '[rvfi_tracer] INFO: Simulation terminated' in off_log
                              and re.findall(r'\*\*\* (?:SUCCESS|FAILED).*', off_log) == record['elapsedVerdicts'])
                record['observerEquivalent'] = equivalent
                record['matched'] = record['matched'] and equivalent
        records.append(record)
        (out / 'activation-results.json').write_text(json.dumps(records, indent=2) + '\n')
        print(json.dumps(record), flush=True)
    if balance:
        arms_by_name = {r['arm']: r for r in records}
        required = ('rvc', 'solo0', 'solo1')
        summary = {'pairedSoloComparisonAvailable': False, 'adaptivePolicyImplemented': False,
                   'linuxQualified': False, 'saturationQualified': False}
        if all(name in arms_by_name and arms_by_name[name]['matched'] for name in required):
            if len({arms_by_name[name]['textSha256'] for name in required}) != 1:
                raise RuntimeError('solo and shared instruction images differ')
            shared = arms_by_name['rvc']['balanceMetrics']['bodyIPC']
            relative = {h: shared[h] / arms_by_name[f'solo{h}']['balanceMetrics']['bodyIPC'][h] for h in (0, 1)}
            summary.update(pairedSoloComparisonAvailable=True, identicalInstructionImage=True,
                           relativePerHartIPC=relative, weightedSpeedup=sum(relative.values()),
                           worstHartSlowdown=max(1 / value for value in relative.values()))
        (out / 'balance-summary.json').write_text(json.dumps(summary, indent=2))
    return 0 if all(r['matched'] for r in records) else 1


def main():
    import resource

    repo = Path(os.environ.get('TH_REPO_DIR', '/opt/testharness/repo')).resolve()
    out = Path(os.environ['TH_OUT_DIR']).resolve()
    out.mkdir(parents=True, exist_ok=True)
    model = Path(os.environ['SMT2_REVIEW_MODEL']).resolve()
    elf = Path(os.environ['SMT2_REVIEW_ELF']).resolve()
    driver = repo / 'verif/regress/soft-ladder-opensbi-soak.sh'
    inspect = os.environ.get('SMT2_REVIEW_INSPECT') == '1'
    evidence = {'model': str(model), 'elf': str(elf), 'inspectOnly': inspect,
                'runnerSha256': digest(Path(__file__))}
    for name, path in [('model', model), ('elf', elf), ('driver', driver)]:
        if not path.is_file():
            raise RuntimeError(f'missing {name}: {path}')
        evidence[name + 'Sha256'] = digest(path)
    evidence['symbols'] = capture(['riscv-none-elf-nm', '-n', str(elf)])
    (out / 'symbols.txt').write_text(evidence['symbols']['stdout'])
    disasm_start = int(os.environ.get('SMT2_REVIEW_DISASM_START', '0x80012550'), 0)
    disasm_end = int(os.environ.get('SMT2_REVIEW_DISASM_END', '0x800125c0'), 0)
    if not 0 <= disasm_start < disasm_end <= disasm_start + 65536:
        raise ValueError('invalid bounded disassembly interval')
    evidence['pinDisassembly'] = capture([
        'riscv-none-elf-objdump', '-d', f'--start-address={disasm_start}',
        f'--stop-address={disasm_end}', str(elf)])
    metadata = {}
    for name in ('build.log', '.soft-ladder-flavour', 'Variane_testharness__verFiles.dat',
                 'Variane_testharness.mk'):
        path = model.parent / name
        if path.is_file():
            text = path.read_text(errors='replace')
            metadata[name] = {'sha256': digest(path), 'lines': [line for line in text.splitlines()
                if any(word in line for word in ('--threads', 'VERILATOR_ROOT', 'flavour', 'vthreads='))][:12]}
    evidence['buildMetadata'] = metadata
    dependencies = '\n'.join(p.read_text(errors='replace') for p in model.parent.glob('*.d'))
    evidence['compiledRuntimeHeaders'] = sorted(set(re.findall(r'\S+/include/verilated_funcs\.h', dependencies)))
    evidence['versions'] = {tool: capture([tool, '--version']) for tool in ('verilator', 'riscv-none-elf-gcc')}
    runtime_record = Path('/opt/testharness/runs/review-cacheability-pair-20260916/output/runtime.json')
    if runtime_record.is_file():
        runtime = json.loads(runtime_record.read_text())
        evidence['recordedRuntime'] = runtime
        evidence['runtimeHeaders'] = {}
        for key in ('privateRoot', 'originalRoot'):
            header = Path(runtime[key]) / 'include/verilated_funcs.h'
            evidence['runtimeHeaders'][key] = {'path': str(header), 'sha256': digest(header)}
    canaries = Path('/opt/testharness/runs/review-private-runtime-rebuild-20260915/output/canaries.json')
    if canaries.is_file():
        evidence['recordedCanaries'] = json.loads(canaries.read_text())
    (out / 'audit.json').write_text(json.dumps(evidence, indent=2) + '\n')
    print(json.dumps({k: v for k, v in evidence.items()
                      if k not in ('symbols', 'versions', 'pinDisassembly')}, indent=2), flush=True)
    print(evidence['pinDisassembly']['stdout'], flush=True)
    if inspect:
        trace_root = os.environ.get('SMT2_REVIEW_TRACE_ROOT')
        if trace_root:
            tails = {}
            pattern = os.environ.get('SMT2_REVIEW_TRACE_FILTER', '').replace(',', '|')
            for path in sorted(Path(trace_root).glob('trace_rvfi_hart_*.dasm')):
                tail = deque(maxlen=min(2000, max(1, int(os.environ.get('SMT2_REVIEW_TRACE_TAIL_LINES', '24')))))
                match_limit = min(2000, max(1, int(os.environ.get('SMT2_REVIEW_TRACE_MATCH_LIMIT', '80'))))
                match_tail = os.environ.get('SMT2_REVIEW_TRACE_MATCH_TAIL') == '1'
                matches = deque(maxlen=match_limit)
                match_count = number = 0
                with path.open(errors='replace') as fh:
                    for number, line in enumerate(fh, 1):
                        tail.append(line)
                        subject = line
                        if os.environ.get('SMT2_REVIEW_TRACE_PC_ONLY') == '1':
                            fields = line.split()
                            subject = fields[1] if len(fields) > 1 and fields[0] in ('0', '1', '2', '3') else ''
                        if pattern and re.search(pattern, subject):
                            match_count += 1
                            if match_tail or len(matches) < match_limit:
                                matches.append({'line': number, 'text': line.rstrip()})
                tails[path.name] = {'sha256': digest(path), 'lines': number, 'matchCount': match_count,
                                    'tail': list(tail), 'matches': list(matches)}
                if path.stat().st_size <= 8_000_000:
                    shutil.copy2(path, out / path.name)
            (out / 'trace-tails.json').write_text(json.dumps(tails, indent=2) + '\n')
            flow_pattern = os.environ.get('SMT2_REVIEW_FLOW_FILTER', '').replace(',', '|')
            log_tails = {}
            for path in sorted([*Path(trace_root).glob('veri_B_*.log'), *Path(trace_root).glob('run.log')]):
                log_tail = deque(maxlen=60)
                flow = []
                with path.open(errors='replace') as fh:
                    for line in fh:
                        log_tail.append(line.rstrip())
                        if line.startswith('[smt-flow]') and (not flow_pattern or re.search(flow_pattern, line)):
                            flow.append(line)
                log_tails[path.name] = list(log_tail)
                (out / 'flow.log').write_text(''.join(flow))
            (out / 'log-tails.json').write_text(json.dumps(log_tails, indent=2))
        return 0

    data = Path(os.environ['TH_DATA_DIR'])
    manifest = json.loads((data / 'build-manifest.json').read_text())
    if manifest['executableSha256'] != evidence['modelSha256']:
        raise RuntimeError('model does not match the uploaded build manifest')
    if manifest['configuration']['flavour'] != 'B' or manifest['target'] != 'g6lc64_smt2':
        raise RuntimeError('expected a fetch_B SMT2 build manifest')
    verfiles = (model.parent / 'Variane_testharness__verFiles.dat').read_text()
    if not re.search(r'--threads\s+1(?:\s|["\'])', verfiles):
        raise RuntimeError('generated model does not record --threads 1')
    check_fetch_b_sources(verfiles)
    runtime_hash = os.environ['SMT2_REVIEW_RUNTIME_SHA256']
    if not evidence['compiledRuntimeHeaders'] or any(
            digest(Path(path)) != runtime_hash for path in evidence['compiledRuntimeHeaders']):
        raise RuntimeError('compiler dependencies do not match the expected runtime header')
    expected_elf = os.environ['SMT2_REVIEW_ELF_SHA256']
    if evidence['elfSha256'] != expected_elf:
        raise RuntimeError('payload changed since inspection')
    symbols = re.findall(r'^([0-9a-fA-F]+)\s+\w\s+tohost$',
                         evidence['symbols']['stdout'], re.M)
    if len(symbols) != 1:
        raise RuntimeError('expected one tohost symbol')
    if capture(['pgrep', '-af', '[/]Variane_testharness( |$)'])['rc'] != 1:
        raise RuntimeError('another harness is running or process check failed')
    resource.setrlimit(resource.RLIMIT_STACK, (resource.RLIM_INFINITY, resource.RLIM_INFINITY))
    if os.environ.get('SMT2_REVIEW_ACTIVATION') == '1' or os.environ.get('SMT2_REVIEW_STARTUP') == '1':
        result = activation_controls(model, data, out)
        if digest(model) != evidence['modelSha256']:
            raise RuntimeError('activation model changed during the controls')
        return result
    inputs = out / 'inputs'
    inputs.mkdir()
    frozen_elf = inputs / elf.name
    frozen_model = inputs / 'Variane_testharness'
    frozen_driver = inputs / driver.name
    for source, dest in ((elf, frozen_elf), (model, frozen_model), (driver, frozen_driver),
                         (data / 'build-manifest.json', inputs / 'build-manifest.json')):
        shutil.copy2(source, dest)
    canary_source = Path('/opt/testharness/runs/review-private-runtime-20260915/output/constant_canary.cpp')
    canary_results = []
    for label, root_key, expected in [('original', 'originalRoot', 1), ('fixed', 'privateRoot', 0)]:
        executable = out / ('canary-' + label)
        compilation = capture(['g++', '-std=c++17', '-O2',
                               '-I' + evidence['recordedRuntime'][root_key] + '/include',
                               str(canary_source), '-o', str(executable)])
        if compilation['rc'] != 0:
            raise RuntimeError(compilation)
        observed = capture([str(executable)])
        canary_results.append({'label': label, 'sourceSha256': digest(canary_source), **observed})
        if observed['rc'] != expected or 'wide-constant canary failures=' not in observed['stdout']:
            raise RuntimeError(f'runtime control did not match: {observed}')
    (out / 'runtime-controls.json').write_text(json.dumps(canary_results, indent=2) + '\n')
    records = []
    cap = int(os.environ.get('SMT2_REVIEW_CYCLES', '12000000'))
    repeats = int(os.environ.get('SMT2_REVIEW_REPEATS', '3'))
    if cap <= 0 or not 1 <= repeats <= 3:
        raise ValueError('positive cycle cap and 1..3 repeats required')
    observer = os.environ.get('SMT2_REVIEW_OBSERVER', 'off')
    observer_args = {'off': '', 'i1': ',+fetch_i1_check', 'flow': ',+smt_flow_trace',
                     'progress': ',+smt_progress'}
    if observer not in observer_args:
        raise ValueError('observer must be off, i1, flow or progress')
    plusargs = '--seed=1' + observer_args[observer]
    for repeat in range(repeats):
        trial = out / f'trial-{repeat}'
        trial.mkdir()
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(('SOFT_', 'PEEL_', 'CVA6_', 'G6LC_'))}
        env.update({'SOFT_LADDER_FETCH': 'B', 'SOFT_LADDER_SKIP_BUILD': '1',
                    'SOFT_LADDER_HARNESS': str(inputs), 'SOFT_LADDER_ELF': str(frozen_elf),
                    'SOFT_LADDER_OSBI_OUT': str(trial), 'SOFT_LADDER_TIME_OUT': str(cap),
                    'SOFT_LADDER_TOHOST': '0x' + symbols[0], 'SOFT_LADDER_PLUSARGS': plusargs,
                    'SOFT_LADDER_WALL_TIMEOUT': '900', 'CVA6_TRAP_DUMP': '1',
                    'CVA6_COOKIE_EXIT': '1', 'CVA6_SOAK_EXIT': '0',
                    'G6LC_RUN_ID': f'{out.parent.name}-trial-{repeat}'})
        print(f'SMT2_REVIEW start trial={repeat} cycles={cap}', flush=True)
        with (trial / 'driver.log').open('w') as log:
            result = subprocess.run(['bash', str(frozen_driver)], cwd=repo, env=env,
                                    stdout=log, stderr=subprocess.STDOUT, timeout=960)
        logs = list(trial.glob('veri_B_*.log'))
        if len(logs) != 1:
            raise RuntimeError(f'trial {repeat}: expected one simulation log')
        text = logs[0].read_text(errors='replace')
        driver_text = (trial / 'driver.log').read_text(errors='replace')
        pins = [line for line in text.splitlines() if line.startswith(
            ('[trapdump]', '[hangpc]', '[cookie-exit]', '[mc_gap]', '*** [mc_gap]', '*** [mc_verdict]'))]
        status = re.findall(r'CLASSIFY=(\w+).*?rc=(-?\d+)', driver_text)
        (trial / 'flow.log').write_text('\n'.join(line for line in text.splitlines()
                                                 if line.startswith('[smt-flow]')) + '\n')
        checks = [line for line in text.splitlines() if line.startswith('[fetch-i1]')]
        observed = any(line.startswith('[trapdump]') for line in pins) and any(
            line.startswith('[hangpc]') for line in pins)
        record = {'trial': repeat, 'driverRc': result.returncode, 'classification': status,
                  'observer': observer, 'plusargs': plusargs, 'observationPresent': observed,
                  'supplyChecks': checks if len(checks) <= 20 else checks[:20] + checks[-1:],
                  'hartProgress': [line for line in text.splitlines() if line.startswith('[smt-progress]')],
                  'pins': pins, 'logSha256': digest(logs[0]), 'cycleCap': cap,
                  'elapsedVerdicts': re.findall(r'\*\*\* (?:SUCCESS|FAILED).*', text),
                  'cookieGreen': result.returncode == 0 and len(status) == 1 and status[0][0] == 'SUCCESS'}
        records.append(record)
        (out / 'results.json').write_text(json.dumps(records, indent=2) + '\n')
        print(json.dumps(record), flush=True)
    for name, path in [('model', frozen_model), ('elf', frozen_elf), ('driver', frozen_driver)]:
        if digest(path) != evidence[name + 'Sha256']:
            raise RuntimeError(f'{name} changed during repeats')
    stable = all((r['pins'], r['elapsedVerdicts'], r['classification']) ==
                 (records[0]['pins'], records[0]['elapsedVerdicts'], records[0]['classification']) for r in records)
    summary = {'repeats': repeats, 'observer': observer,
               'sameObservedSignature': repeats > 1 and stable and all(r['observationPresent'] for r in records),
               'cookieGreen': all(r['cookieGreen'] for r in records),
               'perHartLivenessQualified': False, 'causalAttribution': False}
    (out / 'review-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print('SMT2_REVIEW ' + json.dumps(summary), flush=True)
    return 0 if summary['cookieGreen'] else 1


if __name__ == '__main__':
    sys.exit(main())
