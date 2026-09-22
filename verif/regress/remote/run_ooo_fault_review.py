"""Extract bounded, identity-bearing fault context from a frozen firmware run.

Copyright (c) 2026 Etienne Cimon
SPDX-License-Identifier: MIT
"""
from collections import deque
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def fault_context(lines):
    recent = deque(maxlen=24)
    tail_by_hart = {}
    counts = {}
    contexts = []
    pending = 0
    for number, line in enumerate(lines, 1):
        row = line.rstrip()
        if row.startswith('[smt-flow] retire '):
            fields = dict(re.findall(r'(\w+)=(\S+)', row))
            if fields.get('drop') == '0':
                hart = int(fields['hart'])
                tail_by_hart.setdefault(hart, deque(maxlen=24)).append(row)
                counts[hart] = counts.get(hart, 0) + 1
        event = (row.startswith('[smt-flow] wb ') and ' ex=1' in row) or (
            row.startswith('[smt-flow] control ') and
            'resolve=1 mispredict=1 target=0000000000000000' in row)
        if event and len(contexts) < 32:
            contexts.append({'line': number, 'before': list(recent), 'event': row, 'after': []})
            pending = 12
        elif pending:
            contexts[-1]['after'].append(row)
            pending -= 1
        if row.startswith(('[smt-flow] ', '[smt-flow] operands')) and 'wt_lookup' not in row:
            recent.append(row)
    return {'retiredByHart': counts, 'lastRetirements': {h: list(v) for h, v in tail_by_hart.items()},
            'faultCandidates': contexts,
            'scope': 'Observed writeback exceptions and zero-target resolves, not all committed traps'}


def run_leaf():
    out, data = Path(os.environ['TH_OUT_DIR']), Path(os.environ['TH_DATA_DIR'])
    repo = Path('/opt/testharness/repo')
    runtime = Path('/opt/testharness/runs/review-private-runtime-20260915/runtime')
    if sha(runtime / 'include/verilated_funcs.h') != 'dfbc2c4aa3c1065d4465027c893c9677de10da4cfe7fb152e485eb32b8125166':
        raise ValueError('unqualified runtime')
    source = out / 'source'
    source.mkdir()
    paths = [repo / 'core/include/config_pkg.sv', repo / 'core/include/g6lc64_smt2_config_pkg.sv',
             repo / 'core/include/riscv_pkg.sv', repo / 'core/include/ariane_pkg.sv',
             repo / 'vendor/pulp-platform/common_cells/src/cf_math_pkg.sv',
             repo / 'vendor/pulp-platform/common_cells/src/lzc.sv',
             data / 'lsu_bypass.sv', data / 'load_unit.sv']
    hashes = {}
    for path in paths:
        (source / path.name).write_bytes(path.read_bytes())
        hashes[path.name] = sha(path)
    bench = (data / 'tb_g6lc_rtl_review.sv').read_text()
    top = 'tb_g6lc_review_load_cancel'
    bench = 'module ' + top + ';' + bench.split('module ' + top + ';', 1)[1].split('endmodule', 1)[0] + 'endmodule\n'
    (source / 'bench.sv').write_text(bench)
    hashes['bench.sv'] = sha(source / 'bench.sv')
    before = os.environ.get('FAULT_REVIEW_BEFORE') == '1'
    mutation = os.environ.get('FAULT_REVIEW_MUTATE_QUEUED_CANCEL') == '1'
    if mutation:
        path = source / 'lsu_bypass.sv'
        text = path.read_text()
        old = "          mem_n[i].is_speculative_load_miss = 1'b1;"
        if text.count(old) != 1:
            raise ValueError('queued-cancellation mutation site changed')
        path.write_text(text.replace(old, "          mem_n[i].is_speculative_load_miss = 1'b0;"))
    # Precise-misalignment mutations: 'kill' keeps the D$ request alive after the
    # exception (a late data completion must be caught); 'ex' drops the exception
    # completion itself (the load would retire silently).
    misalign_mutation = os.environ.get('FAULT_REVIEW_MUTATE_MISALIGN')
    if misalign_mutation:
        path = source / 'load_unit.sv'
        text = path.read_text()
        old, new = {
            'kill': ("        if (ex_i.valid) begin\n          req_port_o.kill_req = 1'b1;\n        end\n",
                     "        if (ex_i.valid) begin\n          req_port_o.kill_req = 1'b0;\n        end\n"),
            'ex': ("        valid_o    = 1'b1;\n        ex_o.valid = 1'b1;\n      end\n    end\n",
                   "        valid_o    = 1'b1;\n        ex_o.valid = 1'b0;\n      end\n    end\n"),
        }[misalign_mutation]
        if text.count(old) != 1:
            raise ValueError('misalignment mutation site changed')
        path.write_text(text.replace(old, new))
    pins = {'sources': hashes, 'before': before, 'queuedCancelMutation': mutation, 'misalignMutation': misalign_mutation,
            'compiledSources': {p.name: sha(p) for p in source.glob('*.sv')},
            'runnerSha256': sha(Path(__file__)),
            'compilerControlSha256': sha(Path('/opt/testharness/runs/pmp-transition-split-20260919/output/source/split-counter.vlt')),
            'runtimeSha256': sha(runtime / 'include/verilated_funcs.h')}
    (out / 'inputs.json').write_text(json.dumps(pins, indent=2))
    env = dict(os.environ, VERILATOR_ROOT=str(runtime))
    records = []
    for ooo, nload, mmu in ([(1, 4, 0)] if before or mutation else [(1, 4, 1), (0, 4, 1)] if misalign_mutation else [(1, 2, 0), (1, 4, 1), (0, 4, 1)]):
        work = out / f'ooo{ooo}-loads{nload}-mmu{mmu}'
        work.mkdir()
        model = work / 'model'
        ports = ['-DG6LC_REVIEW_CANCEL_PORT'] if 'cancelled_mask_i' in (source / 'lsu_bypass.sv').read_text() else []
        command = ['verilator', '--cc', '--main', '--exe', '--timing', '--assert', '--threads', '1',
                   '-Wno-fatal', '-Werror-LATCH', '-Werror-UNOPTFLAT', *ports,
                   '/opt/testharness/runs/pmp-transition-split-20260919/output/source/split-counter.vlt',
                   '--top-module', top, f'-GOOO={ooo}', f'-GNLOAD={nload}', f'-GMMU={mmu}',
                   '--Mdir', str(model), '-o', 'review-test',
                   *[str(source / p.name) for p in paths], str(source / 'bench.sv')]
        for name, cmd in [('verilate', command), ('build', ['make', '-C', str(model), '-f', f'V{top}.mk', '-j4'])]:
            (work / f'{name}-command.json').write_text(json.dumps(cmd, indent=2))
            with (work / f'{name}.log').open('w') as log:
                result = subprocess.run(cmd, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=180)
            if result.returncode:
                raise RuntimeError(f'{name} failed: {work}')
        deps = '\n'.join(p.read_text() for p in model.glob('*.d'))
        if str(runtime / 'include/verilated_funcs.h') not in deps:
            raise ValueError('compiled runtime identity missing')
        scenarios = [1] if mutation else [13] if misalign_mutation else [0, 4, 6] if before else list(range(14)) if ooo and mmu else list(range(8)) + [10, 11] if ooo else [2, 3, 4, 5, 6, 13]
        for case in scenarios:
            for negative in ([False] if before or mutation or misalign_mutation else [False, True]):
                cmd = [str(model / 'review-test'), f'+scenario={case}'] + (['+oracle_negative'] if negative else [])
                result = subprocess.run(cmd, cwd=work, capture_output=True, text=True, timeout=15)
                text = result.stdout + result.stderr
                (work / f'case{case}-negative{int(negative)}.log').write_text(text)
                expected = ('LOAD_CANCEL_STALE_REQUEST' if (before and case == 0) or mutation else
                            {'kill': 'misaligned load buffer entry did not complete with LD_ADDR_MISALIGNED and a killed request',
                             'ex': 'LOAD_MISALIGN_DATA_COMPLETION'}[misalign_mutation] if misalign_mutation else
                            'LOAD_MISALIGN_EXCEPTION' if negative and case == 13 else
                            'LOAD_CANCEL_RESPONSE' if negative else None)
                matched = (result.returncode != 0 and expected in text and 'LOAD_CANCEL_PASS' not in text) if expected else (
                    result.returncode == 0 and text.count('LOAD_CANCEL_PASS') == 1 and '%Error' not in text)
                records.append({'ooo': ooo, 'loads': nload, 'mmu': mmu, 'scenario': case, 'negative': negative,
                                'expectedError': expected, 'rc': result.returncode, 'matched': matched,
                                'modelSha256': sha(model / 'review-test')})
                (out / 'results.json').write_text(json.dumps(records, indent=2))
                if not matched:
                    raise RuntimeError(f'leaf mismatch: {records[-1]}')
    print(json.dumps(records, indent=2))


def run_formal():
    data, out = Path(os.environ['TH_DATA_DIR']), Path(os.environ['TH_OUT_DIR'])
    source = out / 'source'
    source.mkdir()
    repo = Path('/opt/testharness/repo/core/include')
    names = ['config_pkg.sv', 'g6lc64_smt2_config_pkg.sv', 'riscv_pkg.sv', 'ariane_pkg.sv']
    for name in names:
        (source / name).write_bytes((repo / name).read_bytes())
    names.append('lsu_bypass.sv')
    text = (data / 'lsu_bypass.sv').read_text()
    mutation = os.environ.get('FAULT_REVIEW_MUTATE_QUEUED_CANCEL') == '1'
    if mutation:
        old = "          mem_n[i].is_speculative_load_miss = 1'b1;"
        if text.count(old) != 1:
            raise ValueError('formal mutation site changed')
        text = text.replace(old, "          mem_n[i].is_speculative_load_miss = 1'b0;")
    (source / names[-1]).write_text(text)
    bench = (data / 'tb_g6lc_rtl_review.sv').read_text()
    top = 'tb_g6lc_review_load_cancel_props'
    bench = 'module ' + top + bench.split('module ' + top, 1)[1].split('endmodule', 1)[0] + 'endmodule\n'
    (source / 'props.sv').write_text(bench)
    names.append('props.sv')
    (out / 'sources.json').write_text(json.dumps({name: sha(source / name) for name in names}, indent=2))
    common = ('read_slang --std 1800-2017 --top ' + top + ' -DFORMAL ' +
              ' '.join(str(source / name) for name in names) +
              '\nprep -top ' + top + '\nasync2sync\nflatten\nchformal -lower\nmemory_map\nopt\n')
    records = []
    for mode in (['mutation'] if mutation else ['prove', 'cover']):
        witness = out / f'{mode}-witness.json'
        script = out / f'{mode}.ys'
        goal = '-prove seen_drain 0' if mode == 'cover' else '-prove-asserts'
        script.write_text(common + f'sat -seq 8 -set-assumes {goal} -verify -show-ports -dump_json {witness}\n')
        with (out / f'{mode}.log').open('w') as log:
            rc = subprocess.run(['yosys', '-s', str(script)], stdout=log, stderr=subprocess.STDOUT, timeout=180).returncode
        text = (out / f'{mode}.log').read_text()
        matched = (rc == 0 and 'no model found: SUCCESS!' in text) if mode == 'prove' else (
            rc != 0 and 'model found: FAIL!' in text and witness.is_file())
        records.append({'mode': mode, 'depth': 8, 'rc': rc, 'matched': matched,
                        'scope': 'live two-entry bypass, four TIDs, independent shift-queue reference; not full LSU proof'})
        (out / 'results.json').write_text(json.dumps(records, indent=2))
        if not matched:
            raise RuntimeError(f'formal mismatch: {mode}')
    print(json.dumps(records, indent=2))


def run_age_formal():
    data, out = Path(os.environ['TH_DATA_DIR']), Path(os.environ['TH_OUT_DIR'])
    source = out / 'source'
    source.mkdir()
    names = ['config_pkg.sv', 'g6lc_ooo_pkg.sv', 'g6lc_lsq.sv', 'g6lc_ooo_age_props.sv']
    mutation = os.environ.get('AGE_FORMAL_MUTATE') == '1'
    for name in names:
        text = (data / name).read_text()
        if mutation and name == 'g6lc_lsq.sv':
            old = "    mem_violation_o = |viol_cand;"
            if text.count(old) != 1:
                raise ValueError('age formal mutation site changed')
            text = text.replace(old, "    mem_violation_o = 1'b0;")
        (source / name).write_text(text)
    (out / 'sources.json').write_text(json.dumps({name: sha(source / name) for name in names}, indent=2))
    top = 'g6lc_ooo_age_props'
    depth = int(os.environ.get('AGE_FORMAL_DEPTH', '14'))
    common = ('read_slang --std 1800-2017 --top ' + top + ' -DFORMAL ' +
              ' '.join(str(source / name) for name in names) +
              '\nprep -top ' + top + '\nasync2sync\nflatten\nchformal -cover -remove\nchformal -lower\nmemory_map\nopt\n' +
              'select -assert-min 1 t:$assert\n')
    records = []
    for mode in (['mutation'] if mutation else ['prove', 'cover']):
        witness = out / f'{mode}-witness.json'
        script = out / f'{mode}.ys'
        goal = '-prove viol 0' if mode == 'cover' else '-prove-asserts'
        script.write_text(common + f'sat -seq {depth} -set-assumes {goal} -verify -show-ports -dump_json {witness}\n')
        with (out / f'{mode}.log').open('w') as log:
            rc = subprocess.run(['yosys', '-s', str(script)], stdout=log, stderr=subprocess.STDOUT,
                                timeout=int(os.environ.get('AGE_FORMAL_TIMEOUT', '900'))).returncode
        text = (out / f'{mode}.log').read_text()
        asserts_present = 'select -assert-min' not in text or 'Assertion failed' not in text
        matched = asserts_present and ((rc == 0 and 'no model found: SUCCESS!' in text) if mode == 'prove' else (
            rc != 0 and 'model found: FAIL!' in text and witness.is_file()))
        records.append({'mode': mode, 'depth': depth, 'rc': rc, 'matched': matched, 'assertsPresent': asserts_present,
                        'scope': 'live g6lc_lsq (2 ld / 2 st, 8 slots) under a scoreboard window model: age key equals '
                                 'allocation order, violation scan complete/sound/oldest; not a full LSU or core proof'})
        (out / 'results.json').write_text(json.dumps(records, indent=2))
        if not matched:
            raise RuntimeError(f'age formal mismatch: {mode}')
    print(json.dumps(records, indent=2))


def run_synth():
    data, out = Path(os.environ['TH_DATA_DIR']), Path(os.environ['TH_OUT_DIR'])
    source = out / 'source'
    source.mkdir()
    repo = Path('/opt/testharness/repo')
    files = [repo / 'core/include/config_pkg.sv', repo / 'core/include/g6lc64_smt2_config_pkg.sv',
             repo / 'core/include/riscv_pkg.sv', repo / 'core/include/ariane_pkg.sv',
             repo / 'vendor/pulp-platform/common_cells/src/cf_math_pkg.sv',
             repo / 'vendor/pulp-platform/common_cells/src/lzc.sv',
             data / 'lsu_bypass.sv', data / 'load_unit.sv']
    for path in files:
        (source / path.name).write_bytes(path.read_bytes())
    bench = (data / 'tb_g6lc_rtl_review.sv').read_text().split('module tb_g6lc_review_load_cancel;', 1)[1]
    definitions = bench[bench.index('  parameter bit'):bench.index('  logic clk=')].replace('parameter bit MMU=0', 'parameter bit MMU=1')
    results = []
    for unit in ('load_unit', 'lsu_bypass'):
        top = 'g6lc_live_' + unit
        ports = (source / (unit + '.sv')).read_text().split(') (', 1)[1].split('\n);', 1)[0]
        for old, new in [('CVA6Cfg', 'C'), ('dcache_req_i_t', 'req_t'), ('dcache_req_o_t', 'resp_t'),
                         ('lsu_ctrl_t', 'ctrl_t'), ('bp_resolve_t', 'branch_t')]:
            ports = ports.replace(old, new)
        bindings = ('.dcache_req_i_t(req_t),.dcache_req_o_t(resp_t),.exception_t(exception_t),.lsu_ctrl_t(ctrl_t)' if unit == 'load_unit' else
                    '.lsu_ctrl_t(ctrl_t),.bp_resolve_t(branch_t)')
        wrapper = source / (top + '.sv')
        wrapper.write_text('package g6lc_load_review_types;\nimport ariane_pkg::*;\n' + definitions +
                           '\nendpackage\nmodule ' + top + ' import g6lc_load_review_types::*; (\n' + ports +
                           '\n);\n' + unit + ' #(.CVA6Cfg(C),' + bindings + ') dut(.*);\nendmodule\n')
        script = out / (unit + '.ys')
        script.write_text('read_slang --std 1800-2017 --top ' + top + ' ' +
                          ' '.join(str(source / p.name) for p in files) + ' ' + str(wrapper) +
                          '\nsynth -top ' + top + '\ncheck -assert\n' +
                          'select -assert-none t:$dlatch t:$_DLATCH_*\nscc -expect 0\n' +
                          f'tee -o {out}/{unit}-stats.json stat -json\n')
        with (out / (unit + '.log')).open('w') as log:
            rc = subprocess.run(['yosys', '-s', str(script)], stdout=log, stderr=subprocess.STDOUT, timeout=180).returncode
        results.append({'unit': unit, 'rc': rc, 'latchesAndSccClean': rc == 0,
                        'scope': 'live-port leaf synthesis, XLEN64, load slots4, MMU1, OoO1; not mapped timing'})
        (out / 'results.json').write_text(json.dumps(results, indent=2))
        if rc:
            raise RuntimeError(f'leaf synthesis failed: {unit}')
    (out / 'sources.json').write_text(json.dumps({p.name: sha(p) for p in source.glob('*.sv')}, indent=2))


def run_fp_lifetime():
    import shutil

    data, out = Path(os.environ['TH_DATA_DIR']), Path(os.environ['TH_OUT_DIR'])
    repo = Path('/opt/testharness/repo')
    runtime_record = Path('/opt/testharness/runs/review-private-runtime-rebuild-20260915/output/runtime.json')
    runtime = Path(json.loads(runtime_record.read_text())['privateRoot'])
    if sha(runtime / 'include/verilated_funcs.h') != 'dfbc2c4aa3c1065d4465027c893c9677de10da4cfe7fb152e485eb32b8125166':
        raise ValueError('unqualified runtime')
    control = Path('/opt/testharness/runs/pmp-transition-split-20260919/output/source/split-counter.vlt')
    if sha(control) != 'be176b279ada076a3459d8bd6509e0946ccf0994d5c35a092bede308bba8c8ff':
        raise ValueError('unqualified compiler control')
    nsb = int(os.environ.get('FP_LIFETIME_NSB', '32'))
    standard_recipe = os.environ.get('FP_LIFETIME_STANDARD_RECIPE') == '1'
    expected_cancel = os.environ.get('FP_LIFETIME_EXPECT_CANCEL') == '1'
    mutation = os.environ.get('FP_LIFETIME_MUTATE_CANCEL') == '1'
    ooo = int(os.environ.get('FP_LIFETIME_OOO', '1'))
    divider = os.environ.get('FP_LIFETIME_DIVIDER') == '1'
    if ooo not in (0, 1) or (expected_cancel and not ooo) or (mutation and not expected_cancel):
        raise ValueError('inconsistent FP lifetime test mode')
    if nsb not in (8, 16, 32):
        raise ValueError('unsupported scoreboard geometry')
    source = out / 'source'
    source.mkdir()
    flist = (data / 'Flist.cva6').read_text()
    entries = [line.strip().replace('${CVA6_REPO_DIR}/', '') for line in flist.splitlines()
               if line.strip().startswith('${CVA6_REPO_DIR}/')]
    fp = [p for p in entries if p.startswith('core/cvfpu/') and p.endswith(('.sv', '.v'))]
    common = [p for p in entries if p.startswith('vendor/pulp-platform/common_cells/src/') and p.endswith('.sv')]
    fixed = ['core/include/config_pkg.sv', 'core/include/g6lc64_smt2_config_pkg.sv',
             'core/include/riscv_pkg.sv', 'core/cvfpu/src/fpnew_pkg.sv', 'core/include/ariane_pkg.sv']
    paths = list(dict.fromkeys(['vendor/pulp-platform/common_cells/src/cf_math_pkg.sv', *fixed,
                               *common, *fp, 'core/g6lc_rvc_enc.sv', 'core/g6lc_jalr_usable.sv',
                               'core/g6lc_fe_keep.sv', 'core/g6lc_sib_cjalr.sv',
                               'core/fpu_wrap.sv', 'core/multiplier.sv', 'core/serdiv.sv', 'core/mult.sv',
                               'core/controller.sv', 'core/scoreboard.sv']))
    pins = {}
    for rel in paths + ['core/include/g6lc_core_types.svh']:
        original = data / Path(rel).name
        if not original.is_file():
            original = repo / rel
        dest = source / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(original, dest)
        pins[rel] = sha(dest)
    original_fp_hash = pins['core/fpu_wrap.sv']
    original_div_hash = pins['core/mult.sv']
    if mutation:
        if divider:
            div_path = source / 'core/mult.sv'
            text = div_path.read_text()
            needle = "div_owner_cancelled_q <= (div_owner_cancelled_q | cancelled_mask_i) & div_owner_live_q;"
            if text.count(needle) != 1:
                raise ValueError('divider cancellation mutation site changed')
            div_path.write_text(text.replace(needle, "div_owner_cancelled_q <= '0;"))
            pins['core/mult.sv'] = sha(div_path)
        else:
            fp_path = source / 'core/fpu_wrap.sv'
            text = fp_path.read_text()
            needle = "owner_cancelled_q <= (owner_cancelled_q | cancelled_mask_i) & owner_live_q;"
            if text.count(needle) != 1:
                raise ValueError('FP cancellation mutation site changed')
            fp_path.write_text(text.replace(needle, "owner_cancelled_q <= '0;"))
            pins['core/fpu_wrap.sv'] = sha(fp_path)
    includes = []
    for directory in ('vendor/pulp-platform/common_cells/include', 'core/cvfpu/src/common_cells/include'):
        if (repo / directory).is_dir():
            for original in (repo / directory).rglob('*.svh'):
                rel = original.relative_to(repo)
                dest = source / rel
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(original, dest)
                pins[str(rel)] = sha(dest)
            includes.append('-I' + str(source / directory))
    top = 'tb_g6lc_review_fp_lifetime'
    bench = (data / 'tb_g6lc_rtl_review.sv').read_text()
    bench = 'module ' + top + ';' + bench.split('module ' + top + ';', 1)[1].split('endmodule', 1)[0] + 'endmodule\n'
    (source / 'bench.sv').write_text(bench)
    pins['bench.sv'] = sha(source / 'bench.sv')
    pins['Flist.cva6'] = sha(data / 'Flist.cva6')
    shutil.copy2(data / 'verilator_config.vlt', source / 'verilator_config.vlt')
    pins['verilator_config.vlt'] = sha(source / 'verilator_config.vlt')
    (out / 'inputs.json').write_text(json.dumps({
        'sources': pins, 'runnerSha256': sha(Path(__file__)), 'scoreboardEntries': nsb,
        'runtimeRoot': str(runtime), 'runtimeHeaderSha256': sha(runtime / 'include/verilated_funcs.h'),
        'compilerControlSha256': sha(control), 'qualificationOnly': True,
        'standardWarningConfigSha256': pins['verilator_config.vlt'], 'strictStructuralQualification': False,
        'standardModelWarningRecipe': standard_recipe,
        'expectedCancellation': expected_cancel, 'OoOEn': ooo, 'cancellationMutation': mutation,
        'producer': 'divider' if divider else 'fpu',
        'originalFpuSha256': original_fp_hash, 'originalDividerSha256': original_div_hash,
        'unoptflatGate': 'open' if standard_recipe else 'enforced',
        'scope': 'Real FPU/controller/scoreboard boundary; decoded allocation and fixed-latency ALU/commit drivers, not full-core reachability or structural sign-off'}, indent=2))
    model = out / 'model'
    command = ['verilator', '--cc', '--main', '--exe', '--timing', '--assert', '--threads', '1',
               '-Wno-fatal', '-Wno-BLKANDNBLK', '-Werror-LATCH',
               '-Wno-UNOPTFLAT' if standard_recipe else '-Werror-UNOPTFLAT', '-DG6LC_FETCH_B',
               str(source / 'verilator_config.vlt'), str(control),
               '-I' + str(source / 'core/include'), *includes, '--top-module', top, f'-GNSB={nsb}',
               f'-GEXPECT_CANCEL={int(expected_cancel)}', f'-GOOO={ooo}', f'-GDIVIDER={int(divider)}',
               '--Mdir', str(model), '-o', 'fp-lifetime', *[str(source / p) for p in paths], str(source / 'bench.sv')]
    env = dict(os.environ, VERILATOR_ROOT=str(runtime))
    for label, cmd in [('verilate', command), ('build', ['make', '-C', str(model), '-f', f'V{top}.mk', '-j4'])]:
        (out / f'{label}-command.json').write_text(json.dumps(cmd, indent=2))
        with (out / f'{label}.log').open('w') as log:
            rc = subprocess.run(cmd, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=600).returncode
        if rc:
            raise RuntimeError(f'FP lifetime {label} failed')
    dependencies = '\n'.join(p.read_text() for p in model.glob('*.d'))
    if str(runtime / 'include/verilated_funcs.h') not in dependencies:
        raise ValueError('compiled runtime identity missing')
    results = []
    trials = [(0, False), (0, True), (2, False), (2, True)]
    if ooo:
        trials += [(1, False), (4, False), (4, True)]
        if expected_cancel:
            trials += [(1, True), (3, False), (3, True), (5, False), (5, True)]
    if mutation:
        trials = [(1, False)]
    for scenario, negative in trials:
        cmd = [str(model / 'fp-lifetime'), f'+scenario={scenario}'] + (['+oracle_negative'] if negative else [])
        result = subprocess.run(cmd, cwd=out, capture_output=True, text=True, timeout=30)
        text = result.stdout + result.stderr
        (out / f'case{scenario}-negative{int(negative)}.log').write_text(text)
        error = 'FP_OWNER_RESULT' if scenario in (0, 3, 4, 5) else 'FP_OWNER_ORACLE_NEGATIVE'
        if mutation:
            matched = result.returncode != 0 and 'FP_OWNER_CANCELLED_RESPONSE' in text and 'FP_OWNER_PASS' not in text
            observation = 'retention-mutation-detected' if matched else 'unexpected'
            outcome = 'pass' if matched else 'error'
        elif scenario == 1 and not expected_cancel:
            observation = ('stale-completion' if result.returncode != 0 and 'FP_OWNER_STALE_COMPLETION' in text
                           else 'completed-before-reuse' if result.returncode == 0 and 'FP_OWNER_NO_OVERLAP' in text else 'unexpected')
            outcome = 'fail' if observation == 'stale-completion' else 'incomplete' if observation == 'completed-before-reuse' else 'error'
            matched = False
        else:
            matched = (result.returncode != 0 and error in text and 'FP_OWNER_PASS' not in text) if negative else (
                result.returncode == 0 and text.count('FP_OWNER_PASS') == 1 and '%Error' not in text)
            observation = 'negative-detected' if negative and matched else 'control-completed' if matched else 'unexpected'
            outcome = 'pass' if matched else 'error'
        results.append({'scenario': scenario, 'negative': negative, 'rc': result.returncode,
                        'outcome': outcome, 'observation': observation, 'matched': matched,
                        'markers': [line for line in text.splitlines() if line.startswith('FP_OWNER_')],
                        'modelSha256': sha(model / 'fp-lifetime'), 'strictQualification': False})
        (out / 'results.json').write_text(json.dumps(results, indent=2))
    if any(sha(source / p) != v for p, v in pins.items() if p != 'Flist.cva6'):
        raise RuntimeError('source changed during execution')
    return 0 if all(item['matched'] for item in results) else 1


def main():
    if os.environ.get('FAULT_REVIEW_FP_LIFETIME') == '1':
        return run_fp_lifetime()
    if os.environ.get('FAULT_REVIEW_SYNTH') == '1':
        return run_synth()
    if os.environ.get('FAULT_REVIEW_FORMAL') == '1':
        return run_formal()
    if os.environ.get('FAULT_REVIEW_AGE_FORMAL') == '1':
        return run_age_formal()
    if os.environ.get('FAULT_REVIEW_LEAF') == '1':
        return run_leaf()
    source = Path(os.environ['FAULT_REVIEW_RUN'])
    out = Path(os.environ['TH_OUT_DIR'])
    record = json.loads((source / 'results.json').read_text())
    log = source / 'trial/run.log'
    if sha(log) != record['logSha256']:
        raise ValueError('frozen run log changed')
    if os.environ.get('FAULT_REVIEW_TRACE_ONLY') == '1':
        result = {'sourceRun': str(source), 'modelSha256': record['modelSha256'],
                  'firmwareSha256': record['firmwareSha256'], 'logSha256': record['logSha256'],
                  'outcome': record.get('outcome'),
                  'scope': 'Unattributed physical-core trace tails; no logical-hart or architectural-equivalence claim'}
        for name in ('trace_rvfi_hart_00.dasm', 'trace_hart_0.dasm'):
            path = source / 'trial' / name
            with path.open() as stream:
                tail = list(deque(stream, maxlen=128))
            (out / (name + '.tail')).write_text(''.join(tail))
            result[name] = {'sha256': sha(path), 'tailLines': len(tail)}
        (out / 'analysis.json').write_text(json.dumps(result, indent=2))
        return
    with log.open() as stream:
        result = fault_context(stream)
    if not result['retiredByHart'] or result['retiredByHart'] != {int(h): n for h, n in record['retiredByHart'].items()}:
        raise ValueError('flow retirement counts disagree with the independently recorded progress')
    reference = os.environ.get('FAULT_REVIEW_REFERENCE_RUN')
    if reference:
        prior = Path(reference)
        prior_record = json.loads((prior / 'results.json').read_text())
        if any(prior_record[key] != record[key] for key in ('modelSha256', 'firmwareSha256')):
            raise ValueError('observer comparison requires identical model and firmware')
        compared = 0
        with (source / 'trial/trace_rvfi_hart_00.dasm').open() as current, (prior / 'trial/trace_rvfi_hart_00.dasm').open() as previous:
            for line in current:
                compared += 1
                if line != previous.readline():
                    raise ValueError(f'observer changed retirement row {compared}')
        if not compared:
            raise ValueError('empty observer comparison')
        result['observerReference'] = {'run': reference, 'exactPrefixLines': compared}
    if os.environ.get('FAULT_REVIEW_CYCLE_LO'):
        lo = int(os.environ['FAULT_REVIEW_CYCLE_LO'])
        hi = int(os.environ['FAULT_REVIEW_CYCLE_HI'])
        if not 0 <= lo <= hi <= lo + 2000:
            raise ValueError('diagnostic window must span at most 2000 cycles')
        with log.open() as stream, (out / 'window.log').open('w') as window:
            for line in stream:
                match = re.search(r'\b(?:cycle|time)=(\d+)', line)
                if match and lo <= int(match[1]) <= hi:
                    window.write(line)
    trace = source / 'trial/trace_rvfi_hart_00.dasm'
    recent = deque(maxlen=48)
    halt_contexts = []
    for line in trace.open():
        if not re.match(r'^[0-3] ', line):
            continue
        recent.append(line.rstrip())
        if re.search(r'\(0x(?:0*10500073)\)', line):
            halt_contexts.append(list(recent))
    firmware = Path(record['firmware'])
    if sha(firmware) != record['firmwareSha256']:
        raise ValueError('frozen firmware changed')
    disassembly = subprocess.check_output(['riscv-none-elf-objdump', '-d', str(firmware)], text=True)
    (out / 'firmware.dis').write_text(disassembly)
    result.update(sourceRun=str(source), modelSha256=record['modelSha256'],
                  firmwareSha256=record['firmwareSha256'], logSha256=record['logSha256'],
                  rvfiSha256=sha(trace), wfiContexts=halt_contexts[-8:],
                  strictDualPassed=record['strictDualPassed'])
    (out / 'analysis.json').write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    raise SystemExit(main())
