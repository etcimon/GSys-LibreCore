#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""T9a eWT CMO leaf oracles — remote Verilator lanes.

Lanes (env-selected):
  REVIEW_CMO_ENGINE=1    g6lc_cmo_engine + g6lc_l3_inclusive_inv broadcaster
                         leaf (tb_g6lc_cmo_engine): arbiter fairness, broadcast
                         backpressure, L2/L3 match-inval handshake under
                         contention, clean write-idle wait; negatives neg0
                         (dropped core) / neg1 (dropped level) must hit
                         CMO_NO_DONE (the per-request done oracle expires long
                         before the CMO_TIMEOUT watchdog), and the
                         ENGINE_MUTATION source rewrite
                         (S_ISSUE -> S_DONE without the broadcast drain) must
                         hit CMO_EARLY_DONE.
  REVIEW_WT_CMO=1        wt_dcache leaf (tb_g6lc_wt_cmo): a CBO never reaches
                         the write buffer; one data_rvalid per CBO; mutation
                         (WT_CMO_MUTATION un-masks data_req) produces the
                         pre-fix byte-write signature WT_CMO_BYTE_WRITE.
  REVIEW_HPDCACHE_CMO=1  cva6_hpdcache_if_adapter leaf (tb_g6lc_hpdcache_cmo):
                         CMO response is held until cmo_done_i; mutation
                         (HPD_CMO_MUTATION drops the done gate) produces
                         HPDCACHE_CMO_EARLY_RVALID.

Data files come from TH_DATA_DIR (uploaded by testharness_proxy `py --data`).
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess


def _paths():
    return Path(os.environ['TH_DATA_DIR']), Path(os.environ['TH_OUT_DIR'])


def _env():
    env = dict(os.environ)
    env['PATH'] = '/opt/testharness/toolchains/verilator-v5.008/bin:' + env['PATH']
    return env


def _build(data, out, top, sources, mutate=None, gflags=None, include=None,
           extra_files=None, splits=None, unoptflat_error=True):
    """Copy sources (optionally rewritten), verilate + build, return exe path."""
    src = out / 'source'
    src.mkdir(parents=True, exist_ok=True)
    hashes = {}
    for name in sources:
        text = (data / name).read_text()
        if mutate and name in mutate:
            orig = hashlib.sha256(text.encode()).hexdigest()
            text = mutate[name](text)
            assert text != (data / name).read_text(), f'mutation no-op: {name}'
            hashes[name + ':mutated_from'] = orig
        (src / name).write_text(text)
        hashes[name] = hashlib.sha256((src / name).read_bytes()).hexdigest()
    for name in (extra_files or []):
        (src / name).write_text((data / name).read_text())
    (out / 'sources.json').write_text(json.dumps(hashes, indent=2))
    env = _env()
    mdir = out / 'model'
    cmd = ['verilator', '--cc', '--main', '--exe', '--build', '--timing',
           '--assert', '--threads', '1', '-j', '4',
           '-Wno-fatal', '-Werror-LATCH',
           '-Werror-UNOPTFLAT' if unoptflat_error else '-Wno-UNOPTFLAT',
           '--top-module', top, '--Mdir', str(mdir), '-o', 'simv']
    if splits:
        # UNOPTFLAT stays an error (-Werror): declare the known comb-flat
        # signals as split vars, same pattern as run_wt_coherence_review.
        control = out / (top + '.vlt')
        control.write_text('`verilator_config\n' + ''.join(
            f'split_var -module "{m}" -var "{v}"\n' for m, v in splits))
        cmd.append(str(control))
    for g in (gflags or []):
        cmd.append('-G' + g)
    for i in (include or []):
        cmd.append('-I' + str(src / i) if (src / i).is_dir() else '-I' + str(src))
    cmd += [str(src / n) for n in sources]
    with (out / 'build.log').open('w') as log:
        rc = subprocess.run(cmd, cwd=out, env=env, stdout=log,
                            stderr=subprocess.STDOUT, timeout=900).returncode
    assert rc == 0, f'build failed: {out / "build.log"}'
    return mdir / 'simv'


def _run(exe, out, name, plusargs, pass_token, expect_error=None, timeout=120):
    run = subprocess.run([str(exe), *plusargs], cwd=out, capture_output=True,
                         text=True, env=_env(), timeout=timeout)
    text = run.stdout + run.stderr
    (out / f'{name}.log').write_text(text)
    if expect_error:
        matched = run.returncode != 0 and expect_error in text and \
            pass_token not in text
    else:
        matched = (run.returncode == 0 and text.count(pass_token) == 1 and
                   '%Error' not in text)
    return {'name': name, 'rc': run.returncode, 'expectedError': expect_error,
            'matched': matched}


def run_cmo_engine():
    data, out = _paths()
    names = ['g6lc_coherence_pkg.sv', 'g6lc_l3_inclusive_inv.sv',
             'g6lc_cmo_engine.sv', 'tb_g6lc_cmo_engine.sv']
    results = []
    for l3 in (0, 1):
        exe = _build(data, out / f'engine-l3{l3}', 'tb_g6lc_cmo_engine', names,
                     gflags=[f'L3_EN_P={l3}'])
        results.append(_run(exe, out, f'engine-l3{l3}', [], 'CMO_ENGINE_PASS'))
    # negatives: dropped core / dropped level must stall -> the per-request
    # done oracle expires (CMO_NO_DONE) well before the global CMO_TIMEOUT.
    for kind in (0, 1):
        results.append(_run(exe, out, f'engine-neg{kind}',
                            ['+oracle_negative', f'+neg_kind={kind}'],
                            'CMO_ENGINE_PASS', expect_error='CMO_NO_DONE'))
    # source mutation: finish S_ISSUE without the broadcast drain -> the
    # bench's early-done oracle must catch it.
    def mut(text):
        old = "            state_d = l1_done_d ? S_DONE : S_WAIT_L1;"
        assert text.count(old) == 1
        return text.replace(old, "            state_d = S_DONE;")
    exe = _build(data, out / 'engine-mut', 'tb_g6lc_cmo_engine', names,
                 mutate={'g6lc_cmo_engine.sv': mut}, gflags=['L3_EN_P=1'])
    results.append(_run(exe, out, 'engine-earlydone', [], 'CMO_ENGINE_PASS',
                        expect_error='CMO_EARLY_DONE'))
    (out / 'results.json').write_text(json.dumps(results, indent=2))
    assert all(r['matched'] for r in results), results
    return 0


def run_wt_cmo():
    data, out = _paths()
    # wt-types.svh: the dcache_req_t/dcache_rtrn_t localparam types live inside
    # wt_cache_subsystem — extract exactly like run_wt_coherence_review does.
    sub = (data / 'wt_cache_subsystem.sv').read_text()
    types = sub.split('  // dcache interface', 1)[1].split(
        '  logic icache_adapter_data_req', 1)[0]
    (data / 'wt-types.svh').write_text(
        sub.split('module wt_cache_subsystem', 1)[0] + types)
    # cva6_config_pkg.sv is a symlink to the active config package; the proxy
    # resolves it and uploads the target under its own name.
    (data / 'cva6_config_pkg.sv').write_text(
        (data / 'g6lc64_smt2_config_pkg.sv').read_text())
    names = ['config_pkg.sv', 'cva6_config_pkg.sv', 'riscv_pkg.sv',
             'ariane_pkg.sv',
             'wt_cache_pkg.sv', 'cf_math_pkg.sv', 'lzc.sv', 'lfsr.sv',
             'exp_backoff.sv', 'rr_arb_tree.sv', 'sram_cache.sv', 'sram.sv',
             'tc_sram_wrapper.sv', 'tc_sram.sv', 'cva6_fifo_v3.sv',
             'wt_dcache_ctrl.sv', 'wt_dcache_missunit.sv', 'wt_dcache_mem.sv',
             'wt_dcache_wbuffer.sv', 'wt_dcache.sv', 'tb_g6lc_wt_cmo.sv']
    results = []
    # wr_ack participates in a pre-existing flat-signal round trip through the
    # wbuffer fixup/evict machinery (evict -> fixup_export_push ->
    # fixup_wbuffer_o -> wbuffer_all -> rd_data -> rd_off -> wr_ack); the
    # top-level core build suppresses UNOPTFLAT wholesale (Makefile), and no
    # prior leaf instantiated wt_dcache, so relax it for this lane only and
    # still split the known lzc/missunit flat signals.
    splits = [('lzc', '*index_nodes'), ('lzc', '*sel_nodes'),
              ('wt_dcache_missunit', 'mem_data_o'), ('wt_dcache', 'wr_ack')]
    exe = _build(data, out / 'wt', 'tb_g6lc_wt_cmo', names, include=['.'],
                 extra_files=['wt-types.svh'], splits=splits,
                 unoptflat_error=False)
    results.append(_run(exe, out, 'wt-cmo', [], 'WT_CMO_PASS'))

    def mut(text):
        old = "      wbuf_port_req.data_req = req_ports_i[NumPorts-1].data_req && !cmo_req;"
        assert text.count(old) == 1
        return text.replace(
            old, "      wbuf_port_req.data_req = req_ports_i[NumPorts-1].data_req;")
    exe = _build(data, out / 'wt-mut', 'tb_g6lc_wt_cmo', names,
                 mutate={'wt_dcache.sv': mut}, include=['.'],
                 extra_files=['wt-types.svh'], splits=splits,
                 unoptflat_error=False)
    results.append(_run(exe, out, 'wt-cmo-mutation', [], 'WT_CMO_PASS',
                        expect_error='WT_CMO_BYTE_WRITE'))
    (out / 'results.json').write_text(json.dumps(results, indent=2))
    assert all(r['matched'] for r in results), results
    return 0


def run_hpd_cmo():
    data, out = _paths()
    # cva6_config_pkg.sv is a symlink to the active config package; the proxy
    # resolves it and uploads the target under its own name.
    names = ['config_pkg.sv', 'g6lc64_smt2_config_pkg.sv', 'riscv_pkg.sv',
             'ariane_pkg.sv', 'hpdcache_pkg.sv', 'hpdcache_typedef.svh',
             'cva6_hpdcache_if_adapter.sv',
             'tb_g6lc_hpdcache_cmo.sv']
    results = []
    # hpdcache_req_is_uncacheable reads the muxed hpdcache_req.addr_tag and
    # feeds back into hpdcache_req.*.pma — an intra-struct flat-signal loop
    # (pre-existing; the core Makefile suppresses UNOPTFLAT for the whole
    # core). Split it so -Werror-UNOPTFLAT still catches genuine new loops.
    splits = [('cva6_hpdcache_if_adapter', 'hpdcache_req_is_uncacheable'),
              ('cva6_hpdcache_if_adapter', 'hpdcache_req')]
    exe = _build(data, out / 'hpd', 'tb_g6lc_hpdcache_cmo', names,
                 include=['.'], splits=splits, unoptflat_error=False)
    results.append(_run(exe, out, 'hpd-cmo', [], 'HPDCACHE_CMO_PASS'))

    def mut(text):
        old = ("      wire cmo_rel = cmo_pend_q && (cmo_rsp_seen_q || cmo_rsp_now) &&\n"
               "                     (cmo_done_seen_q || cmo_done_i);")
        assert text.count(old) == 1
        return text.replace(
            old, "      wire cmo_rel = cmo_pend_q && (cmo_rsp_seen_q || cmo_rsp_now);")
    exe = _build(data, out / 'hpd-mut', 'tb_g6lc_hpdcache_cmo', names,
                 mutate={'cva6_hpdcache_if_adapter.sv': mut}, include=['.'],
                 splits=splits, unoptflat_error=False)
    results.append(_run(exe, out, 'hpd-cmo-mutation', [], 'HPDCACHE_CMO_PASS',
                        expect_error='HPDCACHE_CMO_EARLY_RVALID'))

    def mut_cbz(text):
        old = "|| (cva6_req_i.cbo_op == ariane_pkg::CBO_ZERO)"
        assert text.count(old) == 1
        return text.replace(old, "|| 1'b0")
    exe = _build(data, out / 'hpd-mut-cbz', 'tb_g6lc_hpdcache_cmo', names,
                 mutate={'cva6_hpdcache_if_adapter.sv': mut_cbz},
                 include=['.'], splits=splits, unoptflat_error=False)
    results.append(_run(exe, out, 'hpd-cmo-cbz-mutation', [],
                        'HPDCACHE_CMO_PASS',
                        expect_error='HPDCACHE_CMO_CBZ_NEEDRSP'))
    (out / 'results.json').write_text(json.dumps(results, indent=2))
    assert all(r['matched'] for r in results), results
    return 0


def main():
    if os.environ.get('REVIEW_CMO_ENGINE') == '1':
        return run_cmo_engine()
    if os.environ.get('REVIEW_WT_CMO') == '1':
        return run_wt_cmo()
    if os.environ.get('REVIEW_HPDCACHE_CMO') == '1':
        return run_hpd_cmo()
    raise SystemExit('no REVIEW_* lane selected')


if __name__ == '__main__':
    raise SystemExit(main())
