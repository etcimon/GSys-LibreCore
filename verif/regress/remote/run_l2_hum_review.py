#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Hit-under-miss review for g6lc_l2_top: builds the dedicated concurrent-reader
# bench, runs the contract scenarios plus their injected-error controls, and
# records the raw same-line / different-line measurements.
#
# REVIEW_L2_HUM_BASELINE=<dir> overlays pre-change g6lc_l2_top.sv /
# g6lc_l2_mshr.sv so the measurement control is a matched build.

import hashlib, json, os, re, shutil, subprocess, sys
from pathlib import Path

NAMES = ['axi_pkg.sv', 'tc_sram.sv', 'g6lc_l2_pkg.sv', 'g6lc_l2_tag.sv',
         'g6lc_l2_data.sv', 'g6lc_l2_mshr.sv', 'g6lc_l2_top.sv',
         # compiled with -DL2TB_STATIC: contributes g6lc_l2_tb_pkg only
         'tb_g6lc_l2.sv', 'g6lc_l3_pkg.sv', 'g6lc_l3_top.sv',
         'spill_register_flushable.sv', 'spill_register.sv', 'axi_cut.sv',
         'assign.svh', 'typedef.svh', 'tb_g6lc_l2_hum.sv',
         'tb_g6lc_l2_tag_miter.sv']
HEADERS = ('assign.svh', 'typedef.svh')

# scenario -> expected-failure token for the injected-error control
CONTRACT = {0: 'HUM_DATA', 1: 'HUM_DATA', 2: 'HUM_DATA', 3: 'HUM_DATA',
            4: 'HUM_DATA', 5: None, 6: None, 7: 'HUM_DATA', 8: 'HUM_DATA',
            9: 'HUM_DATA', 10: 'HUM_DATA', 11: 'HUM_DATA', 12: 'HUM_DATA',
            13: 'HUM_DATA', 14: 'HUM_DATA', 15: 'HUM_DATA', 16: 'HUM_DATA',
            17: 'HUM_DATA', 18: 'HUM_DATA', 19: 'HUM_DATA', 20: 'HUM_DATA',
            21: 'HUM_DATA', 22: 'HUM_DATA', 23: 'HUM_DATA', 24: 'HUM_DATA',
            25: 'HUM_DATA', 26: 'HUM_DATA', 27: 'HUM_DATA', 28: 'HUM_DATA',
            29: 'HUM_DATA', 30: 'HUM_DATA', 31: 'HUM_DATA', 32: 'HUM_DATA',
            33: 'HUM_DATA', 34: 'HUM_DATA', 35: 'HUM_DATA', 36: 'HUM_DATA',
            37: 'HUM_DATA', 38: 'HUM_DATA', 39: 'HUM_DATA', 40: 'HUM_DATA',
            41: 'HUM_DATA'}
# Scenarios exercising the TAG_SRAM launched-read protocol; functional on the
# flop path too (the SRAM-only engagement checks are parameter-gated).
TAG_SRAM_SCEN = range(35, 42)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    data = Path(os.environ['TH_DATA_DIR'])
    out = Path(os.environ['TH_OUT_DIR'])
    source = out / 'source'
    source.mkdir(parents=True, exist_ok=True)

    baseline = os.environ.get('REVIEW_L2_HUM_BASELINE')
    fault = os.environ.get('REVIEW_L2_HUM_FAULT')
    order_before = os.environ.get('REVIEW_L2_HUM_ORDER_BEFORE') == '1'
    atop_before = os.environ.get('REVIEW_L2_HUM_ATOP_BEFORE') == '1'
    chain = os.environ.get('REVIEW_L2_HUM_CHAIN') == '1'
    inval_before = os.environ.get('REVIEW_L2_HUM_INVAL_BEFORE') == '1'
    rr_sched = os.environ.get('REVIEW_L2_HUM_RR') == '1'
    tagsram = os.environ.get('REVIEW_L2_HUM_TAG_SRAM') == '1'
    miter = os.environ.get('REVIEW_L2_HUM_MITER') == '1'
    (out / 'mode.json').write_text(json.dumps(
        {k: v for k, v in os.environ.items() if k.startswith('REVIEW_L2_HUM')}, indent=2))
    # Restores the original single-port schedule, where a colliding install took
    # the port and the accepted request's own pointer read was dropped.
    rr_fault = os.environ.get('REVIEW_L2_HUM_RR_FAULT') == '1'
    # Disconnects the outer cache's victim from the inner back-invalidation port,
    # which is how this fixture was originally wired, so the inclusion scenario
    # must fail.
    incl_fault = os.environ.get('REVIEW_L2_HUM_INCL_FAULT') == '1'
    RR_SITES = (
        ("assign do_write = (rr_adv || rr_pend_q) && !read_req;",
         "assign do_write = rr_adv;"),
        ("assign ram_addr = read_req ? idx_of(slv_req_i.ar.addr)\n"
         "                               : (rr_adv ? tag_windex : rr_pend_idx_q);",
         "assign ram_addr = rr_adv ? tag_windex : idx_of(slv_req_i.ar.addr);"),
    )
    faults = {
        'collect': (9, "collect_cnt_d             = collect_cnt_d + 1'b1;", "collect_cnt_d             = collect_cnt_q + 1'b1;", 'HUM_COLLECT_RETIRE_COUNT'),
        'issue': (10, "issued_cnt_d            = issued_cnt_d + 1'b1;", "issued_cnt_d            = issued_cnt_q + 1'b1;", 'HUM_ISSUE_RETIRE_COUNT'),
        'install': (11, 'tag_write  = !bank_conflict;', "tag_write  = 1'b1;", 'HUM_TAG_WITHOUT_DATA'),
        'install_snoop': (32,
            "  assign install_discard = fill_kill_q[inst_idx] ||\n"
            "      (fill_ferr_q[inst_idx] != axi_pkg::RESP_OKAY) ||\n"
            "      (l2_back_inval_valid_i &&\n"
            "       line_align(fill_addr_q[inst_idx]) == line_align(l2_back_inval_addr_i)) ||\n"
            "      (wr_inval_pend_q &&\n"
            "       line_align(fill_addr_q[inst_idx]) == line_align(wr_inval_addr_q)) ||\n"
            "      ((state_q == S_BYPASS_AW || state_q == S_BYPASS_W) &&\n"
            "       line_align(fill_addr_q[inst_idx]) == line_align(addr_q));",
            "  assign install_discard = fill_kill_q[inst_idx] ||\n"
            "      (fill_ferr_q[inst_idx] != axi_pkg::RESP_OKAY);", 'HUM_INSTALL_INVAL_STALE'),
        # A read after a back-invalidation merges into the killed F_READY fill
        # and is served the stale pre-inval copy instead of refetching.
        'merge': (34,
            "      .merge_block_i     (fill_kill_q),",
            "      .merge_block_i     ('0),", 'HUM_STALE_MERGE'),
    }
    assert not fault or (fault in faults and not baseline), 'invalid fault-control mode'
    assert not order_before or (not baseline and not fault), 'invalid order-before mode'
    assert not atop_before or (not baseline and not fault and not order_before), 'invalid atop-before mode'
    assert not chain or not (baseline or fault or order_before or atop_before), 'invalid cache-stack mode'
    assert not inval_before or not (baseline or fault or order_before or atop_before or chain), 'invalid inval-before mode'
    for name in NAMES:
        origin = data / name
        if baseline and name in ('g6lc_l2_top.sv', 'g6lc_l2_mshr.sv'):
            origin = data / ('base_' + name)
            assert origin.exists(), origin
        shutil.copy2(origin, source / name)
    if incl_fault:
        assert chain, 'inclusion fault requires the cache-stack configuration'
        tb_path = source / 'tb_g6lc_l2_hum.sv'
        text = tb_path.read_text()
        old = '  assign inval_valid = back_inval_valid || (CHAIN_L3 && l3_evict_valid);'
        assert text.count(old) == 1, 'inclusion fault injection site changed'
        tb_path.write_text(text.replace(old, '  assign inval_valid = back_inval_valid;'))
    if rr_fault:
        assert rr_sched, 'rr-fault requires the RR configuration'
        rtl_path = source / 'g6lc_l2_top.sv'
        text = rtl_path.read_text()
        for old, new in RR_SITES:
            assert text.count(old) == 1, 'rr fault injection site changed'
            text = text.replace(old, new)
        rtl_path.write_text(text)
    if fault:
        rtl_path = source / 'g6lc_l2_top.sv'
        text = rtl_path.read_text()
        _, old, new, _ = faults[fault]
        assert text.count(old) == 1, 'fault injection site changed'
        rtl_path.write_text(text.replace(old, new))
    (out / 'sources.json').write_text(json.dumps(
        {name: digest(source / name) for name in NAMES}, indent=2))
    (source / 'axi').mkdir(exist_ok=True)
    for name in HEADERS:
        shutil.copy2(source / name, source / 'axi' / name)
    rtl_names = [n for n in NAMES if n not in HEADERS]

    runtime_info = json.loads(Path(
        '/opt/testharness/runs/review-cacheability-pair-20260916/output/runtime.json').read_text())
    runtime = Path(runtime_info['privateRoot'])
    assert digest(runtime / 'include/verilated_funcs.h') == \
        'dfbc2c4aa3c1065d4465027c893c9677de10da4cfe7fb152e485eb32b8125166'
    (out / 'runtime.json').write_text(json.dumps(runtime_info, indent=2))

    if os.environ.get('REVIEW_L2_HUM_SCC') == '1':
        assert not (baseline or fault or order_before or atop_before), 'invalid SCC mode'
        script = ('read_slang ' + ' '.join(str(source / n) for n in rtl_names[:-2]) +
                  ' -I' + str(source) + ' -DL2TB_STATIC -DL2TB_SYNTH --ignore-initial --ignore-assertions'
                  f' --top g6lc_l2_fixture -GCHAIN_L3=1 -GBYTE_SIZE=4096 -GSET_ASSOC=4'
                  f' -GMSHR_DEPTH=4 -GDATA_BANKS=2 -GRR_EN=0 -GTAG_SRAM={int(tagsram)};'
                  ' hierarchy -check -top g6lc_l2_fixture; flatten; proc; opt;'
                  ' check -assert; scc -expect 0')
        command = ['yosys', '-Q', '-T', '-p', script]
        (out/'scc-command.json').write_text(json.dumps(command, indent=2))
        with (out/'scc.log').open('w') as log:
            rc = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=180).returncode
        assert all(digest(source/n)==json.loads((out/'sources.json').read_text())[n] for n in NAMES)
        assert rc == 0, 'cache-stack combinational graph check'
        return 0
    model = out / 'model'
    rtl = ['-I' + str(source)] + [str(source / n) for n in rtl_names]
    top = 'tb_g6lc_l2_tag_miter' if miter else 'tb_g6lc_l2_hum'
    build = [
        ('verilate', ['verilator', '--cc', '--main', '--exe', '--timing', '--assert',
                      '--threads', '1', '-Wno-fatal', '-Wno-TIMESCALEMOD',
                      '-Werror-LATCH', '-Werror-UNOPTFLAT',
                      '-DL2TB_STATIC', *(['-GCHAIN_L3=1'] if chain else []),
                      *(['-GRR_EN=1'] if rr_sched else []),
                      *(['-GTAG_SRAM=1'] if tagsram else []),
                      *(['-GFAIR_WRITES=1'] if os.environ.get('REVIEW_L2_FAIR_WRITES') == '1' else []),
                      '--top-module', top, '--Mdir', str(model),
                      '-o', 'hum-test', *rtl]),
        ('build', ['make', '-C', str(model), '-f', f'V{top}.mk', '-j4',
                   'VERILATOR_ROOT=' + str(runtime)]),
    ]
    for label, cmd in build:
        with (out / f'{label}.log').open('w') as log:
            rc = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT).returncode
        assert rc == 0, label
    deps='\n'.join(p.read_text(errors='replace') for p in model.glob('*.d'))
    assert str(runtime/'include/verilated_funcs.h') in deps
    assert str(Path(runtime_info['originalRoot'])/'include/verilated_funcs.h') not in deps

    if os.environ.get('REVIEW_L2_HUM_SYNTH') == '1':
        for rr in (0, 1):
            script = ('read_slang ' + ' '.join(str(source / n) for n in rtl_names[:-2]) +
                      ' -I' + str(source) + ' -DL2TB_STATIC -DL2TB_SYNTH --ignore-initial --ignore-assertions'
                      ' --top g6lc_l2_fixture -GBYTE_SIZE=512 -GSET_ASSOC=2'
                      f' -GMSHR_DEPTH=2 -GDATA_BANKS=2 -GRR_EN={rr}'
                      f' -GTAG_SRAM={int(tagsram)}'
                      f' -GFAIR_WRITES={int(os.environ.get("REVIEW_L2_FAIR_WRITES") == "1")};'
                      ' hierarchy -check -top g6lc_l2_fixture; proc; opt; check -assert;'
                      ' synth -top g6lc_l2_fixture -noabc; check -assert;'
                      ' select -assert-none t:*dlatch* t:*DLATCH*')
            with (out / f'synth-rr{rr}.log').open('w') as log:
                rc = subprocess.run(['yosys', '-Q', '-T', '-p', script],
                                    stdout=log, stderr=subprocess.STDOUT, timeout=180).returncode
            assert rc == 0, f'L2 synthesis rr={rr}'
    exe = model / 'hum-test'
    if miter:
        # Bounded flop-vs-SRAM miter: positive must pass; the +miter_negative
        # control inverts the trial's hit_o and must fail — the SRAM-path
        # equivalent of the hit_o-inversion mutation.
        results = []
        for negative, expected in ((False, None), (True, 'L2TAG_MITER')):
            cmd = [str(exe)] + (['+miter_negative'] if negative else [])
            p = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
            text = p.stdout + p.stderr
            (out / f'miter-negative-{int(negative)}.log').write_text(text)
            if expected:
                matched = p.returncode != 0 and expected in text \
                    and 'L2TAG_MITER_PASS' not in text
            else:
                matched = p.returncode == 0 and text.count('L2TAG_MITER_PASS') == 1 \
                    and '%Error' not in text
            results.append({'negative': negative, 'expectedError': expected,
                            'rc': p.returncode, 'matched': matched,
                            'executableSha256': digest(exe)})
            (out / 'results.json').write_text(json.dumps(results, indent=2))
            assert matched, ('miter', negative)
        return 0
    results, metrics = [], {}
    # On the pre-change build the merge path does not exist, so the engagement
    # contract must visibly fail; only the measurements are comparable.
    # Scenario 31 needs an outer cache to evict a line, so it belongs to the
    # cache-stack plan only; running it on the direct path would have nothing to
    # measure and its engagement check fails, which is the correct behaviour.
    CHAIN_ONLY = {31}
    if os.environ.get('REVIEW_L2_FAIR_WRITES') != '1':
        CHAIN_ONLY.add(33)
    plan = ([(0, 'HUM_NOT_ENGAGED'), (5, None), (6, None)] if baseline
            else [(s, None) for s in sorted(CONTRACT) if s not in CHAIN_ONLY])
    if fault: plan = [(faults[fault][0], faults[fault][3])]
    if order_before:
        plan = [(12, 'HUM_DATA'), (13, 'HUM_DATA'), (14, 'HUM_DATA'),
                (15, 'HUM_AR_STABILITY'), (16, None), (17, None), (18, None), (19, 'HUM_DATA')]
    if atop_before:
        plan=[(20,'HUM_ATOP_R_BACKPRESSURE'),(21,'HUM_TIMEOUT'),(22,None),(23,None),
              (24,None),(25,None),(26,'HUM_TIMEOUT'),(27,None)]
    if chain: plan=([(31,'HUM_INCLUSION_STALE_HIT')] if incl_fault
                    else [(s,None) for s in [8,*range(12,30),31]])
    if rr_sched: plan=[(30,'HUM_RR_READ_LOST' if rr_fault else None)]
    if inval_before: plan=[(28,None),(29,'HUM_SELF_INVAL_LOST')]
    # TAG_SRAM mode keeps the full plan: every contract scenario must pass on
    # both tag paths; scenarios 35-40 additionally gate SRAM engagement
    # counters on the parameter.
    if os.environ.get('REVIEW_L2_INSTALL_INVAL') == '1':
        plan = [(32, 'HUM_INSTALL_INVAL_STALE' if
                 os.environ.get('REVIEW_L2_INSTALL_INVAL_BEFORE') == '1' else None)]
    if os.environ.get('REVIEW_L2_WRITE_FAIR') == '1':
        plan = [(33, 'HUM_WRITE_STARVE' if
                 os.environ.get('REVIEW_L2_WRITE_FAIR_BEFORE') == '1' else None)]
    for scenario, positive_error in plan:
        trials = [(False, positive_error)]
        if not (baseline or fault or order_before or atop_before or inval_before or rr_sched) \
                and CONTRACT[scenario]:
            trials.append((True, CONTRACT[scenario]))
        for negative, expected in trials:
            cmd = [str(exe), f'+scenario={scenario}'] + (['+oracle_negative'] if negative else [])
            if os.environ.get('REVIEW_L2_HUM_RR_DIAGNOSE')=='1': cmd += ['+rr_diagnose']
            p = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
            text = p.stdout + p.stderr
            (out / f'scenario-{scenario}-negative-{int(negative)}.log').write_text(text)
            if expected:
                matched = p.returncode != 0 and expected in text and 'RTL_REVIEW_PASS' not in text
            else:
                matched = p.returncode == 0 and text.count('RTL_REVIEW_PASS') == 1 and '%Error' not in text
                hit = re.search(r'HUM_METRICS scenario=(\d+) cycles=(\d+) dram_ar=(\d+) '
                                r'fills=(\d+) merges=(\d+) responses=(\d+)', text)
                assert hit, f'missing metrics for scenario {scenario}'
                metrics[scenario] = {
                    'cycles': int(hit.group(2)), 'dramAr': int(hit.group(3)),
                    'fills': int(hit.group(4)), 'merges': int(hit.group(5)),
                    'responses': int(hit.group(6)),
                }
            results.append({'scenario': scenario, 'negative': negative, 'rtlFault': fault,
                            'orderBefore': order_before,
                            'atopBefore': atop_before,
                            'cacheStack': 'L2-L3' if chain else 'L2',
                            'invalBefore': inval_before,
                            'rrEnabled': rr_sched,
                            'expectedError': expected, 'rc': p.returncode,
                            'matched': matched,
                            'executableSha256': digest(exe),
                            'strictQualification': False})
            (out / 'results.json').write_text(json.dumps(results, indent=2))
            assert matched, (scenario, negative)

    (out / 'metrics.json').write_text(json.dumps({
        'role': 'fault-control' if fault else 'baseline' if baseline else 'candidate',
        'sameLine': metrics.get(5),
        'differentLine': metrics.get(6),
        'contract': {str(k): v for k, v in metrics.items()},
    }, indent=2))
    assert all(digest(source / n) == json.loads((out / 'sources.json').read_text())[n]
               for n in NAMES)
    return 0


if __name__ == '__main__':
    sys.exit(main())
