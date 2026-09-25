#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Isolated two-core execution review for the promoted COH_OOO envelope.

Runs ON the remote host via testharness_proxy 'py'. Nothing here touches the
shared mirror: the mirror is copied once into the run directory, the HEAD
subset tarball pushed as data is extracted over that copy, and the Verilator
library is built beside it. Env:
  REVIEW_MC_TARGET   config package (default g6lc64_ooo_int2)
  REVIEW_MC_SEED     mirror to copy (default /opt/testharness/repo)
  REVIEW_MC_HEAD     git HEAD of the pushed subset (recorded only)
  REVIEW_MC_REBUILD  '1' forces a rebuild of an existing library
  REVIEW_MC_TIME_OUT DUT cycle bound (default 4000000)
  REVIEW_MC_BUILD_ONLY '1' builds REVIEW_MC_BUILD_TARGET and writes
      build-manifest.json only; the C++/bootrom compare input is produced by
      local_hashes.py in this directory (push its stdout as
      data/local-hashes.json).
Programs: mc_shared_line_coherence with the publisher on the second core
(PEER_HART=2) and on the sibling hart (PEER_HART=1), and the optimization
kernels linked with soak_entry.S, whose tohost encodes pass/fail and
mark_cycles (see the entry file). A SUCCESS at the cycle bound is not a pass.
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import tarfile
from pathlib import Path

GCC = ['$RISCV/bin/riscv-none-elf-gcc', '-march=rv64imac_zicsr', '-mabi=lp64', '-nostdlib',
       '-nostartfiles', '-T', 'verif/tests/custom/common/link_verilator.ld',
       '-I', 'verif/tests/custom/common']


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def bash(script, log, cwd, timeout):
    # env.sh exports CVA6_REPO_DIR for the shared mirror; every flist and
    # include path must resolve inside the isolated copy instead.
    prelude = ('set -euo pipefail\nset -a\n. /opt/testharness/env.sh\nset +a\n'
               f'export CVA6_REPO_DIR={cwd}\n')
    with Path(log).open('w') as handle:
        return subprocess.run(['bash', '-c', prelude + script], cwd=cwd, stdout=handle,
                              stderr=subprocess.STDOUT, timeout=timeout).returncode


def decode_soak(value):
    nibble, payload = value & 0xF, value >> 4
    if nibble == 0x3:
        return 'pass', payload
    if nibble == 0x1:
        return 'fail', payload
    if nibble == 0x5:
        return 'trap', payload
    return 'undecodable', value


def verdict(text, bound, kind, rc=0, expect_mask=None):
    banners = re.findall(r'\*\*\* (SUCCESS|FAILED) \*\*\* \(tohost = (\d+)(?:, seed \d+)?\) after (\d+) cycles', text)
    held = re.search(r'\[mc_verdict\] HELD: .*held_mask=([01x]+) retired_mask=([01x]+)', text)
    silent = re.search(r'\[mc_verdict\] FAIL: core\(s\) retired no instruction, retired_mask=([01x]+)'
                       r'(?: held_mask=([01x]+))?', text)
    program = re.search(r'\[mc_verdict\] program exit code (\d+)', text)
    record = {'tohost': int(banners[0][1]) if len(banners) == 1 else None,
              'cycles': int(banners[0][2]) if len(banners) == 1 else None,
              'assertions': len(re.findall(r'%Error|Assertion failed|%Fatal', text)),
              'allCoresRetired': '[mc_verdict] all 2 core(s) retired instructions' in text,
              'heldMask': held.group(1) if held else (silent.group(2) if silent else None),
              'retiredMask': held.group(2) if held else (silent.group(1) if silent else None),
              'programExit': int(program.group(1)) if program else None,
              'outcome': 'fail'}
    if record['assertions'] or len(banners) != 1:
        return record
    if record['cycles'] >= bound:
        record['outcome'] = 'timeout'
        return record
    if record['programExit']:
        return record
    if held:
        if expect_mask and int(expect_mask, 2) != (1 << len(expect_mask)) - 1:
            want = int(expect_mask, 2)
            if ((want & ~int(record['retiredMask'], 2)) == 0
                    and (want & int(record['heldMask'], 2)) == 0):
                record['outcome'] = 'pass'
                return record
        record['outcome'] = 'held-secondary'
        return record
    if not record['allCoresRetired'] or '[mc_verdict] FAIL:' in text:
        # Core 0 finished (its tracer raised exit) while a released secondary had
        # not retired (127), or a core ran and then stopped (126).
        record['outcome'] = 'incomplete'
    elif kind == 'soak':
        record['outcome'] = 'unvalidated-soak-encoding'
    elif rc == 0 and banners[0][0] == 'SUCCESS' and record['tohost'] == 0 and record['cycles'] > 0:
        record['outcome'] = 'pass'
    return record


def verdict_self_test():
    good = 'test.elf *** SUCCESS *** (tohost = 0) after 300 cycles\n*** [mc_verdict] all 2 core(s) retired instructions\n'
    held = ('test.elf *** FAILED *** (tohost = 125) after 300 cycles\n'
            '*** [mc_verdict] HELD: core(s) still clock-held at end of test, '
            'held_mask=10 retired_mask=01 (exit code 125)\n'
            '*** [mc_verdict] program exit code 0\n')
    silent = ('test.elf *** FAILED *** (tohost = 127) after 300 cycles\n'
              '*** [mc_verdict] FAIL: core(s) retired no instruction, retired_mask=01 '
              'held_mask=00 (exit code 127)\n*** [mc_verdict] program exit code 0\n')
    cases = [(good, 0, 'htif', 'pass'), (good, 1, 'htif', 'fail'),
             (good.replace('300 cycles', '1000 cycles'), 0, 'htif', 'timeout'),
             (good.replace('SUCCESS', 'FAILED').replace('tohost = 0', 'tohost = 1'), 1, 'htif', 'fail'),
             (good + good, 0, 'htif', 'fail'), ('', 0, 'htif', 'fail'),
             (good.split('\n')[0], 0, 'htif', 'incomplete'),
             (good + '%Error: invalid\n', 0, 'htif', 'fail'),
             (good + '*** [mc_verdict] FAIL: stopped\n', 0, 'htif', 'incomplete'),
             (good, 0, 'soak', 'unvalidated-soak-encoding'),
             (held, 125, 'htif', 'pass', '01'),
             (held, 125, 'htif', 'held-secondary', '11'),
             (held.replace('program exit code 0', 'program exit code 5'), 125, 'htif', 'fail', '01'),
             (silent, 127, 'htif', 'incomplete')]
    for case in cases:
        text, rc, kind, expected = case[:4]
        expect_mask = case[4] if len(case) > 4 else None
        got = verdict(text, 1000, kind, rc, expect_mask)['outcome']
        assert got == expected, (case, got)
    print(f'MC_VERDICT_PASS cases={len(cases)}')


def main():
    data, out = Path(os.environ['TH_DATA_DIR']), Path(os.environ['TH_OUT_DIR'])
    rundir = out.parent
    target = os.environ.get('REVIEW_MC_TARGET', 'g6lc64_ooo_int2')
    seed = Path(os.environ.get('REVIEW_MC_SEED', '/opt/testharness/repo'))
    bound = int(os.environ.get('REVIEW_MC_TIME_OUT', '4000000'))
    repo, verlib = rundir / 'repo', rundir / 'verlib'
    assert not repo.exists() and not verlib.exists(), 'use a fresh tag; unbound model reuse is forbidden'
    runtime = Path('/opt/testharness/runs/review-private-runtime-20260915/runtime')
    assert sha(runtime / 'include/verilated_funcs.h') == 'dfbc2c4aa3c1065d4465027c893c9677de10da4cfe7fb152e485eb32b8125166'
    tarball = data / 'head-subset.tar'
    manifest = {'target': target, 'seed': str(seed), 'head': os.environ.get('REVIEW_MC_HEAD'),
                'subsetSha256': sha(tarball), 'repo': str(repo), 'verlib': str(verlib),
                'sharedMirrorModified': False}
    if not repo.exists():
        assert seed.is_dir(), seed
        shutil.copytree(seed, repo, symlinks=True)
    with tarfile.open(tarball) as archive:
        archive.extractall(repo, filter='data')
    manifest['configSha256'] = sha(repo / 'core/include' / f'{target}_config_pkg.sv')
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2))

    model = verlib / 'Variane_testharness'
    if os.environ.get('REVIEW_MC_REBUILD') == '1' or not model.exists():
        rc = bash(f'export VERILATOR_ROOT={runtime}; '
                  f'SOFT_LADDER_VERLIB={verlib} SOFT_LADDER_BUILD_TARGET={target} '
                  f'SOFT_LADDER_VERILATOR_THREADS=1 SOFT_LADDER_BUILD_JOBS=8 bash verif/regress/soft-ladder-build-harness.sh B',
                  out / 'build.log', repo, timeout=4 * 3600)
        manifest['buildRc'] = rc
        (out / 'manifest.json').write_text(json.dumps(manifest, indent=2))
        assert rc == 0 and model.exists(), 'harness build'
    dependencies = '\n'.join(p.read_text(errors='replace') for p in verlib.glob('*.d'))
    assert str(runtime / 'include/verilated_funcs.h') in dependencies
    assert '/toolchains/verilator-v5.008/share/verilator/include/verilated_funcs.h' not in dependencies
    manifest['modelSha256'] = sha(model)
    manifest['runtimeHeader'] = sha(runtime / 'include/verilated_funcs.h')

    elfs = out / 'elf'
    elfs.mkdir(exist_ok=True)
    soak = 'optimization/tasks/coherence-shared-line/asm/soak_entry.S'
    programs = [
        # Controls first: can core 0 run anything, and does its second hart
        # execute. On a multi-core SMT configuration g6lc_cluster holds the
        # secondary cores until an IPI or 200000 cycles, and the harness forces
        # exit code 127 while any core has not retired, so these two report
        # tohost 127 by construction; they are recorded, not asserted.
        ('mc_boot_sanity', 'control', ['verif/tests/custom/multicore/mc_boot_sanity.S']),
        ('mc_hart1_alive', 'control', ['verif/tests/custom/multicore/mc_hart1_alive.S']),
        ('mc_shared_line_cross_core', 'htif', ['-DPEER_HART=2', 'verif/tests/custom/multicore/mc_shared_line_coherence.S']),
        ('mc_shared_line_sibling_hart', 'htif', ['-DPEER_HART=1', 'verif/tests/custom/multicore/mc_shared_line_coherence.S']),
        ('coherence_shared_line_cross_core', 'soak', ['-e', 'soak_start', '-Wl,--defsym=kernel_entry=_start',
            '-DPEER_HART=2', soak, 'optimization/tasks/coherence-shared-line/asm/coherence_shared_line.S']),
        ('cpu_ilp', 'soak', ['-e', 'soak_start', '-Wl,--defsym=kernel_entry=main',
            soak, 'optimization/tasks/coherence-shared-line/asm/cpu_ilp.S']),
    ]
    results = []
    for name, kind, sources in programs:
        elf = elfs / f'{name}.elf'
        rc = bash(' '.join(GCC + sources + ['-o', str(elf)]), out / f'{name}.gcc.log', repo, timeout=300)
        record = {'program': name, 'kind': kind, 'gccRc': rc}
        if rc == 0:
            record['elfSha256'] = sha(elf)
            # The harness polls tohost at +tohost_addr; without it a finished
            # program is indistinguishable from a hang (mc_hart1_alive.S header).
            symbols = subprocess.run(['bash', '-c', '. /opt/testharness/env.sh; riscv-none-elf-nm ' + str(elf)],
                                     capture_output=True, text=True, timeout=60).stdout
            tohost = re.search(r'^([0-9a-f]+) . tohost$', symbols, re.M)
            assert tohost, 'tohost symbol missing'
            record['tohostAddr'] = '0x' + tohost.group(1)
            log = out / f'{name}.run.log'
            try:
                rc = bash(f'{model} +time_out={bound} +debug_disable +quiet_axi +tohost_addr={record["tohostAddr"]} {elf}',
                          log, repo, timeout=2400)
                record['runRc'] = rc
                record.update(verdict(log.read_text(errors='replace'), bound, kind, rc))
            except subprocess.TimeoutExpired:
                record['outcome'] = 'wall-timeout'
        else:
            record['outcome'] = 'build-fail'
        results.append(record)
        (out / 'results.json').write_text(json.dumps({'manifest': manifest, 'results': results}, indent=2))
    assert all(r['outcome'] == 'pass' for r in results), [r['outcome'] for r in results]
    return 0


def inspect_boot_model():
    out = Path(os.environ['TH_OUT_DIR'])
    model_dir = Path(os.environ['REVIEW_MC_MODEL_DIR'])
    model = model_dir / 'Variane_testharness'
    pattern = re.compile(r'npc_rst_load|npc_bank_q|npc_q;|boot_hold_q|ipi_seen_q|core_clk|core_rst_n|'
                         r'arch_src;|arch_pc;|smt_restore;|smt_active_hart|fetch_address;|boot_addr_i;')
    selected = {}
    for path in model_dir.glob('*.h'):
        lines = path.read_text(errors='replace').splitlines()
        hits = [line.strip() for line in lines if pattern.search(line)]
        if hits:
            selected[path.name] = hits
    deps = {}
    for path in model_dir.glob('*.d'):
        text = path.read_text(errors='replace')
        matches = re.findall(r'\S*/verilated_funcs\.h', text)
        for match in matches:
            if Path(match).is_file():
                deps[match] = sha(match)
    runtime = Path('/opt/testharness/runs/review-private-runtime-20260915/runtime')
    fixed_header = runtime / 'include/verilated_funcs.h'
    for name in ('Variane_testharness.mk', 'Variane_testharness_classes.mk'):
        shutil.copy2(model_dir / name, out / name)
    summaries = {}
    for header in [*map(Path, deps), fixed_header]:
        text = header.read_text()
        start = text.index('VL_CONSTHI_W_1X')
        summaries[str(header)] = text[start:start + 2300]
    (out / 'boot-model.json').write_text(json.dumps({
        'model': str(model), 'modelSha256': sha(model), 'headers': selected,
        'runtimeHeaders': deps, 'fixedRuntimeHeader': sha(fixed_header),
        'runtimeFunctions': summaries}, indent=2))
    return 0


def exit_leaf_review():
    out, data = Path(os.environ['TH_OUT_DIR']), Path(os.environ['TH_DATA_DIR'])
    source = (data / 'ariane_testharness.sv').read_text()
    selection = re.search(r'  always_comb begin : mc_exit_select\n.*?\n  end', source, re.S)
    if selection:
        assert '.end_of_test_o(core_tracer_exit[0])' in source
        assert '.end_of_test_o(core_tracer_exit[c]' in source
        selection = selection[0]
    else:
        assert '.end_of_test_o(tracer_exit)' in source
        selection = 'assign tracer_exit = core_tracer_exit[0];'
    verdict_logic = re.search(r'    assign rvfi_exit = .*?;', source, re.S)[0]
    bench = '''module tb_g6lc_mc_exit;
parameter int NR_CORES=2;
logic [NR_CORES-1:0][31:0] core_tracer_exit;
logic [31:0] tracer_exit, rvfi_exit;
logic [NR_CORES-1:0] core_retired;
logic mc_all_silent_held, mc_any_hung;
int scenario;
bit negative;
@SELECTION@
@VERDICT@
initial begin
  scenario=0; void'($value$plusargs("scenario=%d",scenario));
  negative=$test$plusargs("oracle_negative");
  core_tracer_exit='0;core_retired='1;mc_all_silent_held=0;mc_any_hung=0;
  case(scenario)
    0: core_tracer_exit[0]=32'd1;
    1: core_tracer_exit[NR_CORES-1]=32'd1;
    2: core_tracer_exit[NR_CORES-1]=32'd11;
    3: begin core_tracer_exit[0]=32'd1;core_tracer_exit[NR_CORES-1]=32'd11;end
    4: begin core_tracer_exit[NR_CORES-1]=32'd1;core_retired[0]=0;end
    5: begin core_tracer_exit[NR_CORES-1]=32'd1;mc_any_hung=1;end
    6: begin core_tracer_exit[NR_CORES-1]=32'd1;core_retired[0]=0;mc_all_silent_held=1;end
    7: core_tracer_exit[NR_CORES-1]=32'd10;
    8: begin core_retired='0;mc_any_hung=1;end
    9: begin core_tracer_exit[0]=32'd11;core_tracer_exit[NR_CORES-1]=32'd1;end
    default: $fatal(1,"MC_EXIT_SCENARIO");
  endcase
  #1;
  case(scenario)
    0,1: if(rvfi_exit !== (32'd1 ^ 32'(negative))) $fatal(1,"MC_EXIT_ROUTE got=%h",rvfi_exit);
    2,3: if(rvfi_exit !== (32'd11 ^ 32'(negative))) $fatal(1,"MC_EXIT_FAILURE got=%h",rvfi_exit);
    4: if(rvfi_exit !== (32'd255 ^ 32'(negative))) $fatal(1,"MC_EXIT_SILENT got=%h",rvfi_exit);
    5: if(rvfi_exit !== (32'd253 ^ 32'(negative))) $fatal(1,"MC_EXIT_HUNG got=%h",rvfi_exit);
    6: if(rvfi_exit !== (32'd251 ^ 32'(negative))) $fatal(1,"MC_EXIT_HELD got=%h",rvfi_exit);
    7,8: if(rvfi_exit !== 32'(negative)) $fatal(1,"MC_EXIT_IDLE got=%h",rvfi_exit);
    9: if(rvfi_exit !== ((NR_CORES==1 ? 32'd1 : 32'd11) ^ 32'(negative))) $fatal(1,"MC_EXIT_PRIORITY got=%h",rvfi_exit);
  endcase
  $display("MC_EXIT_PASS scenario=%0d cores=%0d",scenario,NR_CORES);$finish;
end
endmodule
'''.replace('@SELECTION@', selection).replace('@VERDICT@', verdict_logic)
    path = out / 'tb_g6lc_mc_exit.sv'
    path.write_text(bench)
    runtime = Path('/opt/testharness/runs/review-private-runtime-20260915/runtime')
    assert sha(runtime / 'include/verilated_funcs.h') == 'dfbc2c4aa3c1065d4465027c893c9677de10da4cfe7fb152e485eb32b8125166'
    env = dict(os.environ, VERILATOR_ROOT=str(runtime), VPATH=str(runtime / 'include'))
    records = []
    (out / 'sources.json').write_text(json.dumps({'testharness': sha(data / 'ariane_testharness.sv'),
        'bench': sha(path), 'runner': sha(__file__)}, indent=2))
    for cores in (2, 1, 4):
        model = out / f'model-{cores}'
        cmd = ['verilator', '--binary', '--timing', '--assert', '-j', '4', '-Wno-fatal',
               '-Werror-LATCH', '-Werror-UNOPTFLAT', '--top-module', 'tb_g6lc_mc_exit',
               f'-GNR_CORES={cores}', '--Mdir', str(model), str(path)]
        with (out / f'build-{cores}.log').open('w') as log:
            assert subprocess.run(cmd, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=180).returncode == 0
        for scenario in range(10):
            for negative in (False, True):
                cmd = [str(model / 'Vtb_g6lc_mc_exit'), f'+scenario={scenario}'] + (['+oracle_negative'] if negative else [])
                result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
                text = result.stdout + result.stderr
                (out / f'n{cores}-s{scenario}-neg{int(negative)}.log').write_text(text)
                marker = ('MC_EXIT_ROUTE', 'MC_EXIT_ROUTE', 'MC_EXIT_FAILURE', 'MC_EXIT_FAILURE',
                          'MC_EXIT_SILENT', 'MC_EXIT_HUNG', 'MC_EXIT_HELD', 'MC_EXIT_IDLE',
                          'MC_EXIT_IDLE', 'MC_EXIT_PRIORITY')[scenario]
                matched = (result.returncode != 0 and marker in text and 'MC_EXIT_PASS' not in text) if negative else (result.returncode == 0 and 'MC_EXIT_PASS' in text)
                records.append({'cores': cores, 'scenario': scenario, 'negative': negative,
                                'expectedError': marker if negative else None,
                                'rc': result.returncode, 'matched': matched})
                (out / 'results.json').write_text(json.dumps(records, indent=2))
                assert matched, (cores, scenario, negative)
    return 0


def boot_reset_leaf():
    out, data = Path(os.environ['TH_OUT_DIR']), Path(os.environ['TH_DATA_DIR'])
    runtime = Path('/opt/testharness/runs/review-private-runtime-20260915/runtime')
    expected = 'dfbc2c4aa3c1065d4465027c893c9677de10da4cfe7fb152e485eb32b8125166'
    assert sha(runtime / 'include/verilated_funcs.h') == expected
    sources = ['config_pkg.sv', 'tc_clk.sv', 'rstgen.sv', 'rstgen_bypass.sv', 'g6lc_smt_pc_bank.sv']
    for name in sources:
        shutil.copy2(data / name, out / name)
    bench = '''module tb_g6lc_boot_reset(
input logic clk_i, rst_ni, release_i, active_i,
input logic [63:0] boot_i,
output logic [63:0] plain_pc_o, gated_pc_o);
function automatic config_pkg::cva6_cfg_t cfg();
  config_pkg::cva6_cfg_t c = config_pkg::cva6_cfg_empty;
  c.XLEN=64; c.VLEN=64; c.NrHarts=2; c.NrCommitPorts=2;
  return c;
endfunction
logic reset_n, gated_clk;
rstgen reset_gen(.clk_i, .rst_ni, .test_mode_i(1'b0), .rst_no(reset_n), .init_no());
tc_clk_gating #(.IS_FUNCTIONAL(1)) gate(.clk_i, .en_i(release_i), .test_en_i(1'b0), .clk_o(gated_clk));
for(genvar c=0;c<2;c++) begin : gen_bank
  logic [63:0] pc;
  g6lc_smt_pc_bank #(.CVA6Cfg(cfg())) bank(
    .clk_i(c ? gated_clk : clk_i), .rst_ni(reset_n), .boot_addr_i(boot_i),
    .npc_live_i('0), .npc_live_valid_i(1'b0),
    .redirect_valid_i(1'b0), .redirect_hart_i('0), .redirect_pc_i('0),
    .redirect2_valid_i(1'b0), .redirect2_hart_i('0), .redirect2_pc_i('0),
    .retire_valid_i('0), .retire_hart_i('0), .retire_pc_i('0),
    .active_hart_i(active_i), .switch_i(1'b1), .npc_alt_valid_i(1'b0), .npc_alt_i('0),
    .npc_restore_o(pc), .restore_o(), .outgoing_hart_o());
  if(c) assign gated_pc_o=pc; else assign plain_pc_o=pc;
end
endmodule
'''
    driver = '''#include "Vtb_g6lc_boot_reset.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  for (unsigned n=0; n<2; ++n) {
    Vtb_g6lc_boot_reset top;
    top.clk_i=0; top.rst_ni=0; top.release_i=0; top.active_i=0;
    const unsigned long long boot = n ? 0x80001280ULL : 0x10000ULL;
    top.boot_i=boot;
    auto tick=[&]() {top.clk_i=0;top.eval();top.clk_i=1;top.eval();};
    if (std::getenv("RESET_EDGE")) {top.rst_ni=1;for(int i=0;i<5;++i)tick();top.rst_ni=0;}
    for(int i=0;i<10;++i) tick();
    for(int phase=0;phase<3;++phase) {
      for(int h=0;h<2;++h) {
        top.active_i=h;top.eval();
        if(top.plain_pc_o!=boot || top.gated_pc_o!=(boot ^ (std::getenv("NEGATIVE") ? 1 : 0))) {
          std::printf("BOOT_RESET_STATE phase=%d hart=%d expected=%llx plain=%llx gated=%llx\\n",
            phase,h,boot,(unsigned long long)top.plain_pc_o,(unsigned long long)top.gated_pc_o);
          return 1;
        }
      }
      top.rst_ni=1;
      if(phase==1)top.release_i=1;
      for(int i=0;i<12;++i)tick();
    }
    top.final();
  }
  std::puts("BOOT_RESET_PASS");
}
'''
    (out / 'tb_g6lc_boot_reset.sv').write_text(bench)
    (out / 'main.cpp').write_text(driver)
    records = []
    env = dict(os.environ, VERILATOR_ROOT=str(runtime), VPATH=str(runtime / 'include'))
    for initial_edge in (False, True):
        model = out / f'model-{int(initial_edge)}'
        cmd = ['verilator', '--cc', '--exe', '--build', '-j', '4', '--assert', '--no-timing',
               '-Wno-fatal', '-Werror-LATCH', '-Werror-UNOPTFLAT', '+define+G6LC_FETCH_B',
               '--x-initial', '0', '--top-module', 'tb_g6lc_boot_reset', '--Mdir', str(model),
               *(['--x-initial-edge'] if initial_edge else []),
               *map(str, [out / name for name in sources]), str(out / 'tb_g6lc_boot_reset.sv'), str(out / 'main.cpp')]
        with (out / f'build-{int(initial_edge)}.log').open('w') as log:
            rc = subprocess.run(cmd, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=180).returncode
        assert rc == 0, cmd
        for pulse, negative in ((False, False), (True, False), (False, True)):
            trial_env = dict(env)
            if pulse:
                trial_env['RESET_EDGE'] = '1'
            if negative:
                trial_env['NEGATIVE'] = '1'
            run = subprocess.run([str(model / 'Vtb_g6lc_boot_reset')], env=trial_env,
                                 capture_output=True, text=True, timeout=30)
            want_pass = (initial_edge or pulse) and not negative
            matched = (run.returncode == 0 and 'BOOT_RESET_PASS' in run.stdout) if want_pass else (
                       run.returncode != 0 and 'BOOT_RESET_STATE' in run.stdout)
            records.append({'initialEdge': initial_edge, 'resetPulse': pulse, 'negative': negative,
                            'rc': run.returncode, 'matched': matched, 'output': run.stdout + run.stderr})
    (out / 'sources.json').write_text(json.dumps({name: sha(out / name) for name in sources}, indent=2))
    (out / 'results.json').write_text(json.dumps(records, indent=2))
    assert all(r['matched'] for r in records)
    return 0


def visibility_review():
    out = Path(os.environ['TH_OUT_DIR'])
    parent_path = Path(os.environ['REVIEW_MC_MANIFEST'])
    parent = json.loads(parent_path.read_text())
    # The parent is either an initial-review manifest (sourceRoot + plain digests)
    # or a build-only manifest (repo beside the model, original/review digests).
    seed = Path(parent['sourceRoot']) if 'sourceRoot' in parent else Path(parent['model']).parent.parent / 'repo'
    for name, digest in parent['sources'].items():
        assert sha(seed / name) == (digest if isinstance(digest, str) else digest['reviewSha256']), name
    runtime = Path('/opt/testharness/runs/review-private-runtime-20260915/runtime')
    runtime_header = parent.get('runtimeHeader') or parent['recipe']['runtimeHeader']
    assert sha(runtime / 'include/verilated_funcs.h') == runtime_header
    target = parent.get('target', 'g6lc64_ooo_int2')
    repo, model = out.parent / 'repo', out.parent / 'model'
    shutil.copytree(seed, repo, symlinks=True)
    changes = {}
    # Observation window and stuck-handshake detector. Defaults keep the
    # directed cases byte-identical (first 6000 time units, no detector); a
    # firmware run sets +mc_vis_from/+mc_vis_until and +mc_vis_stuck=<cycles>
    # so a channel whose valid is held without ready for that long is reported
    # once, with its payload, instead of logging every beat.
    window = '''logic vis_enabled; longint unsigned vis_from=0, vis_until=6000, vis_stuck=0;
initial begin
  vis_enabled=$test$plusargs("mc_visibility");
  void'($value$plusargs("mc_vis_from=%d", vis_from));
  void'($value$plusargs("mc_vis_until=%d", vis_until));
  void'($value$plusargs("mc_vis_stuck=%d", vis_stuck));
end
'''
    gate = 'rst_ni && vis_enabled && $time>=vis_from && $time<vis_until'

    def append_probe(name, body):
        path = repo / name
        original = sha(path)
        text = path.read_text()
        pos = text.index('\nendmodule')
        path.write_text(text[:pos] + '\n' + body + text[pos:])
        changes[name] = {'original': original, 'effective': sha(path)}

    def axi_probe(req, resp, label):
        result = []
        for ch in ('aw', 'w', 'b', 'ar', 'r'):
            producer, consumer = (resp, req) if ch in ('b', 'r') else (req, resp)
            names = {'aw': ('id', 'addr', 'len', 'size', 'cache'), 'w': ('data', 'strb', 'last'),
                     'b': ('id', 'resp'), 'ar': ('id', 'addr', 'len', 'size', 'cache'),
                     'r': ('id', 'data', 'resp', 'last')}[ch]
            fields = ' '.join(f'{name}=%h' for name in names)
            values = ', '.join(f'{producer}.{ch}.{name}' for name in names)
            result.append(f'if ({producer}.{ch}_valid && {consumer}.{ch}_ready) '
                          f'$display("VIS t=%0t %m {label} {ch} {fields}", $time, {values});')
        return '\n'.join(result)

    def stuck_probe(req, resp, label):
        # One report per channel per stall episode: valid held without ready for
        # vis_stuck cycles. Requests carry the address so the stalled transaction
        # is identifiable; responses carry the id.
        result = []
        for ch in ('aw', 'w', 'ar', 'b', 'r'):
            producer, consumer = (resp, req) if ch in ('b', 'r') else (req, resp)
            payload = {'aw': 'id=%h addr=%h atop=%h", $time, {p}.aw.id, {p}.aw.addr, {p}.aw.atop',
                       'w': 'last=%b", $time, {p}.w.last',
                       'ar': 'id=%h addr=%h", $time, {p}.ar.id, {p}.ar.addr',
                       'b': 'id=%h", $time, {p}.b.id',
                       'r': 'id=%h last=%b", $time, {p}.r.id, {p}.r.last'}[ch].replace('{p}', producer)
            result.append(f'''    if({producer}.{ch}_valid && !{consumer}.{ch}_ready) begin
      if(stuck_{ch}==vis_stuck) $display("VIS t=%0t %m STUCK {label} {ch} {payload});
      stuck_{ch}++;
    end else stuck_{ch}=0;''')
        return '\n'.join(result)

    cluster = window + '''for(genvar v=0;v<NC;v++) begin : gen_visibility
  longint unsigned stuck_aw=0, stuck_w=0, stuck_ar=0, stuck_b=0, stuck_r=0, stuck_inv=0;
  always @(posedge clk_i) if(''' + gate + ''') begin
''' + axi_probe('core_req[v]', 'core_resp[v]', 'core') + '''
    if(inv_to_core[v].valid && inv_core_ready[v])
      $display("VIS t=%0t %m inv addr=%h", $time, inv_to_core[v].line_addr);
  end
  always @(posedge clk_i) if(rst_ni && vis_enabled && vis_stuck!=0) begin
''' + stuck_probe('core_req[v]', 'core_resp[v]', 'core') + '''
    if(inv_to_core[v].valid && !inv_core_ready[v]) begin
      if(stuck_inv==vis_stuck) $display("VIS t=%0t %m STUCK core inv addr=%h", $time, inv_to_core[v].line_addr);
      stuck_inv++;
    end else stuck_inv=0;
  end
end
longint unsigned hub_stuck_aw=0, hub_stuck_w=0, hub_stuck_ar=0, hub_stuck_b=0, hub_stuck_r=0;
always @(posedge clk_i) if(''' + gate + ''') begin
''' + axi_probe('hub_mem_req', 'hub_mem_resp', 'hub') + '\n' + axi_probe('l2_mst_req', 'l2_mst_resp', 'l2') + '''
end
always @(posedge clk_i) if(rst_ni && vis_enabled && vis_stuck!=0) begin
''' + stuck_probe('hub_mem_req', 'hub_mem_resp', 'hub').replace('stuck_', 'hub_stuck_') + '\nend\n'
    append_probe('corev_apu/src/g6lc_cluster.sv', cluster)
    append_probe('corev_apu/clint/clint.sv', window + '''always @(posedge clk_i) if(''' + gate + ''') begin
  if(en) $display("VIS t=%0t %m clint we=%b addr=%h wdata=%h be=%h rdata=%h msip=%h next=%h",
    $time,we,address,wdata,be,rdata,msip_q,msip_n);
end
''')
    append_probe('core/cva6.sv', window + '''longint unsigned stuck_retire=0;
always @(posedge clk_i) if(rst_ni && vis_enabled && vis_stuck!=0) begin
  if($time>=vis_from && $time<vis_until)
    $display("VIS t=%0t %m COMMIT ack=%b pc0=%h fu0=%0d op0=%0d tid0=%0d v0=%b pc1=%h fu1=%0d tid1=%0d v1=%b csr_commit=%b csr_ex=%b flush_ex=%b flush_unissued=%b",
      $time, commit_ack, commit_instr_id_commit[0].pc, commit_instr_id_commit[0].fu, commit_instr_id_commit[0].op, commit_instr_id_commit[0].trans_id, commit_instr_id_commit[0].valid,
      commit_instr_id_commit[1].pc, commit_instr_id_commit[1].fu, commit_instr_id_commit[1].trans_id, commit_instr_id_commit[1].valid,
      csr_commit_commit_ex, csr_exception_csr_commit.valid, flush_ctrl_ex, flush_unissued_instr_ctrl_id);
  if(ex_commit.valid && ex_commit.cause == 64'd2)
    $display("VIS t=%0t %m ILLEGAL pc=%h tval=%h from_decode=%b decode_cause=%0d from_csr=%b fu=%0d op=%0d hart=%0d priv=%0d",
      $time, commit_instr_id_commit[0].pc, ex_commit.tval, commit_instr_id_commit[0].ex.valid, commit_instr_id_commit[0].ex.cause,
      csr_exception_csr_commit.valid, commit_instr_id_commit[0].fu, commit_instr_id_commit[0].op, commit_instr_id_commit[0].hart_id, priv_lvl);
  if(!(|commit_ack)) begin
    if(stuck_retire==vis_stuck) begin
      $display("VIS t=%0t %m STUCK retire head0 valid=%b pc=%h fu=%0d op=%0d hart=%0d ex=%b drop=%b | amo_valid_commit=%b amo_req=%b amo_op=%0d amo_addr=%h amo_ack=%b | no_st_pending_ex=%b wbuffer_empty=%b no_st_pending_commit=%b smt_sb_empty=%b flush_ctrl_id=%b halt_ctrl=%b halt_csr=%b lsu_commit_ready=%b",
        $time, commit_instr_id_commit[0].valid, commit_instr_id_commit[0].pc, commit_instr_id_commit[0].fu, commit_instr_id_commit[0].op,
        commit_instr_id_commit[0].hart_id, commit_instr_id_commit[0].ex.valid, commit_drop_id_commit[0],
        amo_valid_commit, amo_req.req, amo_req.amo_op, amo_req.operand_a, amo_resp.ack,
        no_st_pending_ex, dcache_commit_wbuffer_empty, no_st_pending_commit, smt_sb_empty, flush_ctrl_id, halt_ctrl, halt_csr_ctrl, lsu_commit_ready_ex_commit);
      $display("VIS t=%0t %m STUCK retire head1 valid=%b pc=%h fu=%0d op=%0d hart=%0d ex=%b",
        $time, commit_instr_id_commit[1].valid, commit_instr_id_commit[1].pc, commit_instr_id_commit[1].fu, commit_instr_id_commit[1].op,
        commit_instr_id_commit[1].hart_id, commit_instr_id_commit[1].ex.valid);
    end
    stuck_retire++;
  end else stuck_retire=0;
end
always @(posedge clk_i) if(''' + gate + ''') begin
  for(int p=0;p<3;p++) begin
    if(dcache_req_ports_ex_cache[p].data_req && dcache_req_ports_cache_ex[p].data_gnt)
      $display("VIS t=%0t %m dgrant port=%0d request=%p",$time,p,dcache_req_ports_ex_cache[p]);
    if(dcache_req_ports_cache_ex[p].data_rvalid)
      $display("VIS t=%0t %m dreturn port=%0d data=%h id=%h",$time,p,
        dcache_req_ports_cache_ex[p].data_rdata,dcache_req_ports_cache_ex[p].data_rid);
  end
end
''')
    append_probe('core/csr_regfile.sv', window + '''always @(posedge clk_i) if(rst_ni && vis_enabled && vis_stuck!=0) begin
  if(csr_exception_o.valid && (csr_op_i inside {CSR_READ, CSR_WRITE, CSR_SET, CSR_CLEAR}))
    $display("VIS t=%0t %m CSREXC op=%0d addr=%h cause=%0d priv=%0d read_exc=%b update_exc=%b priv_viol=%b debug=%b",
      $time, csr_op_i, csr_addr_i, csr_exception_o.cause, priv_lvl_o, read_access_exception, update_access_exception, privilege_violation, debug_mode_q);
end
''')
    append_probe('core/ex_stage.sv', window + '''always @(posedge clk_i) if((''' + gate + ''') || (rst_ni && vis_enabled && vis_stuck!=0 && (|csr_valid_i) && (one_cycle_select != csr_valid_i))) begin
  if(|csr_valid_i)
    $display("VIS t=%0t %m CSRISSUE csr_valid=%b alu_valid=%b branch_valid=%b one_cycle=%b p0_tid=%0d p0_op=%0d p0_b=%h p1_tid=%0d p1_op=%0d p1_b=%h picked_tid=%0d picked_b=%h",
      $time, csr_valid_i, alu_valid_i, branch_valid_i, one_cycle_select, fu_data_i[0].trans_id, fu_data_i[0].operation, fu_data_i[0].operand_b[11:0],
      fu_data_i[1].trans_id, fu_data_i[1].operation, fu_data_i[1].operand_b[11:0], one_cycle_data.trans_id, one_cycle_data.operand_b[11:0]);
end
''')
    append_probe('core/issue_read_operands.sv', window + '''always @(posedge clk_i) if(''' + gate + ''') begin
  for(int p=0;p<CVA6Cfg.NrIssuePorts;p++)
    if(issue_instr_valid_i[p])
      $display("VIS t=%0t %m ISSUE port=%0d ack=%b pc=%h fu=%0d op=%0d tid=%0d use_imm=%b result=%h fu_busy=%b csr_ready=%b flush=%b",
        $time, p, issue_ack_o[p], issue_instr_i[p].pc, issue_instr_i[p].fu, issue_instr_i[p].op, issue_instr_i[p].trans_id,
        issue_instr_i[p].use_imm, issue_instr_i[p].result[11:0], fu_busy[p], csr_ready_i, flush_i);
end
''')
    append_probe('core/csr_buffer.sv', window + '''logic vis_matched;
always_comb begin
  vis_matched = 1'b0;
  for (int unsigned i = 0; i < DEPTH; i++)
    if (tab_q[i].valid && (tab_q[i].tid == csr_commit_tid_i)) vis_matched = 1'b1;
end
always @(posedge clk_i) if(rst_ni && vis_enabled && (vis_stuck!=0 || ($time>=vis_from && $time<vis_until))) begin
  automatic logic matched;
  matched = vis_matched;
  if(csr_valid_i && $time>=vis_from && $time<vis_until)
    $display("VIS t=%0t %m CSRALLOC tid=%0d addr=%h op=%0d ready=%b tab=%p", $time, fu_data_i.trans_id, fu_data_i.operand_b[11:0], fu_data_i.operation, csr_ready_o, tab_q);
  if(csr_commit_i && (csr_addr_o == 12'h300 || csr_addr_o == 12'h341 || csr_addr_o == 12'h340 || !matched || ($time>=vis_from && $time<vis_until)))
    $display("VIS t=%0t %m CSRCOMMIT tid=%0d addr=%h matched=%b tab=%p valid_in=%b alloc_addr=%h alloc_tid=%0d",
      $time, csr_commit_tid_i, csr_addr_o, matched, tab_q, csr_valid_i, fu_data_i.operand_b[11:0], fu_data_i.trans_id);
end
''')
    append_probe('core/store_unit.sv', window + '''longint unsigned stuck_amo=0;
always @(posedge clk_i) if(rst_ni && vis_enabled && vis_stuck!=0) begin
  if(amo_buffer_valid || !amo_buffer_ready) begin
    if(stuck_amo==vis_stuck) $display("VIS t=%0t %m STUCK storeunit st_valid=%b amo_op=%0d amo_buffer_valid=%b amo_buffer_ready=%b store_buffer_ready=%b no_st_pending=%b amo_valid_commit=%b commit=%b",
      $time, st_valid, amo_op_q, amo_buffer_valid, amo_buffer_ready, store_buffer_ready, no_st_pending_o, amo_valid_commit_i, commit_i);
    stuck_amo++;
  end else stuck_amo=0;
end
''')
    append_probe('core/store_buffer.sv', window + '''longint unsigned stuck_sb=0;
always @(posedge clk_i) if(rst_ni && vis_enabled && vis_stuck!=0) begin
  if((speculative_status_cnt_q != 0 || commit_status_cnt_q != 0)) begin
    if(stuck_sb==vis_stuck) $display("VIS t=%0t %m STUCK storebuffer spec_cnt=%0d commit_cnt=%0d spec_head_mismatch=%b commit_i=%b stall_st_pending=%b spec_head=%p",
      $time, speculative_status_cnt_q, commit_status_cnt_q, spec_head_mismatch, commit_i, stall_st_pending_i, speculative_queue_q[speculative_read_pointer_q]);
    stuck_sb++;
  end else stuck_sb=0;
end
''')
    append_probe('core/cache_subsystem/wt_dcache_missunit.sv', window + '''longint unsigned stuck_drain=0;
always @(posedge clk_i) if(rst_ni && vis_enabled && vis_stuck!=0) begin
  if(state_q inside {DRAIN, AMO, AMO_WAIT}) begin
    if(stuck_drain==vis_stuck) $display("VIS t=%0t %m STUCK missunit state=%0d wbuffer_empty=%b mshr_vld=%b amo_req=%b amo_op=%0d amo_addr=%h",
      $time, state_q, wbuffer_empty_i, mshr_vld_q, amo_req_i.req, amo_req_i.amo_op, amo_req_i.operand_a);
    stuck_drain++;
  end else stuck_drain=0;
end
''')
    append_probe('core/cache_subsystem/wt_dcache_mem.sv', window + '''longint unsigned stuck_deny=0;
always @(posedge clk_i) if(rst_ni && vis_enabled && vis_stuck!=0) begin
  if((|wr_req_i) && !wr_ack_o) begin
    if(stuck_deny==vis_stuck) $display("VIS t=%0t %m STUCK wordwrite idx=%h off=%h ways=%h denied=%b clwr=%b rd_req=%b rd_ack=%h rd_idx0=%h rd_off0=%h rd_idx1=%h rd_off1=%h tagonly=%b sel=%0d",
      $time, wr_idx_i, wr_off_i, wr_req_i, wr_denied, wr_cl_vld_i, rd_req_i, rd_ack_o, rd_idx_i[0], rd_off_i[0], rd_idx_i[1], rd_off_i[1], rd_tag_only_i, vld_sel_d);
    stuck_deny++;
  end else stuck_deny=0;
end
''')
    append_probe('core/cache_subsystem/wt_dcache_wbuffer.sv', window + '''longint unsigned stuck_hold=0, stuck_full=0;
always @(posedge clk_i) if(rst_ni && vis_enabled && vis_stuck!=0) begin
  if(ack_wr_lost) begin
    if(stuck_hold==vis_stuck) $display("VIS t=%0t %m STUCK ackhold ptr=%0d wtag=%h checked=%b hit=%h wr_req=%h wr_ack=%b fixup_wr_req=%b check_wr=%b rd_req=%b rd_ack=%b tocheck=%h",
      $time, rtrn_ptr, wbuffer_q[rtrn_ptr].wtag, wbuffer_q[rtrn_ptr].checked, wbuffer_q[rtrn_ptr].hit_oh, wr_req_o, wr_ack_i, fixup_wr_req, check_wr, rd_req_o, rd_ack_i, tocheck);
    stuck_hold++;
  end else stuck_hold=0;
  if(!empty_o && !evict) begin
    if(stuck_full==vis_stuck) $display("VIS t=%0t %m STUCK wbuffer rtrn_empty=%b miss_req=%b miss_ack=%b tx=%p dirty=%h tocheck=%h buffers=%p",
      $time, rtrn_empty, miss_req_o, miss_ack_i, tx_stat_q, dirty, tocheck, wbuffer_q);
    stuck_full++;
  end else stuck_full=0;
end
always @(posedge clk_i) if(''' + gate + ''') begin
  if(miss_req_o && miss_ack_i)
    $display("VIS t=%0t %m wb_send addr=%h data=%h id=%h nc=%b",$time,miss_paddr_o,miss_wdata_o,miss_id_o,miss_nc_o);
  if(miss_rtrn_vld_i || (req_port_i.data_req && req_port_o.data_gnt) || wr_ack_i) begin
    $display("VIS t=%0t %m wb_state rtrn=%b id=%h wrack=%b buffers=%p fixup=%p",
      $time,miss_rtrn_vld_i,miss_rtrn_id_i,wr_ack_i,wbuffer_q,fixup_wbuffer_o);
  end
end
''')
    driver = repo / 'corev_apu/tb/g6lc_tb.cpp'
    text = driver.read_text()
    old = '    "mc_verdict_fault",'
    assert text.count(old) == 1
    driver.write_text(text.replace(old, '    "mc_visibility", "mc_vis_from", "mc_vis_until", "mc_vis_stuck",\n' + old))
    cmd = (f'export VERILATOR_ROOT={runtime} SOFT_LADDER_VERLIB={model} '
           f'SOFT_LADDER_BUILD_TARGET={target} SOFT_LADDER_VERILATOR_THREADS=1 '
           'SOFT_LADDER_BUILD_JOBS=8; bash verif/regress/soft-ladder-build-harness.sh B')
    rc = bash(cmd, out / 'build.log', repo, 3600)
    assert rc == 0, 'visibility build'
    dependencies = '\n'.join(p.read_text(errors='replace') for p in model.glob('*.d'))
    assert str(runtime / 'include/verilated_funcs.h') in dependencies
    exe = model / 'Variane_testharness'
    manifest = {'parent': str(parent_path), 'model': str(exe), 'modelSha256': sha(exe),
                'sourceRoot': str(repo), 'observers': changes, 'driverSha256': sha(driver),
                'runtimeHeader': runtime_header, 'target': target, 'build': cmd}
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2))
    if os.environ.get('REVIEW_MC_VISIBILITY_BUILD_ONLY') == '1':
        return 0
    cases = [('clint', Path('/opt/testharness/runs/ooocoh-boot-release-r2/output/negative0/boot.elf'), 20000),
             ('shared', Path('/opt/testharness/runs/ooocoh-mc-int2-r3/output/elf/mc_shared_line_cross_core.elf'), 100000)]
    records = []
    for name, elf, bound in cases:
        for enabled in (False, True):
            work = out / f'{name}-{int(enabled)}'
            work.mkdir()
            command = [str(exe), '--seed=1', '+debug_disable', '+quiet_axi',
                       f'+time_out={bound}', '+tohost_addr=0x80001000']
            if enabled:
                command += ['+mc_visibility']
            command.append(str(elf))
            with (work / 'run.log').open('w') as log:
                rc = subprocess.run(command, cwd=work, stdout=log, stderr=subprocess.STDOUT, timeout=180).returncode
            record = {'case': name, 'observe': enabled, 'rc': rc, 'elfSha256': sha(elf),
                      'retirement': {p.name: sha(p) for p in work.glob('trace_rvfi_hart_*.dasm')}}
            records.append(record)
            (out / 'results.json').write_text(json.dumps(records, indent=2))
        assert records[-1]['retirement'] == records[-2]['retirement'], 'observer changed retirement'
    return 0


def clint_lane_review():
    out, data = Path(os.environ['TH_OUT_DIR']), Path(os.environ['TH_DATA_DIR'])
    runtime = Path('/opt/testharness/runs/review-private-runtime-20260915/runtime')
    assert sha(runtime / 'include/verilated_funcs.h') == 'dfbc2c4aa3c1065d4465027c893c9677de10da4cfe7fb152e485eb32b8125166'
    names = ['config_pkg.sv', 'g6lc64_smt2_config_pkg.sv', 'axi_pkg.sv', 'ariane_axi_pkg.sv', 'axi_lite_interface.sv', 'clint.sv']
    for name in names:
        shutil.copy2(data / name, out / name)
    before = os.environ.get('CLINT_LANE_BEFORE') == '1'
    fault = os.environ.get('CLINT_LANE_FAULT') == '1'
    original = sha(out / 'clint.sv')
    if fault:
        path = out / 'clint.sv'
        text = path.read_text()
        old = 'rdata[32*address[2]] = msip_q[$unsigned(address[AddrSelWidth-1+2:2])];'
        assert text.count(old) == 1
        path.write_text(text.replace(old, 'rdata = msip_q[$unsigned(address[AddrSelWidth-1+2:2])];'))
    (out / 'sources.json').write_text(json.dumps({'originalClint': original,
        'effective': {name: sha(out / name) for name in names}, 'fault': fault}, indent=2))
    bench = '''module tb_clint_lane;
parameter bit RV32=0;
function automatic config_pkg::cva6_cfg_t cfg();
  config_pkg::cva6_cfg_t c=config_pkg::cva6_cfg_empty;
  c.XLEN=RV32 ? 32 : 64; c.IS_XLEN32=RV32; c.IS_XLEN64=!RV32;
  return c;
endfunction
logic clk=0,rst_n=0;
ariane_axi::req_t req='0;
ariane_axi::resp_t rsp;
logic [3:0] ipi,expected='0;
bit negative;
clint #(.CVA6Cfg(cfg()),.NR_CORES(4),.AXI_ID_WIDTH(ariane_axi::IdWidth)) dut(
  .clk_i(clk),.rst_ni(rst_n),.testmode_i(1'b0),.axi_req_i(req),.axi_resp_o(rsp),
  .rtc_i(1'b0),.timer_irq_o(),.ipi_o(ipi),.mtime_o());
task automatic tick; #2;clk=1;#2;clk=0;#2;endtask
task automatic wr(input int h,input bit value);
  req.aw='0;req.aw.addr=64'h2000000+64'(h*4);req.aw.id=ariane_axi::id_t'(h);
  req.aw.size=2;req.aw_valid=1;
  do begin #1; if(rsp.aw_ready)break; tick(); end while(1);
  tick();req.aw_valid=0;
  req.w='{data:64'(value)<<(32*(h%2)),strb:8'h0f<<(4*(h%2)),last:1,user:0};req.w_valid=1;
  do begin #1; if(rsp.w_ready)break; tick(); end while(1);
  tick();req.w_valid=0;req.b_ready=1;
  do begin #1; if(rsp.b_valid)break; tick(); end while(1);
  if(rsp.b.resp!=0 || rsp.b.id!=ariane_axi::id_t'(h))$fatal(1,"CLINT_WRITE_RESPONSE");
  tick();req.b_ready=0;expected[h]=value;
  if(ipi!==expected)$fatal(1,"CLINT_MSIP_STATE");
endtask
task automatic rd(input int h);
  logic [63:0] held;
  req.ar='0;req.ar.addr=64'h2000000+64'(h*4);req.ar.id=ariane_axi::id_t'(h);
  req.ar.size=2;req.ar_valid=1;req.r_ready=0;
  do begin #1; if(rsp.ar_ready)break; tick(); end while(1);
  tick();req.ar_valid=0;
  do begin #1; if(rsp.r_valid)break; tick(); end while(1);
  held=rsp.r.data;
  repeat(3)begin
    if(!rsp.r_valid || rsp.r.data!==held)$fatal(1,"CLINT_READ_STABILITY");
    tick();
  end
  if(rsp.r.resp!=0 || !rsp.r.last || rsp.r.id!=ariane_axi::id_t'(h))$fatal(1,"CLINT_READ_RESPONSE");
  if(((rsp.r.data>>(32*(h%2))) & 64'hffffffff)!=(64'(expected[h]) ^ 64'(negative)))
    $fatal(1,"CLINT_LANE h=%0d rv32=%b data=%h expected=%b",h,RV32,rsp.r.data,expected[h]);
  req.r_ready=1;tick();req.r_ready=0;
endtask
initial begin
  negative=$test$plusargs("oracle_negative");
  repeat(3)tick();rst_n=1;
  for(int h=0;h<4;h++)wr(h,1);
  for(int h=0;h<4;h++)rd(h);
  for(int h=0;h<4;h++)begin wr(h,0);for(int j=0;j<4;j++)rd(j);end
  $display("CLINT_LANE_PASS rv32=%b",RV32);$finish;
end
initial begin #10000;$fatal(1,"CLINT_WATCHDOG");end
endmodule
'''
    path = out / 'tb_clint_lane.sv'
    path.write_text(bench)
    env = dict(os.environ, VERILATOR_ROOT=str(runtime), VPATH=str(runtime / 'include'))
    records = []
    if os.environ.get('CLINT_LANE_SYNTH') == '1':
        top = out / 'clint_synth.sv'
        top.write_text('''module clint_synth(input logic clk_i,rst_ni,rtc_i,
input ariane_axi::req_t req_i,output ariane_axi::resp_t resp_o,
output logic [3:0] ipi_o,timer_irq_o,output logic [63:0] mtime_o);
function automatic config_pkg::cva6_cfg_t cfg();
config_pkg::cva6_cfg_t c=config_pkg::cva6_cfg_empty;
c.XLEN=64;c.IS_XLEN32=0;c.IS_XLEN64=1;return c;
endfunction
clint #(.CVA6Cfg(cfg()),.NR_CORES(4),.AXI_ID_WIDTH(ariane_axi::IdWidth)) dut(
.clk_i,.rst_ni,.rtc_i,.testmode_i(1'b0),.axi_req_i(req_i),.axi_resp_o(resp_o),
.ipi_o,.timer_irq_o,.mtime_o);
endmodule
''')
        script = 'read_slang --top clint_synth ' + ' '.join(str(out / n) for n in names) + f' {top}; '
        script += 'synth -top clint_synth -flatten; check -assert; scc -expect 0; stat'
        (out / 'synth.ys').write_text(script)
        with (out / 'synth.log').open('w') as log:
            rc = subprocess.run(['/opt/testharness/toolchains/formal/bin/yosys', '-p', script],
                                stdout=log, stderr=subprocess.STDOUT, timeout=180).returncode
        (out / 'synth-result.json').write_text(json.dumps({'rc': rc, 'passed': rc==0}))
        assert rc==0, 'clint synthesis'
        return 0
    for rv32 in (0, 1):
        model = out / f'model-{rv32}'
        command = ['verilator', '--cc', '--main', '--exe', '--build', '-j', '4', '--timing', '--assert',
                   '--x-initial-edge', '-Wno-fatal', '-Werror-LATCH', '-Werror-UNOPTFLAT', '--top-module', 'tb_clint_lane',
                   f'-GRV32={rv32}', '--Mdir', str(model), *[str(out / n) for n in names], str(path)]
        with (out / f'build-{rv32}.log').open('w') as log:
            rc = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=180).returncode
        assert rc == 0, 'clint build'
        for negative in ([False] if before or fault else [False, True]):
            result = subprocess.run([str(model / 'Vtb_clint_lane')] + (['+oracle_negative'] if negative else []),
                                    capture_output=True, text=True, timeout=30)
            output = result.stdout + result.stderr
            expected_failure = before or fault or negative
            matched = (result.returncode!=0 and 'CLINT_LANE h=' in output) if expected_failure else (
                       result.returncode==0 and 'CLINT_LANE_PASS' in output)
            records.append({'rv32': rv32, 'negative': negative, 'rc': result.returncode, 'matched': matched, 'output': output})
            (out / 'results.json').write_text(json.dumps(records, indent=2))
            assert matched, output
    return 0


def boot_release_review():
    out, data = Path(os.environ['TH_OUT_DIR']), Path(os.environ['TH_DATA_DIR'])
    manifest = json.loads(Path(os.environ['REVIEW_MC_MANIFEST']).read_text())
    exe = Path(manifest['model'])
    repo = Path(manifest['sourceRoot'])
    assert sha(exe) == manifest['modelSha256']
    records = []
    for negative in (False, True):
        trial = out / f'negative{int(negative)}'
        trial.mkdir()
        elf = trial / 'boot.elf'
        command = GCC + (['-DORACLE_NEGATIVE'] if negative else []) + [
            str(data / 'mc_smt2_boot_release.S'), '-o', str(elf)]
        rc = bash(' '.join(command), trial / 'gcc.log', repo, 120)
        assert rc == 0
        cmd = [str(exe), '--seed=1', '+debug_disable', '+quiet_axi', '+time_out=1000000',
               '+tohost_addr=0x80001000', str(elf)]
        with (trial / 'run.log').open('w') as log:
            rc = subprocess.run(cmd, cwd=trial, stdout=log, stderr=subprocess.STDOUT, timeout=120).returncode
        text = (trial / 'run.log').read_text()
        result = verdict(text, 1000000, 'htif', rc)
        matched = (result['outcome'] == 'fail' and result['tohost'] == 1 and
                   result['allCoresRetired'] and rc == 1) if negative else result['outcome'] == 'pass'
        records.append({'negative': negative, 'rc': rc, 'matched': matched,
                        'elfSha256': sha(elf), **result})
    (out / 'manifest.json').write_text(json.dumps({'modelSha256': sha(exe),
        'sourceSha256': sha(data / 'mc_smt2_boot_release.S'), 'parent': manifest['model']}, indent=2))
    (out / 'results.json').write_text(json.dumps(records, indent=2))
    assert all(r['matched'] for r in records)
    return 0


def directed_review():
    """One directed program on a frozen model (build-only or initial-review
    manifest): positive and oracle-negative arms, hart-0-only expectation
    (secondaries held), no RTL change."""
    out, data = Path(os.environ['TH_OUT_DIR']), Path(os.environ['TH_DATA_DIR'])
    manifest = json.loads(Path(os.environ['REVIEW_MC_MANIFEST']).read_text())
    exe = Path(manifest['model'])
    repo = Path(manifest['sourceRoot']) if 'sourceRoot' in manifest else exe.parent.parent / 'repo'
    assert sha(exe) == manifest['modelSha256']
    src = os.environ['REVIEW_MC_DIRECTED_SRC']
    bound = int(os.environ.get('REVIEW_MC_DIRECTED_BOUND', '1000000'))
    expect_mask = os.environ.get('REVIEW_MC_DIRECTED_MASK', '01')
    records = []
    for negative in (False, True):
        trial = out / f'negative{int(negative)}'
        trial.mkdir()
        elf = trial / 'directed.elf'
        command = GCC + (['-DORACLE_NEGATIVE'] if negative else []) + (
            ['-DEXIT_ON_SECONDARY'] if os.environ.get('REVIEW_MC_EXIT_SECONDARY') == '1' else []) + [str(data / src), '-o', str(elf)]
        rc = bash(' '.join(command), trial / 'gcc.log', repo, 120)
        assert rc == 0, 'gcc'
        cmd = [str(exe), '--seed=1', '+debug_disable', '+quiet_axi', f'+time_out={bound}',
               '+tohost_addr=0x80001000', str(elf)]
        with (trial / 'run.log').open('w') as log:
            rc = subprocess.run(cmd, cwd=trial, stdout=log, stderr=subprocess.STDOUT, timeout=1800).returncode
        text = (trial / 'run.log').read_text()
        result = verdict(text, bound, 'htif', rc, expect_mask)
        # Oracle-negative: the program reports exit code 1 (tohost 3). With the
        # secondaries clock-held the harness exit is the held-secondary code
        # (125) and the program's own code is carried in the verdict line.
        matched = ((result['programExit'] == 1 or (result['tohost'] == 1 and rc == 1))
                   and result['outcome'] != 'pass') if negative else result['outcome'] == 'pass'
        records.append({'negative': negative, 'rc': rc, 'matched': matched, 'elfSha256': sha(elf), **result})
        (out / 'results.json').write_text(json.dumps(records, indent=2))
    (out / 'manifest.json').write_text(json.dumps({'modelSha256': sha(exe), 'source': src,
        'sourceSha256': sha(data / src), 'parent': str(exe), 'bound': bound, 'expectMask': expect_mask}, indent=2))
    assert all(r['matched'] for r in records), [r['outcome'] for r in records]
    return 0


def boot_initial_review():
    out, data = Path(os.environ['TH_OUT_DIR']), Path(os.environ['TH_DATA_DIR'])
    seed = Path(os.environ['REVIEW_MC_SOURCE_DIR'])
    frozen = Path(os.environ['REVIEW_MC_FROZEN_OUTPUT'])
    runtime = Path('/opt/testharness/runs/review-private-runtime-20260915/runtime')
    expected = 'dfbc2c4aa3c1065d4465027c893c9677de10da4cfe7fb152e485eb32b8125166'
    assert sha(runtime / 'include/verilated_funcs.h') == expected
    repo, model = out.parent / 'repo', out.parent / 'model'
    shutil.copytree(seed, repo, symlinks=True)
    for relative in ('Makefile', 'verif/regress/soft-ladder-build-harness.sh'):
        shutil.copy2(data / Path(relative).name, repo / relative)
    overlay = [p for p in os.environ.get('REVIEW_MC_OVERLAY', '').split(',') if p]
    candidate = bool(overlay)
    for relative in overlay:
        shutil.copy2(data / Path(relative).name, repo / relative)
    inputs = {str(p.relative_to(repo)): sha(p) for base in ('core', 'corev_apu')
              for p in (repo / base).rglob('*') if p.is_file() and p.suffix in ('.sv', '.svh')}
    command = (f'export VERILATOR_ROOT={runtime} SOFT_LADDER_VERLIB={model} '
               'SOFT_LADDER_BUILD_TARGET=g6lc64_ooo_int2 SOFT_LADDER_VERILATOR_THREADS=12 '
               'SOFT_LADDER_BUILD_JOBS=8; bash verif/regress/soft-ladder-build-harness.sh B')
    rc = bash(command, out / 'build.log', repo, 3600)
    assert rc == 0, 'initial-edge full-model build'
    for name, digest in inputs.items():
        assert sha(repo / name) == digest, name
    dependencies = '\n'.join(p.read_text(errors='replace') for p in model.glob('*.d'))
    assert str(runtime / 'include/verilated_funcs.h') in dependencies
    assert '/toolchains/verilator-v5.008/share/verilator/include/verilated_funcs.h' not in dependencies
    exe = model / 'Variane_testharness'
    manifest = {'sources': inputs, 'modelSha256': sha(exe), 'runtimeHeader': expected,
                'sourceRoot': str(repo), 'model': str(exe), 'build': command,
                'makefileSha256': sha(repo / 'Makefile'), 'rtlModified': overlay}
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2))
    records = []
    cross_core = frozen / 'elf' / 'mc_shared_line_cross_core.elf'
    cases = [(name, frozen / 'elf' / f'{name}.elf', []) for name in
             ('release_probe', 'mc_shared_line_cross_core', 'mc_shared_line_sibling_hart', 'mc_boot_sanity', 'mc_hart1_alive')]
    cases.append(('cross_core_fault_control', cross_core, ['+mc_verdict_fault']))
    if candidate:
        base = Path('/opt/testharness/runs/ooocoh-boot-release-r2/output')
        cases += [('boot_release', base / 'negative0/boot.elf', []),
                  ('boot_negative', base / 'negative1/boot.elf', [])]
    # Expected verdict per case. The single-core-scope programs leave core 1
    # clock-held, which the testbench reports as a HELD verdict (exit 125) --
    # a pass when the expected core retired and the program's own exit was 0.
    expected = {'release_probe': {'kind': 'probe', 'outcome': 'timeout',
                                  'allCoresRetired': True, 'hart2Faults': 0},
                'mc_shared_line_cross_core': {'outcome': 'pass', 'mask': '11'},
                'mc_shared_line_sibling_hart': {'outcome': 'pass', 'mask': '01'},
                'mc_boot_sanity': {'outcome': 'pass', 'mask': '01'},
                'mc_hart1_alive': {'outcome': 'pass', 'mask': '01'},
                'cross_core_fault_control': {'outcome': 'incomplete', 'tohost': 127},
                'boot_release': {'outcome': 'pass', 'mask': '11'},
                'boot_negative': {'outcome': 'fail', 'programExit': 1, 'allCoresRetired': True}}
    for name, elf, extra in cases:
        trial = out / name
        trial.mkdir()
        bound = 20000 if name in ('release_probe', 'boot_release', 'boot_negative') else 4000000
        cmd = [str(exe), '--seed=1', '+debug_disable', '+quiet_axi',
               f'+time_out={bound}', '+tohost_addr=0x80001000', *extra, str(elf)]
        with (trial / 'run.log').open('w') as log:
            rc = subprocess.run(cmd, cwd=trial, stdout=log, stderr=subprocess.STDOUT, timeout=600).returncode
        text = (trial / 'run.log').read_text()
        traces = {}
        for path in trial.glob('trace_rvfi_hart_*.dasm'):
            lines = path.read_text().splitlines()
            traces[path.name] = {'sha256': sha(path), 'instructions': sum(line.startswith('core ') for line in lines),
                                 'faults': sum('INSTR_ACCESS_FAULT' in line for line in lines), 'first': lines[:20]}
        banners = re.findall(r'\*\*\* (SUCCESS|FAILED) \*\*\* \(tohost = (\d+)\) after (\d+) cycles', text)
        want = expected[name]
        result = verdict(text, bound, 'htif', rc, want.get('mask'))
        matched = result['outcome'] == want['outcome']
        if 'programExit' in want:
            matched = matched and result['programExit'] == want['programExit']
        if 'tohost' in want:
            matched = matched and result['tohost'] == want['tohost']
        if want.get('allCoresRetired'):
            matched = matched and result['allCoresRetired']
        if 'hart2Faults' in want:
            matched = matched and traces.get('trace_rvfi_hart_02.dasm', {}).get('faults', -1) == want['hart2Faults']
        record = {'name': name, 'elfSha256': sha(elf), 'rc': rc, 'banners': banners,
                  'traces': traces, 'expected': want, 'matched': matched}
        record.update(result)
        records.append(record)
        (out / 'results.json').write_text(json.dumps(records, indent=2))
    assert all(r['matched'] for r in records), \
        [(r['name'], r['outcome'], r['expected']) for r in records]
    return 0


def boot_reset_review():
    out = Path(os.environ['TH_OUT_DIR'])
    seed = Path(os.environ['REVIEW_MC_MODEL_DIR'])
    repo = Path(os.environ['REVIEW_MC_SOURCE_DIR'])
    runtime = Path('/opt/testharness/runs/review-private-runtime-20260915/runtime')
    expected = 'dfbc2c4aa3c1065d4465027c893c9677de10da4cfe7fb152e485eb32b8125166'
    assert sha(runtime / 'include/verilated_funcs.h') == expected
    canaries = Path('/opt/testharness/runs/review-private-runtime-rebuild-20260915/output/canaries.json')
    assert [(r['tag'], r['rc']) for r in json.loads(canaries.read_text())] == [('original', 1), ('fixed', 0)]
    shutil.copy2(canaries, out / 'canaries.json')
    model = out.parent / 'model'
    shutil.copytree(seed, model, ignore=shutil.ignore_patterns('*.o', '*.a', '*.d', '*.log',
                    'Variane_testharness', 'corev_apu', 'tool-wrap'))
    tb = model / 'corev_apu/tb'
    shutil.copytree(repo / 'corev_apu/tb', tb, ignore=shutil.ignore_patterns('*.o', '*.a', '*.d', '*.log'))
    mk = model / 'Variane_testharness.mk'
    text = mk.read_text()
    old_runtime = re.search(r'^VERILATOR_ROOT = (.+)$', text, re.M)[1]
    mk.write_text(text.replace(old_runtime, str(runtime)))
    driver = tb / 'g6lc_tb.cpp'
    original_driver = sha(driver)
    text = driver.read_text()
    marker = '  for (int i = 0; i < 10; i++) {'
    assert text.count(marker) == 1
    warmup = '''  if (std::getenv("G6LC_RESET_EDGE")) {
    top->rst_ni = 1;
    top->rtc_i = 0;
    for (int i = 0; i < 5; ++i) {
      top->clk_i = 0;
      top->eval();
      top->clk_i = 1;
      top->eval();
    }
  }
'''
    text = text.replace(marker, warmup + marker)
    probes = []
    prefix = 'ariane_testharness__DOT__i_cluster__DOT__'
    for core in range(2):
        base = prefix + f'gen_core__BRA__{core}__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6__DOT__'
        fields = {name: base + 'i_frontend__DOT__' + name for name in
                  ('npc_rst_load_q', 'npc_q', 'fetch_address', 'arch_src', 'arch_pc')}
        bank = base + 'i_smt_pc_bank__DOT__gen_banked__DOT__npc_bank_q'
        values = ' '.join(f'{key}=0x%llx' for key in fields)
        args = ', '.join(f'(unsigned long long)top->rootp->{field}' for field in fields.values())
        probes.append(f'      fprintf(stderr, "BOOT_STATE t=%llu core={core} rst=%u ipi=%u hold=%u '
                      f'{values} bank0=0x%llx bank1=0x%llx\\n", '
                      f'(unsigned long long)main_time, (unsigned)top->rst_ni, '
                      f'(unsigned)top->rootp->{prefix}ipi_seen_q, '
                      f'(unsigned)top->rootp->{prefix}boot_hold_q, {args}, '
                      f'((unsigned long long)top->rootp->{bank}[1] << 32) | top->rootp->{bank}[0], '
                      f'((unsigned long long)top->rootp->{bank}[3] << 32) | top->rootp->{bank}[2]);')
    observe = ('\n    if (std::getenv("G6LC_BOOT_OBSERVE") && main_time < 800) {\n' +
               '\n'.join(probes) + '\n    }\n')
    old = '    top->clk_i = 1;\n    top->eval();'
    assert text.count(old) == 2
    driver.write_text(text.replace(old, old + observe))
    generated = {p.name: sha(p) for p in seed.glob('Variane_testharness*.cpp')}
    assert all(sha(model / name) == digest for name, digest in generated.items())
    env = dict(os.environ, VERILATOR_ROOT=str(runtime), VPATH=str(runtime / 'include'))
    command = ['make', '-C', str(model), '-f', 'Variane_testharness.mk', '-j8']
    with (out / 'build.log').open('w') as log:
        rc = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=3600).returncode
    assert rc == 0, 'reset probe build'
    dependencies = '\n'.join(p.read_text(errors='replace') for p in model.glob('*.d'))
    assert str(runtime / 'include/verilated_funcs.h') in dependencies
    assert old_runtime + '/include/verilated_funcs.h' not in dependencies
    exe = model / 'Variane_testharness'
    elf = Path(os.environ['REVIEW_MC_PROBE_ELF'])
    manifest = {'seedModelSha256': sha(seed / exe.name), 'modelSha256': sha(exe),
                'elfSha256': sha(elf), 'generatedCpp': generated, 'originalDriver': original_driver,
                'effectiveDriver': sha(driver), 'runtimeHeader': expected, 'build': command,
                'rtlModified': False}
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2))
    records = []
    for edge, observe in ((False, False), (False, True), (True, True), (True, False)):
        case = out / f'edge{int(edge)}-observe{int(observe)}'
        case.mkdir()
        env = dict(os.environ)
        env.pop('G6LC_RESET_EDGE', None)
        env.pop('G6LC_BOOT_OBSERVE', None)
        if edge:
            env['G6LC_RESET_EDGE'] = '1'
        if observe:
            env['G6LC_BOOT_OBSERVE'] = '1'
        command = [str(exe), '--seed=1', '+debug_disable', '+quiet_axi',
                   '+time_out=20000', '+tohost_addr=0x80001000', str(elf)]
        with (case / 'run.log').open('w') as log:
            rc = subprocess.run(command, cwd=case, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=180).returncode
        traces = {}
        for trace in case.glob('trace_rvfi_hart_*.dasm'):
            lines = trace.read_text().splitlines()
            traces[trace.name] = {'sha256': sha(trace), 'instructions': sum(line.startswith('core ') for line in lines),
                                 'faults': sum('INSTR_ACCESS_FAULT' in line for line in lines), 'first': lines[:20]}
        records.append({'resetEdge': edge, 'observe': observe, 'rc': rc, 'traces': traces})
        (out / 'results.json').write_text(json.dumps(records, indent=2))
    return 0


def build_only_review():
    out, data = Path(os.environ['TH_OUT_DIR']), Path(os.environ['TH_DATA_DIR'])
    seed = Path(os.environ['REVIEW_MC_SOURCE_DIR'])
    target = os.environ['REVIEW_MC_BUILD_TARGET']
    threads = int(os.environ.get('REVIEW_MC_VERILATOR_THREADS', '1'))
    runtime = Path('/opt/testharness/runs/review-private-runtime-20260915/runtime')
    expected = 'dfbc2c4aa3c1065d4465027c893c9677de10da4cfe7fb152e485eb32b8125166'
    assert sha(runtime / 'include/verilated_funcs.h') == expected
    repo, model = out.parent / 'repo', out.parent / 'model'
    shutil.copytree(seed, repo, symlinks=True)
    for relative in ('Makefile', 'verif/regress/soft-ladder-build-harness.sh'):
        shutil.copy2(data / Path(relative).name, repo / relative)
    overlay = [p for p in os.environ.get('REVIEW_MC_OVERLAY', '').split(',') if p]
    for relative in overlay:
        shutil.copy2(data / Path(relative).name, repo / relative)
    fields = dict((name, int(value)) for name, value in re.findall(
        r"^\s*(NrCores|NrHarts)\s*:\s*unsigned'\(\s*(\d+)\s*\)",
        (repo / 'core/include' / f'{target}_config_pkg.sv').read_text(), re.M))
    for name in ('NrCores', 'NrHarts'):
        if name not in fields:
            raise RuntimeError(f'{target} config package has no {name} field')
    cores, harts_per_core = fields['NrCores'], fields['NrHarts']
    sources = {}
    for base in ('core', 'corev_apu'):
        for path in sorted((repo / base).rglob('*')):
            if path.is_file() and path.suffix in ('.sv', '.svh'):
                rel = str(path.relative_to(repo))
                origin = seed / rel
                sources[rel] = {'originalSha256': sha(origin) if origin.is_file() else '0' * 64,
                                'reviewSha256': sha(path)}
    # The SV set is already proven identical to the seed; this records the
    # C++/bootrom side, comparing local-tree hashes (pushed as data) against
    # the effective build inputs.
    comparison = {'files': {}, 'mismatches': []}
    local_hashes = data / 'local-hashes.json'
    if local_hashes.is_file():
        for rel, local in sorted(json.loads(local_hashes.read_text()).items()):
            entry = {'localSha256': local,
                     'seedSha256': sha(seed / rel) if (seed / rel).is_file() else None,
                     'reviewSha256': sha(repo / rel) if (repo / rel).is_file() else None}
            comparison['files'][rel] = entry
            if entry['reviewSha256'] != local:
                comparison['mismatches'].append(rel)
    control = Path('/opt/testharness/runs/pmp-transition-split-20260919/output/source/split-counter.vlt')
    vlt_args = (f'{control} +incdir+{repo}/corev_apu/tb +incdir+{repo}/corev_apu/src'
                if control.is_file() else '')
    command = (f'export VERILATOR_ROOT={runtime} SOFT_LADDER_VERLIB={model} '
               f'SOFT_LADDER_BUILD_TARGET={target} SOFT_LADDER_VERILATOR_THREADS={threads} '
               'SOFT_LADDER_BUILD_JOBS=8 SOFT_LADDER_BUILD_CLEAN=1 SOFT_LADDER_ISOLATED=1 '
               f"SOFT_LADDER_BUILD_VLT_ARGS='{vlt_args}'; "
               'bash verif/regress/soft-ladder-build-harness.sh B')
    rc = bash(command, out / 'build.log', repo, 3600)
    assert rc == 0, f'build-only model build failed for {target}'
    for rel, entry in sources.items():
        assert sha(repo / rel) == entry['reviewSha256'], rel
    dependencies = '\n'.join(p.read_text(errors='replace') for p in model.glob('*.d'))
    assert str(runtime / 'include/verilated_funcs.h') in dependencies
    assert '/toolchains/verilator-v5.008/share/verilator/include/verilated_funcs.h' not in dependencies
    exe = model / 'Variane_testharness'
    verfiles = (model / 'Variane_testharness__verFiles.dat').read_text()
    assert re.search(r'--threads\s+1(?:\s|["\'])', verfiles), 'verFiles lacks --threads 1'
    assert '/core/fetch_B/frontend.sv' in verfiles, 'verFiles lacks fetch_B frontend'
    assert not re.search(r'/(?:fetch_A|smt_legacy)/|Flist\.smt_legacy', verfiles)
    manifest = {'target': target, 'harts': cores * harts_per_core, 'cores': cores,
                'hartsPerCore': harts_per_core, 'qualificationOnly': True, 'rc': rc,
                'modelSha256': sha(exe), 'model': str(exe), 'sources': sources,
                'recipe': {'build': command, 'runtimeHeader': expected, 'threads': threads},
                'seed': str(seed), 'overlay': overlay,
                'compilerControl': {'path': str(control), 'sha256': sha(control)}
                                   if control.is_file() else None,
                'sourceComparison': comparison}
    (out / 'build-manifest.json').write_text(json.dumps(manifest, indent=2))
    print(json.dumps({'target': target, 'modelSha256': manifest['modelSha256'],
                      'sources': len(sources), 'mismatches': comparison['mismatches']}))
    return 0


if __name__ == '__main__':
    if os.environ.get('REVIEW_MC_BUILD_ONLY') == '1':
        raise SystemExit(build_only_review())
    if os.environ.get('REVIEW_CLINT_LANE') == '1':
        raise SystemExit(clint_lane_review())
    if os.environ.get('REVIEW_MC_VISIBILITY') == '1':
        raise SystemExit(visibility_review())
    if os.environ.get('REVIEW_MC_BOOT_RELEASE') == '1':
        raise SystemExit(boot_release_review())
    if os.environ.get('REVIEW_MC_DIRECTED') == '1':
        raise SystemExit(directed_review())
    if os.environ.get('REVIEW_MC_INITIAL_REVIEW') == '1':
        raise SystemExit(boot_initial_review())
    if os.environ.get('REVIEW_MC_EXIT_LEAF') == '1':
        raise SystemExit(exit_leaf_review())
    if os.environ.get('REVIEW_MC_RESET_LEAF') == '1':
        raise SystemExit(boot_reset_leaf())
    if os.environ.get('REVIEW_MC_RESET_PROBE') == '1':
        raise SystemExit(boot_reset_review())
    raise SystemExit(inspect_boot_model() if os.environ.get('REVIEW_MC_INSPECT') == '1' else main())
