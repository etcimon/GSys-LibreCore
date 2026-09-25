#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
import hashlib
import json
import os
from pathlib import Path
import subprocess


def run_fill():
    data, out = Path(os.environ['TH_DATA_DIR']), Path(os.environ['TH_OUT_DIR'])
    source = out / 'source'
    source.mkdir()
    names = ['config_pkg.sv', 'g6lc64_smt2_config_pkg.sv', 'riscv_pkg.sv', 'ariane_pkg.sv',
             'wt_cache_pkg.sv', 'cf_math_pkg.sv', 'lzc.sv', 'lfsr.sv', 'exp_backoff.sv',
             'wt_dcache_missunit.sv', 'tb_g6lc_wt_fill.sv']
    for name in names:
        (source / name).write_bytes((data / name).read_bytes())
    types_source = (data / 'wt_cache_subsystem.sv').read_text()
    types = types_source.split('  // dcache interface', 1)[1].split('  logic icache_adapter_data_req', 1)[0]
    (source / 'wt-types.svh').write_text(types_source.split('module wt_cache_subsystem', 1)[0] + types)
    hashes = {name: hashlib.sha256((source / name).read_bytes()).hexdigest() for name in names}
    hashes['wt-types.svh'] = hashlib.sha256((source / 'wt-types.svh').read_bytes()).hexdigest()
    (out / 'sources.json').write_text(json.dumps(hashes, indent=2))
    runtime = Path('/opt/testharness/runs/review-private-runtime-20260915/runtime')
    assert hashlib.sha256((runtime / 'include/verilated_funcs.h').read_bytes()).hexdigest() == \
        'dfbc2c4aa3c1065d4465027c893c9677de10da4cfe7fb152e485eb32b8125166'
    env = dict(os.environ, VERILATOR_ROOT=str(runtime), VPATH=str(runtime / 'include'))
    before = os.environ.get('REVIEW_WT_FILL_BEFORE') == '1'
    control = out / 'wt-fill.vlt'
    control.write_text(Path('/opt/testharness/runs/pmp-transition-split-20260919/output/source/split-counter.vlt').read_text() +
                       '\nsplit_var -module "wt_dcache_missunit" -var "mem_data_o"\n')
    (out / 'compiler-control.json').write_text(json.dumps({'sha256': hashlib.sha256(control.read_bytes()).hexdigest()}))
    results = []
    for coherence, cores in ([(1,1)] if before else [(0,1),(1,2),(0,2)]):
        mode = f'{coherence}-n{cores}'
        model = out / f'model-{mode}'
        command = ['verilator', '--cc', '--main', '--exe', '--timing', '--assert', '--threads', '1',
                   '-Wno-fatal', '-Werror-LATCH', '-Werror-UNOPTFLAT',
                   str(control),
                   '-I' + str(source), '--top-module', 'tb_g6lc_wt_fill', f'-GCOH={coherence}', f'-GNCORES={cores}',
                   '--Mdir', str(model), '-o', 'wt-fill', *[str(source / name) for name in names]]
        for label, command in [('verilate', command), ('build', ['make', '-C', str(model),
                               '-f', 'Vtb_g6lc_wt_fill.mk', '-j4'])]:
            with (out / f'{label}-{mode}.log').open('w') as log:
                rc = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=180).returncode
            assert rc == 0, label
        deps = '\n'.join(path.read_text() for path in model.glob('*.d'))
        assert str(runtime / 'include/verilated_funcs.h') in deps
        for scenario in range(6 if coherence or cores>1 else 4):
            for negative in ([False] if before else [False, True]):
                command = [str(model / 'wt-fill'), f'+scenario={scenario}'] + (['+oracle_negative'] if negative else [])
                run = subprocess.run(command, capture_output=True, text=True, timeout=30)
                text = run.stdout + run.stderr
                (out / f'coh{mode}-s{scenario}-negative{int(negative)}.log').write_text(text)
                error = 'WT_INVAL_FLUSH_COLLISION' if before and scenario in (4, 5) else \
                    'WT_INVAL_APPLY_SAME_CYCLE' if negative and scenario in (1, 2) else \
                    'WT_FILL_INSTALL' if negative or (before and scenario in (1, 3)) else None
                matched = (run.returncode != 0 and error in text and 'WT_FILL_PASS' not in text) if error else \
                    (run.returncode == 0 and text.count('WT_FILL_PASS') == 1 and '%Error' not in text)
                results.append({'coherence': coherence, 'cores': cores, 'scenario': scenario, 'negative': negative,
                                'expectedError': error, 'rc': run.returncode, 'matched': matched})
                (out / 'results.json').write_text(json.dumps(results, indent=2))
                assert matched, results[-1]
    return 0


def run_self_address():
    import re
    data, out = Path(os.environ['TH_DATA_DIR']), Path(os.environ['TH_OUT_DIR'])
    source = data / 'wt_axi_adapter.sv'
    text = source.read_text()
    before = os.environ.get('REVIEW_WT_SELF_ADDR_BEFORE') == '1'
    fault = os.environ.get('REVIEW_WT_SELF_ADDR_MUTATION') == '1'
    original_sha = hashlib.sha256(source.read_bytes()).hexdigest()
    if fault:
        old = "64'(self_inval_addr_q)"
        assert text.count(old) == 1
        text = text.replace(old, "64'(self_inval_addr_q[CVA6Cfg.DCACHE_INDEX_WIDTH-1:0])")
    declarations = '\n'.join(re.findall(r'^  logic [^\n;]*self_inval_[^\n;]*;', text, re.M))
    reset = '\n'.join(re.findall(r'^      self_inval_\w+_q\s+<=\s+[^\n;]*;',
                               text.split('begin : p_rd_buf', 1)[1].split('    end else begin', 1)[0], re.M))
    update = '\n'.join(re.findall(r'^      self_inval_\w+_q\s+<=\s+[^\n;]*;',
                                text.split('begin : p_rd_buf', 1)[1].split('    end else begin', 1)[1], re.M))
    assert declarations and reset and update
    decoder = '  always_comb begin : p_axi_rtrn_decode' + text.split('  always_comb begin : p_axi_rtrn_decode', 1)[1].split('\n  end\n', 1)[0] + '\n  end\n'
    apply = text.split('  if (CVA6Cfg.CohPolicy == config_pkg::COH_OOO) begin : gen_inval_apply', 1)[1].split('  // remote invalidations', 1)[0]
    apply = '  if (CVA6Cfg.CohPolicy == config_pkg::COH_OOO) begin : gen_inval_apply' + apply
    wrapper = text.split('module wt_axi_adapter', 1)[0] + '''
package config_pkg;
  localparam int COH_OOO=3;
endpackage
module wt_self_address_contract #(parameter bit NEGATIVE=0)(
input logic clk_i,rst_ni,invalidate,inval_valid_i,
input logic [55:0] dcache_paddr_i,
input logic [63:0] inval_addr_i,
output logic covered=0);
typedef struct packed {bit RVA;int DCACHE_INDEX_WIDTH;int PLEN;int CohPolicy;} cfg_t;
localparam cfg_t CVA6Cfg='{RVA:1,DCACHE_INDEX_WIDTH:12,PLEN:56,CohPolicy:3};
typedef struct packed {logic[55:0] paddr;} request_t;
request_t dcache_data;
assign dcache_data.paddr=dcache_paddr_i;
wire axi_rd_valid=0,axi_rd_last=0,dcache_wr_empty=1,b_empty=1,amo_gen_r_q=0;
wire [3:0] axi_rd_id_out=1,wr_id_out=0;
logic axi_rd_rdy,icache_rtrn_rd_en,icache_rtrn_vld_d;
logic dcache_rtrn_rd_en,dcache_rtrn_vld_d,dcache_rd_pop,dcache_wr_pop;
logic b_pop,dcache_sc_rtrn,inval_ready_o,inval_apply_valid_o;
logic [63:0] inval_apply_addr_o;
struct packed {logic vld;logic all;logic[11:0] idx;logic[1:0] way;} dcache_rtrn_inv_d;
wt_cache_pkg::dcache_in_t dcache_rtrn_type_d;
''' + declarations + '\nalways_ff @(posedge clk_i or negedge rst_ni) begin\nif(!rst_ni)begin\n' + reset + '\nend else begin\n' + update + '\nend\nend\n' + decoder + apply + '''
logic initialized=0;
logic owed_q,expected_valid_q;
logic [63:0] saved_q,expected_addr_q;
always_ff @(posedge clk_i) begin
  initialized<=1;
  if(!initialized)assume(!rst_ni);else assume(rst_ni);
  if(!rst_ni)begin
    owed_q<=0;saved_q<=0;expected_valid_q<=0;expected_addr_q<=0;covered<=0;
  end else begin
    owed_q<=invalidate && (owed_q || inval_valid_i);
    if(invalidate && (owed_q || inval_valid_i))saved_q<=64'(dcache_paddr_i);
    expected_valid_q<=owed_q || inval_valid_i || invalidate;
    expected_addr_q<=owed_q ? saved_q : inval_valid_i ? inval_addr_i : 64'(dcache_paddr_i);
    if(initialized)begin
      assert(inval_apply_valid_o==expected_valid_q);
      if(expected_valid_q)assert((inval_apply_addr_o ^ 64'(NEGATIVE))==expected_addr_q);
      if(owed_q)assert(!inval_ready_o);
      if(expected_valid_q && expected_addr_q[63:12]!=0 && inval_apply_addr_o==expected_addr_q)
        covered<=1;
    end
  end
end
endmodule
'''
    path = out / 'wt_self_address_contract.sv'
    path.write_text(wrapper)
    (out / 'sources.json').write_text(json.dumps({'original': original_sha,
        'effective': hashlib.sha256(text.encode()).hexdigest(),
        'wrapper': hashlib.sha256(wrapper.encode()).hexdigest(),
        'scope': 'extracted decoder, retained-state registers and apply registers; symbolic addresses, six frames'}, indent=2))
    results=[]
    for mode in (['before'] if before or fault else ['prove','negative','cover']):
        goal = '-prove covered 0' if mode=='cover' else '-prove-asserts'
        script=(f'read_slang --top wt_self_address_contract -GNEGATIVE={int(mode=="negative")} '
                f'{data}/wt_cache_pkg.sv {path}; prep -top wt_self_address_contract; flatten; '
                f'async2sync; chformal -lower; opt; sat -seq 6 -set-assumes {goal} -verify '
                f'-show-ports -dump_vcd {out}/{mode}.vcd')
        (out / f'{mode}.ys').write_text(script)
        with (out / f'{mode}.log').open('w') as log:
            rc=subprocess.run(['yosys','-p',script],stdout=log,stderr=subprocess.STDOUT,timeout=120).returncode
        output=(out / f'{mode}.log').read_text()
        expected_failure=mode!='prove'
        matched=(rc!=0 and 'model found: FAIL!' in output) if expected_failure else (
            rc==0 and 'no model found: SUCCESS!' in output and 'Import proof for assert' in output)
        results.append({'mode':mode,'rc':rc,'matched':matched,'restoredTruncation':fault})
        (out / 'results.json').write_text(json.dumps(results,indent=2))
        assert matched, mode
    return 0


def run_amo_apply():
    data, out = Path(os.environ['TH_DATA_DIR']), Path(os.environ['TH_OUT_DIR'])
    source = out / 'source'
    source.mkdir()
    names = ['config_pkg.sv', 'g6lc64_ooo_int2_config_pkg.sv', 'riscv_pkg.sv',
             'ariane_pkg.sv', 'build_config_pkg.sv', 'wt_cache_pkg.sv', 'axi_pkg.sv',
             'ariane_axi_pkg.sv', 'cf_math_pkg.sv', 'lzc.sv', 'rr_arb_tree.sv',
             'cva6_fifo_v3.sv', 'axi_shim.sv', 'wt_axi_adapter.sv',
             'tb_g6lc_wt_amo_apply.sv']
    for name in names:
        (source / name).write_bytes((data / name).read_bytes())
    types_source = (data / 'wt_cache_subsystem.sv').read_text()
    types = types_source.split('  // dcache interface', 1)[1].split('  logic icache_adapter_data_req', 1)[0]
    (source / 'wt-types.svh').write_text(types_source.split('module wt_cache_subsystem', 1)[0] + types)
    mutation = os.environ.get('REVIEW_WT_AMO_APPLY_MUTATION') == '1'
    original = {name: hashlib.sha256((source / name).read_bytes()).hexdigest() for name in names}
    if mutation:
        path = source / 'wt_axi_adapter.sv'
        text = path.read_text()
        old = '              invalidate = arb_gnt;'
        assert text.count(old) == 1
        path.write_text(text.replace(
            old, '              invalidate = arb_gnt && (dcache_data.amo_op != AMO_CAS1);'))
    hashes = {name: hashlib.sha256((source / name).read_bytes()).hexdigest() for name in names}
    hashes['wt-types.svh'] = hashlib.sha256((source / 'wt-types.svh').read_bytes()).hexdigest()
    (out / 'sources.json').write_text(json.dumps(
        {'original': original, 'effective': hashes, 'mutation': mutation,
         'scope': 'real wt_axi_adapter under g6lc64_ooo_int2 (COH_OOO, RVA, Zacas); '
                  'AMO apply-event and retained self-invalidation coverage'}, indent=2))
    runtime = Path('/opt/testharness/runs/review-private-runtime-20260915/runtime')
    assert hashlib.sha256((runtime / 'include/verilated_funcs.h').read_bytes()).hexdigest() == \
        'dfbc2c4aa3c1065d4465027c893c9677de10da4cfe7fb152e485eb32b8125166'
    env = dict(os.environ, VERILATOR_ROOT=str(runtime), VPATH=str(runtime / 'include'))
    control = out / 'wt-amo.vlt'
    control.write_text(
        Path('/opt/testharness/runs/pmp-transition-split-20260919/output/source/split-counter.vlt').read_text() +
        '\nsplit_var -module "wt_axi_adapter" -var "dcache_data_i"\n'
        'split_var -module "wt_axi_adapter" -var "dcache_rtrn_o"\n'
        'split_var -module "wt_axi_adapter" -var "icache_data_i"\n'
        'split_var -module "wt_axi_adapter" -var "icache_rtrn_o"\n'
        'split_var -module "wt_axi_adapter" -var "axi_req_o"\n'
        'split_var -module "wt_axi_adapter" -var "axi_resp_i"\n'
        'isolate_assignments -module "wt_axi_adapter" -var "arb_gnt"\n'
        'isolate_assignments -module "wt_axi_adapter" -var "axi_wr_req"\n'
        'isolate_assignments -module "wt_axi_adapter" -var "axi_wr_gnt"\n'
        'isolate_assignments -module "wt_axi_adapter" -var "axi_rd_req"\n'
        'isolate_assignments -module "wt_axi_adapter" -var "axi_rd_gnt"\n'
        'isolate_assignments -module "wt_axi_adapter" -var "axi_rd_rdy"\n')
    (out / 'compiler-control.json').write_text(json.dumps({'sha256': hashlib.sha256(control.read_bytes()).hexdigest()}))
    model = out / 'model'
    command = ['verilator', '--cc', '--main', '--exe', '--timing', '--assert', '--threads', '1',
               '-Wno-fatal', '-Werror-LATCH', '-Werror-UNOPTFLAT',
               str(control),
               '-I' + str(source), '--top-module', 'tb_g6lc_wt_amo_apply',
               '--Mdir', str(model), '-o', 'wt-amo',
               *[str(source / name) for name in names]]
    for label, command in [('verilate', command), ('build', ['make', '-C', str(model),
                           '-f', 'Vtb_g6lc_wt_amo_apply.mk', '-j4'])]:
        with (out / f'{label}.log').open('w') as log:
            rc = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=300).returncode
        assert rc == 0, (label, str(out / f'{label}.log'))
    deps = '\n'.join(path.read_text() for path in model.glob('*.d'))
    assert str(runtime / 'include/verilated_funcs.h') in deps
    results = []
    for scenario in range(4):
        for negative in [False, True]:
            command = [str(model / 'wt-amo'), f'+scenario={scenario}'] + \
                (['+oracle_negative'] if negative else [])
            run = subprocess.run(command, capture_output=True, text=True, timeout=60)
            text = run.stdout + run.stderr
            (out / f'scenario-{scenario}-negative-{int(negative)}.log').write_text(text)
            error = 'WT_AMO_INV_MISSING' if mutation and scenario in (1, 3) else \
                'WT_AMO_APPLY' if negative else None
            matched = (run.returncode != 0 and error in text and 'WT_AMO_PASS' not in text) if error else \
                (run.returncode == 0 and text.count('WT_AMO_PASS') == 1 and '%Error' not in text)
            results.append({'scenario': scenario, 'negative': negative, 'mutation': mutation,
                            'expectedError': error, 'rc': run.returncode, 'matched': matched})
            (out / 'results.json').write_text(json.dumps(results, indent=2))
            assert matched, results[-1]
    return 0


def main():
    if os.environ.get('REVIEW_WT_SELF_ADDR') == '1':
        return run_self_address()
    if os.environ.get('REVIEW_WT_AMO_APPLY') == '1' or \
            os.environ.get('REVIEW_WT_AMO_APPLY_MUTATION') == '1':
        return run_amo_apply()
    if os.environ.get('REVIEW_WT_FILL') == '1' or \
            os.environ.get('REVIEW_WT_FILL_BEFORE') == '1':
        return run_fill()
    data = Path(os.environ['TH_DATA_DIR'])
    out = Path(os.environ['TH_OUT_DIR'])
    source = data / 'wt_axi_adapter.sv'
    text = source.read_text()
    start = '  always_comb begin : p_axi_rtrn_decode'
    end = '  // remote invalidations are not supported yet'
    assert text.count(start) == 1 and text.count(end) == 1
    decoder = text.split(start, 1)[1].split('\n  end\n', 1)[0]
    decoder = start + decoder + '\n  end\n'
    header = text.split('module wt_axi_adapter', 1)[0]
    wrapper = header + '''module wt_return_contract #(
parameter bit NEGATIVE=0, parameter bit RVA=1)(
input logic invalidate,inval_valid_i,axi_rd_valid,axi_rd_last,
input logic [3:0] axi_rd_id_out,wr_id_out,
input logic dcache_wr_empty,b_empty,amo_gen_r_q,
input logic [63:0] inval_addr_i,dcache_paddr_i,
// The retained self-invalidation state is combinational-visible state for
// this contract: free inputs here; the sequential contract proves its update.
input logic self_inval_pend_q,
input logic [55:0] self_inval_addr_q);
typedef struct packed {bit RVA;int unsigned DCACHE_INDEX_WIDTH;int unsigned PLEN;} cfg_t;
localparam cfg_t CVA6Cfg='{RVA:RVA,DCACHE_INDEX_WIDTH:12,PLEN:56};
typedef struct packed {logic [63:0] paddr;} request_t;
request_t dcache_data;
assign dcache_data.paddr=dcache_paddr_i;
logic axi_rd_rdy,icache_rtrn_rd_en,icache_rtrn_vld_d;
logic dcache_rtrn_rd_en,dcache_rtrn_vld_d,dcache_rd_pop,dcache_wr_pop;
logic b_pop,dcache_sc_rtrn,inval_ready_o;
logic self_inval_pend_d;
logic [55:0] self_inval_addr_d;
struct packed {logic vld;logic all;logic[11:0] idx;logic[1:0] way;} dcache_rtrn_inv_d;
wt_cache_pkg::dcache_in_t dcache_rtrn_type_d;
''' + decoder + '''
always_comb begin
  if(axi_rd_valid && axi_rd_rdy && axi_rd_id_out[0]) begin
    assert(dcache_rtrn_rd_en ^ NEGATIVE);
    assert(dcache_rtrn_vld_d == axi_rd_last);
    assert(dcache_rd_pop || dcache_wr_pop || !axi_rd_last);
  end
  if(inval_valid_i && inval_ready_o) begin
    assert(dcache_rtrn_vld_d);
    assert(dcache_rtrn_type_d == wt_cache_pkg::DCACHE_INV_REQ);
    assert(dcache_rtrn_inv_d.idx == inval_addr_i[11:0]);
  end
end
endmodule
'''
    # Sequential contract for the retained self-invalidation (Part B): a
    # displaced AMO invalidate pulse must be captured and re-emitted before any
    # other return traffic. REVIEW_WT_SELF_INVAL_BEFORE restores the defect by
    # making self_inval_pend_d unreachable, so the P1 capture proof must fail.
    self_inval = os.environ.get('REVIEW_WT_SELF_INVAL') == '1'
    self_before = os.environ.get('REVIEW_WT_SELF_INVAL_BEFORE') == '1'
    if self_inval or self_before:
        seq_decoder = decoder
        if self_before:
            capture = ('if (CVA6Cfg.RVA && invalidate && '
                       '(self_inval_pend_q || inval_valid_i)) begin')
            assert seq_decoder.count(capture) == 1, 'self-inval capture site changed'
            seq_decoder = seq_decoder.replace(capture, "if (1'b0) begin")
        seq_wrapper = header + '''module wt_self_inval_contract #(
parameter bit NEGATIVE=0, parameter bit RVA=1)(
input logic clk_i,
input logic invalidate,inval_valid_i,axi_rd_valid,axi_rd_last,
input logic [3:0] axi_rd_id_out,wr_id_out,
input logic dcache_wr_empty,b_empty,amo_gen_r_q,
input logic [63:0] inval_addr_i,dcache_paddr_i,
output logic seen_displaced = 0);
typedef struct packed {bit RVA;int unsigned DCACHE_INDEX_WIDTH;int unsigned PLEN;} cfg_t;
localparam cfg_t CVA6Cfg='{RVA:RVA,DCACHE_INDEX_WIDTH:12,PLEN:56};
typedef struct packed {logic [63:0] paddr;} request_t;
request_t dcache_data;
assign dcache_data.paddr=dcache_paddr_i;
logic axi_rd_rdy,icache_rtrn_rd_en,icache_rtrn_vld_d;
logic dcache_rtrn_rd_en,dcache_rtrn_vld_d,dcache_rd_pop,dcache_wr_pop;
logic b_pop,dcache_sc_rtrn,inval_ready_o;
struct packed {logic vld;logic all;logic[11:0] idx;logic[1:0] way;} dcache_rtrn_inv_d;
wt_cache_pkg::dcache_in_t dcache_rtrn_type_d;
logic self_inval_pend_q, self_inval_pend_d;
logic [55:0] self_inval_addr_q, self_inval_addr_d;
always_ff @(posedge clk_i) begin
  self_inval_pend_q <= self_inval_pend_d;
  self_inval_addr_q  <= self_inval_addr_d;
end
''' + seq_decoder + '''
logic past_valid = 0;
always_ff @(posedge clk_i) past_valid <= 1;
always_ff @(posedge clk_i) begin
  // P1: a displaced pulse is captured -- pend is set the cycle after
  // invalidate && inval_valid_i.
  if (past_valid && $past(invalidate && inval_valid_i))
    assert (self_inval_pend_q ^ NEGATIVE);
  // P2: a pending self-invalidation is emitted as a DCACHE_INV_REQ carrying
  // its own index, and it blocks every other consumer that cycle.
  if (self_inval_pend_q) begin
    assert (dcache_rtrn_vld_d);
    assert (dcache_rtrn_type_d == wt_cache_pkg::DCACHE_INV_REQ);
    assert (dcache_rtrn_inv_d.idx == self_inval_addr_q[11:0]);
    assert (!inval_ready_o);
    assert (!dcache_rd_pop);
    assert (!b_pop);
  end
  if (past_valid && $past(invalidate && inval_valid_i) && self_inval_pend_q)
    seen_displaced <= 1;
end
endmodule
'''
        seq_path = out / 'wt_self_inval_contract.sv'
        seq_path.write_text(seq_wrapper)
        manifest = {'wt_axi_adapter.sv': hashlib.sha256(source.read_bytes()).hexdigest(),
                    'wt_cache_pkg.sv': hashlib.sha256((data / 'wt_cache_pkg.sv').read_bytes()).hexdigest(),
                    'selfInvalContract': hashlib.sha256(seq_wrapper.encode()).hexdigest(),
                    'selfInvalBefore': self_before,
                    'scope': 'source-extracted sequential return decoder; not the complete WT cache'}
        (out / 'sources.json').write_text(json.dumps(manifest, indent=2))
        results = []
        # In before mode the pend bit can never be set, so the NEGATIVE=1 form
        # (assert !self_inval_pend_q) is vacuously true: only the positive
        # proof, which must fail, discriminates the restored defect.
        for negative in ((0,) if self_before else (0, 1)):
            label = f'self-inval-negative{negative}'
            script = (f'read_slang --top wt_self_inval_contract -GRVA=1 -GNEGATIVE={negative} '
                      f'{data}/wt_cache_pkg.sv {seq_path}; prep -top wt_self_inval_contract; '
                      f'flatten; async2sync; chformal -lower; opt; sat -seq 4 -prove-asserts -verify '
                      f'-show-ports -dump_vcd {out}/{label}.vcd')
            with (out / f'{label}.log').open('w') as log:
                rc = subprocess.run(['yosys', '-p', script], stdout=log,
                                    stderr=subprocess.STDOUT, timeout=120).returncode
            log_text = (out / f'{label}.log').read_text()
            expected_failure = self_before or bool(negative)
            matched = (rc != 0 and 'model found: FAIL!' in log_text) if expected_failure else \
                (rc == 0 and 'no model found: SUCCESS!' in log_text)
            results.append({'contract': 'self-inval', 'negative': bool(negative),
                            'selfInvalBefore': self_before, 'rc': rc, 'matched': matched})
            (out / 'results.json').write_text(json.dumps(results, indent=2))
            assert matched, label
        if not self_before:
            # The displaced case must actually be reachable: proving
            # seen_displaced==0 must fail (a witness exists within 4 steps).
            label = 'self-inval-displaced-cover'
            script = (f'read_slang --top wt_self_inval_contract -GRVA=1 -GNEGATIVE=0 '
                      f'{data}/wt_cache_pkg.sv {seq_path}; prep -top wt_self_inval_contract; '
                      f'flatten; async2sync; chformal -lower; opt; sat -seq 4 -prove seen_displaced 0 '
                      f'-verify -show-ports -dump_vcd {out}/{label}.vcd')
            with (out / f'{label}.log').open('w') as log:
                rc = subprocess.run(['yosys', '-p', script], stdout=log,
                                    stderr=subprocess.STDOUT, timeout=120).returncode
            log_text = (out / f'{label}.log').read_text()
            matched = rc != 0 and 'model found: FAIL!' in log_text
            results.append({'contract': 'self-inval-displaced-cover', 'negative': False,
                            'selfInvalBefore': self_before, 'rc': rc, 'matched': matched})
            (out / 'results.json').write_text(json.dumps(results, indent=2))
            assert matched, label
        return 0
    wrapper_path = out / 'wt_return_contract.sv'
    wrapper_path.write_text(wrapper)
    manifest = {'wt_axi_adapter.sv': hashlib.sha256(source.read_bytes()).hexdigest(),
                'wt_cache_pkg.sv': hashlib.sha256((data / 'wt_cache_pkg.sv').read_bytes()).hexdigest(),
                'contract': hashlib.sha256(wrapper.encode()).hexdigest(),
                'scope': 'source-extracted combinational return decoder; not the complete WT cache'}
    (out / 'sources.json').write_text(json.dumps(manifest, indent=2))
    before = os.environ.get('REVIEW_WT_COH_BEFORE') == '1'
    results = []
    for rva in (0, 1):
        for negative in (0, 1):
            label = f'rva{rva}-negative{negative}'
            script = (f'read_slang --top wt_return_contract -GRVA={rva} -GNEGATIVE={negative} '
                      f'{data}/wt_cache_pkg.sv {wrapper_path}; prep -top wt_return_contract; '
                      f'flatten; chformal -lower; opt; sat -prove-asserts -verify -show-ports '
                      f'-dump_vcd {out}/{label}.vcd')
            with (out / f'{label}.log').open('w') as log:
                rc = subprocess.run(['yosys', '-p', script], stdout=log,
                                    stderr=subprocess.STDOUT, timeout=120).returncode
            log_text = (out / f'{label}.log').read_text()
            expected_failure = before or bool(negative)
            matched = (rc != 0 and 'model found: FAIL!' in log_text) if expected_failure else \
                (rc == 0 and 'no model found: SUCCESS!' in log_text and 'Import proof for assert' in log_text)
            results.append({'rva': rva, 'negative': bool(negative), 'before': before,
                            'rc': rc, 'matched': matched})
            (out / 'results.json').write_text(json.dumps(results, indent=2))
            assert matched, label
    print(json.dumps(results))


if __name__ == '__main__':
    main()
