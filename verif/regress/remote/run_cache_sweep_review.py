#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Phase-4 cache-geometry sweep + elaboration legality (measurement, not
# qualification):
#
#   REVIEW_SWEEP=1      composed hub+L2+L3 bench (tb_g6lc_coherence_l2,
#                       scenario 5) across the 9-point L2{128,256,512 KiB} x
#                       L3{512 KiB,1,2 MiB} matrix, assoc 8/16, TAG_SRAM=1.
#                       Reports per-phase hits/misses and analytic bit budgets.
#   REVIEW_SWEEP_LINT=1 lint-elaborates g6lc_cluster_lint_top for the same 9
#                       points on the int2_l3 package with L2/L3 sizes mutated
#                       through the check_cfg user literal (the refusal
#                       harness's constant-function mechanism: build_config of
#                       a mutated cva6_user_cfg_t as the CVA6Cfg parameter).
#                       Sources: REVIEW_SEED repo copy + REVIEW_SWEEP_OVERLAY.

import hashlib, json, math, os, re, shutil, subprocess, sys
from pathlib import Path

NAMES = ['config_pkg.sv', 'axi_pkg.sv', 'tc_sram.sv', 'g6lc_l2_pkg.sv',
         'g6lc_l2_tag.sv', 'g6lc_l2_data.sv', 'g6lc_l2_mshr.sv', 'g6lc_l2_top.sv',
         'g6lc_l3_pkg.sv', 'g6lc_l3_top.sv', 'axi_cut.sv', 'spill_register.sv',
         'g6lc_coherence_pkg.sv', 'g6lc_inval_bus.sv', 'g6lc_snoop_filter.sv',
         'g6lc_ooo_snoop_filter.sv', 'g6lc_lr_sc_tracker.sv', 'g6lc_coherence_hub.sv',
         'tb_g6lc_l2.sv', 'tb_g6lc_coherence_hub.sv']
HEADERS = ('assign.svh', 'typedef.svh')

L2_SIZES = [131072, 262144, 524288]
L3_SIZES = [524288, 1048576, 2097152]
L2_WAYS, L3_WAYS = 8, 16
LINE = 64


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def bit_budget(byte_size, ways):
    sets = byte_size // (LINE * ways)
    tag_bits = 64 - int(math.log2(sets)) - 6
    return {'sets': sets, 'ways': ways,
            'tagWidth': tag_bits,
            'tagBits': sets * ways * tag_bits,
            'dataBits': byte_size * 8,
            'validFlops': sets * ways}


def run_sweep(out, data):
    source = out / 'source'
    source.mkdir(parents=True, exist_ok=True)
    for name in NAMES:
        shutil.copy2(data / name, source / name)
    (source / 'axi').mkdir(exist_ok=True)
    for header in HEADERS:
        shutil.copy2(data / header, source / 'axi' / header)
    hashes = {name: digest(source / name) for name in NAMES}
    types = re.findall(r'package g6lc_l2_tb_pkg;.*?endpackage',
                       (source / 'tb_g6lc_l2.sv').read_text(), re.S)
    assert len(types) == 1
    (source / 'types.sv').write_text(types[0] + '\n')
    files = [str(source / n) for n in NAMES[:-2]] + [str(source / 'types.sv'),
                                                     str(source / NAMES[-1])]
    runtime = Path('/opt/testharness/runs/review-private-runtime-20260915/runtime')
    assert digest(runtime / 'include/verilated_funcs.h') == \
        'dfbc2c4aa3c1065d4465027c893c9677de10da4cfe7fb152e485eb32b8125166'
    env = dict(os.environ, VERILATOR_ROOT=str(runtime), VPATH=str(runtime / 'include'))
    verilator = '/opt/testharness/toolchains/verilator-v5.008/bin/verilator'
    if not Path(verilator).is_file():
        verilator = 'verilator'
    # Same compiler control as the composed lane: struct-granular UNOPTFLAT at
    # the hub/L2 AXI seams is not a bit-level loop (review-composed SCC lane).
    control = out / 'composed.vlt'
    control.write_text('`verilator_config\n' + '\n'.join(
        f'split_var -module "{module}" -var "{port}"' for module, ports in (
            ('g6lc_coherence_hub', ('mem_req_o', 'mem_resp_i', 'core_req_i', 'core_resp_o')),
            ('g6lc_l2_top', ('slv_req_i', 'slv_resp_o', 'mst_req_o', 'mst_resp_i')),
            ('g6lc_l3_top', ('slv_req_i', 'slv_resp_o', 'mst_req_o', 'mst_resp_i')),
            ('axi_cut', ('slv_req_i', 'slv_resp_o', 'mst_req_o', 'mst_resp_i')))
        for port in ports) + '\nisolate_assignments -module "g6lc_coherence_hub" -var "mem_req_o"\n'
        'isolate_assignments -module "g6lc_l2_top" -var "slv_resp_o"\n')
    results = []
    for l2b in L2_SIZES:
        for l3b in L3_SIZES:
            tag = f'l2-{l2b//1024}k-l3-{l3b//1024}k'
            model = out / f'model-{tag}'
            command = [verilator, '--cc', '--main', '--exe', '--timing', '--assert',
                       '--threads', '1', '--flatten',
                       '-Wno-fatal', '-Werror-LATCH', '-Werror-USERERROR',
                       str(control), '-I' + str(source),
                       '--top-module', 'tb_g6lc_coherence_l2',
                       '-GUSE_L3=1', '-GTAG_SRAM=1',
                       f'-GBYTE_SIZE={l2b}', f'-GSET_ASSOC={L2_WAYS}',
                       '-GMSHR_DEPTH=4', '-GDATA_BANKS=4',
                       f'-GL3_BYTES={l3b}', f'-GL3_SET_ASSOC={L3_WAYS}',
                       '-GL3_MSHR_DEPTH=4', '-GL3_DATA_BANKS=4',
                       '--Mdir', str(model), '-o', 'composed-test', *files]
            with (out / f'verilate-{tag}.log').open('w') as log:
                rc = subprocess.run(command, env=env, stdout=log,
                                    stderr=subprocess.STDOUT, timeout=600).returncode
            assert rc == 0, f'verilate {tag}'
            with (out / f'build-{tag}.log').open('w') as log:
                rc = subprocess.run(['make', '-C', str(model), '-f',
                                     'Vtb_g6lc_coherence_l2.mk', '-j4'],
                                    env=env, stdout=log, stderr=subprocess.STDOUT,
                                    timeout=600).returncode
            assert rc == 0, f'build {tag}'
            exe = model / 'composed-test'
            run = subprocess.run([str(exe), '+scenario=5'], cwd=out,
                                 capture_output=True, text=True, timeout=600)
            text = run.stdout + run.stderr
            (out / f'sweep-{tag}.log').write_text(text)
            phases = re.findall(
                r'COH_L2_SWEEP phase=(\d+) l2_hit=(\d+) l2_miss=(\d+) l3_hit=(\d+)'
                r' l3_miss=(\d+) dram_ar=(\d+) cycles=(\d+)', text)
            passed = run.returncode == 0 and 'COH_L2_PASS scenario=5' in text \
                and len(phases) == 5
            results.append({
                'point': tag, 'l2Bytes': l2b, 'l3Bytes': l3b,
                'rc': run.returncode, 'matched': passed,
                'phases': [{'phase': int(p[0]), 'l2Hit': int(p[1]),
                            'l2Miss': int(p[2]), 'l3Hit': int(p[3]),
                            'l3Miss': int(p[4]), 'dramAr': int(p[5]),
                            'cycles': int(p[6])} for p in phases],
                'budget': {'l2': bit_budget(l2b, L2_WAYS),
                           'l3': bit_budget(l3b, L3_WAYS)}})
            (out / 'results-sweep.json').write_text(json.dumps(
                {'sources': hashes, 'tagSram': True, 'points': results}, indent=2))
            assert passed, (tag, text[-2000:])
    return results


FLISTS = ['core/Flist.cva6', 'corev_apu/Flist.cluster']
TARGET = 'g6lc64_ooo_int2_l3'
HPDCACHE_SUBPATH = 'core/cache_subsystem/hpdcache'


def run_lint_sweep(out, data):
    # The cluster lint top binds cva6_config_pkg through TARGET_CFG; the size
    # mutation rides the same constant-function seam as cfg_refusal_harness:
    # mutate the int2_l3 user literal, build_config it, pass as CVA6Cfg.
    seed = Path(os.environ['REVIEW_SEED'])
    assert (seed / 'core').is_dir(), seed
    repo = out / 'repo'
    shutil.copytree(seed, repo, symlinks=True)
    overlay = [p for p in os.environ.get('REVIEW_SWEEP_OVERLAY', '').split(',') if p]
    for relative in overlay:
        src = data / Path(relative).name
        assert src.is_file(), src
        dst = repo / relative
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
    hpdcache = (repo / HPDCACHE_SUBPATH).as_posix()

    def expand(text):
        return (text.replace('${CVA6_REPO_DIR}', repo.as_posix())
                    .replace('${TARGET_CFG}', TARGET)
                    .replace('${HPDCACHE_DIR}', hpdcache))

    def flatten(path, seen):
        key = str(path.resolve())
        if key in seen:
            return []
        seen.add(key)
        acc = []
        for raw in expand(path.read_text(encoding='utf-8')).splitlines():
            line = raw.strip()
            m = re.match(r'^-[Ff]\s+(\S+)$', line)
            if m:
                nested = Path(m.group(1))
                if not nested.is_absolute():
                    nested = path.parent / nested
                assert nested.is_file(), f'nested manifest not found: {nested}'
                acc.extend(flatten(nested, seen))
            else:
                acc.append(raw)
        return acc

    flat = out / f'{TARGET}.f'
    body = []
    seen = set()
    for name in FLISTS:
        body.extend(flatten(repo / name, seen))
    flat.write_text('\n'.join(body) + '\n', encoding='utf-8')

    verilator = '/opt/testharness/toolchains/verilator-v5.008/bin/verilator'
    if not Path(verilator).is_file():
        verilator = 'verilator'
    results = []
    for l2b in L2_SIZES:
        for l3b in L3_SIZES:
            tag = f'l2-{l2b//1024}k-l3-{l3b//1024}k'
            harness = out / f'sweep_lint_{tag}.sv'
            harness.write_text(
                '// Copyright (c) 2026 Etienne Cimon\n'
                '// SPDX-License-Identifier: MIT\n'
                f'// Geometry sweep elaboration point: L2={l2b} L3={l3b} on the\n'
                '// int2_l3 package. Mutates the user literal and rebuilds the\n'
                '// resolved config, the same mechanism check_cfg refusal\n'
                '// harnesses use, so check_cfg-visible knobs stay consistent.\n'
                'function automatic config_pkg::cva6_cfg_t g6lc_sweep_cfg();\n'
                '  config_pkg::cva6_user_cfg_t u = cva6_config_pkg::cva6_cfg;\n'
                f"  u.L2ByteSize = unsigned'({l2b});\n"
                f"  u.L3ByteSize = unsigned'({l3b});\n"
                '  return build_config_pkg::build_config(u);\n'
                'endfunction\n'
                f'module g6lc_sweep_lint_{tag.replace("-", "_")};\n'
                '  g6lc_cluster_lint_top #(.CVA6Cfg(g6lc_sweep_cfg())) i_top();\n'
                'endmodule\n')
            top = f'g6lc_sweep_lint_{tag.replace("-", "_")}'
            command = [verilator, '--lint-only', '--no-timing', '-Wall',
                       '-Werror-PINMISSING', '-Werror-IMPLICIT', '-Wno-fatal',
                       '-Wno-PINCONNECTEMPTY', '-Wno-ASSIGNDLY', '-Wno-DECLFILENAME',
                       '-Wno-UNUSED', '-Wno-UNOPTFLAT', '-Wno-BLKANDNBLK', '-Wno-style',
                       '--top-module', top,
                       str(repo / 'verilator_config.vlt'), '-f', str(flat),
                       str(harness)]
            with (out / f'lint-{tag}.log').open('w') as log:
                rc = subprocess.run(command, cwd=repo, stdout=log,
                                    stderr=subprocess.STDOUT, timeout=1800).returncode
            text = (out / f'lint-{tag}.log').read_text(errors='replace')
            warnings = len(re.findall(r'%Warning', text))
            errors = len(re.findall(r'%Error', text))
            results.append({'point': tag, 'l2Bytes': l2b, 'l3Bytes': l3b, 'rc': rc,
                            'warnings': warnings, 'errors': errors,
                            'matched': rc == 0 and errors == 0})
            (out / 'results-lint.json').write_text(json.dumps(
                {'seed': str(seed), 'overlay': overlay, 'target': TARGET,
                 'flistSha256': digest(flat), 'points': results}, indent=2))
            assert results[-1]['matched'], (tag, text[-2000:])
    return results


def main():
    out = Path(os.environ['TH_OUT_DIR'])
    data = Path(os.environ['TH_DATA_DIR'])
    out.mkdir(parents=True, exist_ok=True)
    summary = {}
    if os.environ.get('REVIEW_SWEEP', '0') == '1':
        summary['sweep'] = run_sweep(out, data)
    if os.environ.get('REVIEW_SWEEP_LINT', '0') == '1':
        summary['lint'] = run_lint_sweep(out, data)
    assert summary, 'set REVIEW_SWEEP=1 and/or REVIEW_SWEEP_LINT=1'
    (out / 'summary.json').write_text(json.dumps(summary, indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main())
