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
import sys


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


FORMAL = r'''
// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
module g6lc_inval_contract
  import g6lc_coherence_pkg::*;
#(parameter bit NEGATIVE = 0)(
  input logic clk_i,
  input coh_inval_t request,
  input logic [2:0] targets, consumer_ready,
  output logic seen_blocked = 0, seen_departed = 0
);
  logic initial_reset = 1;
  logic past_valid = 0;
  wire rst_n = !initial_reset;
  always_ff @(posedge clk_i) begin
    initial_reset <= 0;
    past_valid <= rst_n;
  end
  coh_inval_t [2:0] delivered;
  logic ready, blocked, coalesced;
  logic expected_ready, any_merge;
  g6lc_inval_bus #(.NR_CORES(3), .DEPTH(2)) dut (
    .clk_i, .rst_ni(rst_n), .inv_req_i(request), .inv_target_i(targets),
    .inv_ready_o(ready), .inv_core_o(delivered), .inv_core_ready_i(consumer_ready),
    .inv_stall_o(blocked), .inv_coalesce_o(coalesced)
  );
  always_comb begin
    expected_ready = 1;
    any_merge = 0;
    for (int c = 0; c < 3; c++) begin
      logic retained_match;
      int tail;
      tail = (int'(dut.gen_multi.tail_q[c]) + 1) % 2;
      retained_match = dut.gen_multi.count_q[c] != 0 &&
                       dut.gen_multi.fifo_q[c][tail].valid &&
                       dut.gen_multi.fifo_q[c][tail].line_addr == request.line_addr &&
                       !(dut.gen_multi.count_q[c] == 1 && consumer_ready[c]);
      if (request.valid && targets[c]) begin
        expected_ready &= dut.gen_multi.count_q[c] < 2 || retained_match;
        any_merge |= retained_match;
      end
    end
  end
  always_ff @(posedge clk_i) begin
    if (rst_n) begin
      assert ((ready ^ NEGATIVE) == expected_ready);
      assert (blocked == (request.valid && !ready));
      assert (coalesced == (request.valid && ready && any_merge));
      for (int c = 0; c < 3; c++) begin
        assert (dut.gen_multi.count_q[c] <= 2);
        assert (delivered[c].valid == (dut.gen_multi.count_q[c] != 0));
        if (past_valid && $past(request.valid && ready && targets[c] &&
            dut.gen_multi.count_q[c] == 1 && consumer_ready[c]))
          assert (delivered[c] == $past(request));
      end
      if (request.valid && !ready && any_merge) seen_blocked <= 1;
      if (request.valid && ready && targets[0] &&
          dut.gen_multi.count_q[0] == 1 && consumer_ready[0]) seen_departed <= 1;
    end
  end
endmodule
'''


def quality_review(out, data):
    work = out / 'quality'
    work.mkdir()
    package = data / 'g6lc_coherence_pkg.sv'
    candidate = data / 'g6lc_inval_bus.sv'
    original = Path('/opt/testharness/runs/review-inval-before-20260916/output/source/g6lc_inval_bus.sv')
    assert digest(original) == 'a8a78d0368333069ec09b75d0495b033295e954e6158c127c92af195dc719c7d'
    harness = work / 'contract.sv'
    harness.write_text(FORMAL)
    results = []
    def run(label, script, expected=None):
        script_path = work / (label + '.ys')
        script_path.write_text(script)
        with (work / (label + '.log')).open('w') as log:
            p = subprocess.run(['yosys', '-s', str(script_path)], cwd=work, stdout=log, stderr=subprocess.STDOUT, timeout=120)
        text = (work / (label + '.log')).read_text()
        matched = p.returncode != 0 and expected in text if expected else p.returncode == 0
        results.append({'label': label, 'rc': p.returncode, 'expectedError': expected, 'matched': matched})
        (out / 'quality.json').write_text(json.dumps(results, indent=2))
        assert matched, label
        return text
    for label, rtl, negative in [('before', original, False), ('after', candidate, False), ('negative', candidate, True)]:
        instance = work / (label + '-contract.sv')
        instance.write_text(FORMAL.replace('NEGATIVE = 0', 'NEGATIVE = 1') if negative else FORMAL)
        script = f'read_slang --std 1800-2017 --top g6lc_inval_contract {package} {rtl} {instance}\n'
        script += 'prep -top g6lc_inval_contract\nasync2sync\nchformal -lower\nflatten\nmemory_map\nopt -full\ndffunmap\nopt_clean -purge\n'
        script += f'write_rtlil {label}.il\nsat -seq 8 -prove-asserts -show-ports -dump_vcd {label}.vcd -verify\n'
        text = run(label, script, 'proof did fail' if label != 'after' else None)
        assert ('model found: FAIL!' if label != 'after' else 'no model found: SUCCESS!') in text
    for goal in ['seen_blocked', 'seen_departed']:
        text = run(goal, f'read_rtlil after.il\nchformal -assert -remove\nsat -seq 8 -prove {goal} 0 -prove-skip 7 -show-ports -dump_vcd {goal}.vcd -verify\n', 'proof did fail')
        assert 'model found: FAIL!' in text
    areas = []
    for cores, depth in [(1, 1), (3, 2), (4, 4)]:
        wrapper = work / f'shape-{cores}-{depth}.sv'
        wrapper.write_text(f'// Copyright (c) 2026 Etienne Cimon\n// SPDX-License-Identifier: MIT\nmodule leaf import g6lc_coherence_pkg::*; (input logic clk_i, rst_ni, input coh_inval_t request, input logic [{cores-1}:0] targets, consumer_ready, output coh_inval_t [{cores-1}:0] delivered, output logic ready, blocked, coalesced);\ng6lc_inval_bus #(.NR_CORES({cores}), .DEPTH({depth})) dut (.clk_i, .rst_ni, .inv_req_i(request), .inv_target_i(targets), .inv_core_ready_i(consumer_ready), .inv_core_o(delivered), .inv_ready_o(ready), .inv_stall_o(blocked), .inv_coalesce_o(coalesced));\nendmodule\n')
        for role, rtl in [('before', original), ('after', candidate)]:
            label = f'synth-{role}-{cores}-{depth}'
            script = f'read_slang --std 1800-2017 --top leaf {package} {rtl} {wrapper}\nsynth -top leaf -flatten\ncheck -assert\nwrite_json {label}.json\n'
            run(label, script)
            cells = json.loads((work / (label + '.json')).read_text())['modules']['leaf']['cells']
            types = [c['type'] for c in cells.values()]
            assert not any('LATCH' in kind.upper() for kind in types)
            areas.append({'role': role, 'cores': cores, 'depth': depth, 'cells': len(types), 'sequentialCells': sum('DFF' in kind.upper() for kind in types), 'sourceSha256': digest(rtl), 'physicalArea': None})
    (out / 'area.json').write_text(json.dumps(areas, indent=2))
    (out / 'sources.json').write_text(json.dumps({'before': digest(original), 'after': digest(candidate), 'package': digest(package), 'formalHarness': digest(harness)}, indent=2))
    return 0


HUB_FORMAL = r'''
// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
module hub_contract
  import config_pkg::*;
  import g6lc_coherence_pkg::*;
  import g6lc_l2_tb_pkg::*;
#(parameter int CORES=2, LIMIT=4, parameter bit NEGATIVE=0)(
  input logic clk_i,
  input req_t [CORES-1:0] requests,
  input resp_t memory_response,
  input logic [CORES-1:0] inv_ready,
  output logic seen_pair=0, seen_credit=0
);
  logic initial_reset=1, past_valid=0;
  wire rst_n = !initial_reset;
  req_t memory_request;
  resp_t [CORES-1:0] responses;
  coh_inval_t [CORES-1:0] invalidations;
  logic [CORES-1:0] ar_acks, aw_acks, ar_valids, aw_valids;
  g6lc_coherence_hub #(.NR_CORES(CORES), .MAX_OUTSTANDING(LIMIT),
    .INVAL_DEPTH(2), .SNOOP_FILTER_EN(0), .SNOOP_FILTER_ENTRIES(4),
    .POLICY(COH_BROADCAST), .AXI_STARVE_LIMIT(16), .axi_req_t(req_t), .axi_resp_t(resp_t)) dut (
    .clk_i, .rst_ni(rst_n), .core_req_i(requests), .core_resp_o(responses),
    .mem_req_o(memory_request), .mem_resp_i(memory_response),
    .inv_core_o(invalidations), .inv_core_ready_i(inv_ready),
    .lr_valid_i(1'b0), .lr_addr_i('0), .lr_core_i('0),
    .coh_inv_fire_o(), .coh_sf_hit_o(), .coh_sf_overapprox_o(),
    .coh_arb_starve_o(), .coh_split_conflict_o(), .coh_sc_noresv_o(), .coh_lr_kill_o()
  );
  always_ff @(posedge clk_i) begin
    initial_reset <= 0;
    past_valid <= rst_n;
  end
  for (genvar c=0; c<CORES; c++) begin : gen_master
    assign ar_acks[c] = responses[c].ar_ready;
    assign aw_acks[c] = responses[c].aw_ready;
    assign ar_valids[c] = requests[c].ar_valid;
    assign aw_valids[c] = requests[c].aw_valid;
    always_ff @(posedge clk_i) begin
      if (rst_n && past_valid) begin
        if ($past(requests[c].ar_valid && !responses[c].ar_ready)) begin
          assume (requests[c].ar_valid);
          assume (requests[c].ar == $past(requests[c].ar));
        end
        if ($past(requests[c].aw_valid && !responses[c].aw_ready)) begin
          assume (requests[c].aw_valid);
          assume (requests[c].aw == $past(requests[c].aw));
        end
      end
    end
  end
  if (CORES==1) begin : gen_identity
    always_ff @(posedge clk_i) if (rst_n) begin
      assert (memory_request == requests[0]);
      assert (responses[0] == memory_response);
      assert (invalidations == '0);
    end
  end else begin : gen_multi
    ar_chan_t observed_ar;
    always_comb begin
      observed_ar = memory_request.ar;
      if (NEGATIVE) observed_ar.addr[0] ^= 1'b1;
    end
    always_ff @(posedge clk_i) if (rst_n) begin
      if (past_valid && $past(memory_request.ar_valid && !memory_response.ar_ready)) begin
        assert (memory_request.ar_valid);
        assert (memory_request.ar == $past(memory_request.ar));
      end
      if (past_valid && $past(memory_request.aw_valid && !memory_response.aw_ready)) begin
        assert (memory_request.aw_valid);
        assert (memory_request.aw == $past(memory_request.aw));
      end
      assert ($countones(ar_acks) == int'(memory_request.ar_valid && memory_response.ar_ready));
      assert ($countones(aw_acks) == int'(memory_request.aw_valid && memory_response.aw_ready));
      if (memory_request.ar_valid) assert (int'(memory_request.ar.id) < LIMIT);
      if (memory_request.aw_valid) assert (int'(memory_request.aw.id) < LIMIT);
      if (memory_request.ar_valid && memory_request.aw_valid)
        assert (memory_request.ar.id != memory_request.aw.id);
      for (int c=0; c<CORES; c++) begin
        ar_chan_t expected_ar;
        aw_chan_t expected_aw;
        expected_ar = requests[c].ar;
        expected_ar.id = memory_request.ar.id;
        expected_aw = requests[c].aw;
        expected_aw.id = memory_request.aw.id;
        if (ar_acks[c]) begin
          assert (requests[c].ar_valid);
          assert (observed_ar == expected_ar);
        end
        if (aw_acks[c]) begin
          assert (requests[c].aw_valid);
          assert (memory_request.aw == expected_aw);
        end
      end
      for (int s=0; s<LIMIT; s++) begin
        assert (!(dut.gen_cluster.ar_ot_q[s].valid && dut.gen_cluster.aw_ot_q[s].valid));
        if ((memory_request.ar_valid && int'(memory_request.ar.id)==s) ||
            (memory_request.aw_valid && int'(memory_request.aw.id)==s))
          assert (!dut.gen_cluster.ar_ot_q[s].valid && !dut.gen_cluster.aw_ot_q[s].valid);
      end
      if (!(|ar_valids) && |aw_valids && !(&dut.gen_cluster.slot_used) && !dut.gen_cluster.w_busy_q)
        assert (memory_request.aw_valid);
      if (memory_request.ar_valid && !memory_response.ar_ready &&
          memory_request.aw_valid && !memory_response.aw_ready) seen_pair <= 1;
      if (!(|ar_valids) && memory_request.aw_valid &&
          $countones(dut.gen_cluster.slot_used)==LIMIT-1) seen_credit <= 1;
    end
  end
endmodule
'''


def hub_quality(out, data):
    work = out / 'hub-quality'
    work.mkdir()
    original = Path('/opt/testharness/runs/review-hub-before-20260916/output/source/g6lc_coherence_hub.sv')
    candidate = data / 'g6lc_coherence_hub.sv'
    assert digest(original) == '78ad3d66fd4a01e746602fb3e239e3a443eab57b4bb1b221343a922df95c258a'
    source_names = ['config_pkg.sv', 'g6lc_coherence_pkg.sv', 'g6lc_inval_bus.sv', 'g6lc_snoop_filter.sv', 'g6lc_lr_sc_tracker.sv']
    types = re.findall(r'package g6lc_l2_tb_pkg;.*?endpackage', (data / 'tb_g6lc_l2.sv').read_text(), re.S)
    assert len(types)==1
    types_file = work / 'types.sv'
    types_file.write_text('// Copyright (c) 2026 Etienne Cimon\n// SPDX-License-Identifier: MIT\n' + types[0] + '\n')
    common = ' '.join(str(data / n) for n in source_names) + ' ' + str(types_file)
    results = []
    areas = []
    def run(label, script, expected=None):
        (work / (label + '.ys')).write_text(script)
        with (work / (label + '.log')).open('w') as log:
            proc = subprocess.run(['yosys', '-s', str(work / (label + '.ys'))], cwd=work, stdout=log, stderr=subprocess.STDOUT, timeout=180)
        text = (work / (label + '.log')).read_text()
        matched = (proc.returncode != 0 and expected in text) if expected else proc.returncode==0
        results.append({'label':label, 'rc':proc.returncode, 'expectedError':expected, 'matched':matched})
        (out / 'quality.json').write_text(json.dumps(results,indent=2))
        assert matched, label
        return text
    for role, rtl, cores, limit, negative in [('before',original,2,4,False),('after',candidate,2,4,False),('single-slot',candidate,2,1,False),('identity',candidate,1,1,False),('negative',candidate,2,4,True)]:
        formal = work / (role + '.sv')
        text = HUB_FORMAL.replace('CORES=2, LIMIT=4',f'CORES={cores}, LIMIT={limit}')
        if negative: text=text.replace('NEGATIVE=0','NEGATIVE=1')
        formal.write_text(text)
        script = f'read_slang --std 1800-2017 --top hub_contract {common} {rtl} {formal}\nprep -top hub_contract\nasync2sync\nchformal -lower\nflatten\nmemory_map\nopt -full\ndffunmap\nopt_clean -purge\nwrite_rtlil {role}.il\nsat -seq 8 -set-assumes -prove-asserts -show-ports -dump_vcd {role}.vcd -verify\n'
        text = run(role,script,'proof did fail' if role in {'before','negative'} else None)
        assert ('model found: FAIL!' if role in {'before','negative'} else 'no model found: SUCCESS!') in text
    for goal in ['seen_pair','seen_credit']:
        text=run(goal,f'read_rtlil after.il\nchformal -assert -remove\nsat -seq 8 -set-assumes -prove {goal} 0 -prove-skip 7 -show-ports -dump_vcd {goal}.vcd -verify\n','proof did fail')
        assert 'model found: FAIL!' in text
    for cores, limit in [(1,1),(2,1),(2,4),(4,4)]:
        wrapper=work/f'leaf-{cores}-{limit}.sv'
        wrapper.write_text(f'// Copyright (c) 2026 Etienne Cimon\n// SPDX-License-Identifier: MIT\nmodule leaf import config_pkg::*; import g6lc_coherence_pkg::*; import g6lc_l2_tb_pkg::*; (input logic clk_i,rst_ni, input req_t [{cores-1}:0] requests, input resp_t memory_response, input logic [{cores-1}:0] inv_ready, output resp_t [{cores-1}:0] responses, output req_t memory_request, output coh_inval_t [{cores-1}:0] invalidations, output logic [6:0] events); g6lc_coherence_hub #(.NR_CORES({cores}),.MAX_OUTSTANDING({limit}),.INVAL_DEPTH(2),.SNOOP_FILTER_EN(0),.SNOOP_FILTER_ENTRIES(4),.POLICY(COH_BROADCAST),.AXI_STARVE_LIMIT(16),.axi_req_t(req_t),.axi_resp_t(resp_t)) dut (.clk_i,.rst_ni,.core_req_i(requests),.core_resp_o(responses),.mem_req_o(memory_request),.mem_resp_i(memory_response),.inv_core_o(invalidations),.inv_core_ready_i(inv_ready),.lr_valid_i(1\'b0),.lr_addr_i(\'0),.lr_core_i(\'0),.coh_inv_fire_o(events[0]),.coh_sf_hit_o(events[1]),.coh_sf_overapprox_o(events[2]),.coh_arb_starve_o(events[3]),.coh_split_conflict_o(events[4]),.coh_sc_noresv_o(events[5]),.coh_lr_kill_o(events[6])); endmodule\n')
        for role,rtl in [('before',original),('after',candidate)]:
            label=f'synth-{role}-{cores}-{limit}'
            run(label,f'read_slang --std 1800-2017 --top leaf {common} {rtl} {wrapper}\nsynth -top leaf -flatten\ncheck -assert\nwrite_json {label}.json\n')
            cells=json.loads((work/(label+'.json')).read_text())['modules']['leaf']['cells']
            types=[c['type'] for c in cells.values()]
            latch=sum('LATCH' in t.upper() for t in types)
            if role=='after': assert latch==0
            areas.append({'role':role,'cores':cores,'outstanding':limit,'cells':len(types),'sequentialCells':sum('DFF' in t.upper() for t in types),'latches':latch,'sourceSha256':digest(rtl),'physicalArea':None})
            (out/'area.json').write_text(json.dumps(areas,indent=2))
    (out/'sources.json').write_text(json.dumps({'before':digest(original),'after':digest(candidate),**{name:digest(data/name) for name in source_names},'typesSource':digest(data/'tb_g6lc_l2.sv')},indent=2))
    return 0


def hub_review(out, data, runtime_info, runtime):
    source = out / 'source'
    source.mkdir()
    names = ['config_pkg.sv', 'g6lc_coherence_pkg.sv', 'g6lc_inval_bus.sv', 'g6lc_snoop_filter.sv', 'g6lc_lr_sc_tracker.sv', 'g6lc_coherence_hub.sv', 'tb_g6lc_l2.sv', 'tb_g6lc_coherence_hub.sv']
    for name in names:
        shutil.copy2(data / name, source / name)
    assert digest(source / 'g6lc_inval_bus.sv') == '2cafee7fbcda6f30274461a4486fd613698e61ef67691e08dda94b2ff0592945'
    hashes = {name: digest(source / name) for name in names}
    types = re.findall(r'package g6lc_l2_tb_pkg;.*?endpackage', (source / 'tb_g6lc_l2.sv').read_text(), re.S)
    assert len(types) == 1
    (source / 'types.sv').write_text('// Copyright (c) 2026 Etienne Cimon\n// SPDX-License-Identifier: MIT\n' + types[0] + '\n')
    (out / 'sources.json').write_text(json.dumps(hashes, indent=2))
    (out / 'runtime.json').write_text(json.dumps(runtime_info, indent=2))
    repaired = os.environ.get('REVIEW_HUB_RESERVATIONS') == '1'
    files = [str(source / name) for name in names[:-2]] + [str(source / 'types.sv'), str(source / names[-1])]
    records = []
    for outstanding in ([4, 1] if repaired else [4]):
        work = out / f'model-{outstanding}'
        work.mkdir()
        command = ['verilator', '--cc', '--main', '--exe', '--timing', '--assert', '--threads', '1', '-Wno-fatal', '--top-module', 'tb_g6lc_coherence_hub', f'-GOT={outstanding}', '--Mdir', str(work), '-o', 'hub-test', *files]
        commands = [('verilate', command), ('build', ['make', '-C', str(work), '-f', 'Vtb_g6lc_coherence_hub.mk', '-j4', 'VERILATOR_ROOT=' + str(runtime)])]
        for label, cmd in commands:
            (work / (label + '-command.json')).write_text(json.dumps(cmd, indent=2))
            with (work / (label + '.log')).open('w') as log:
                p = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT, timeout=180)
            assert p.returncode == 0, label
        dependencies = '\n'.join(p.read_text(errors='replace') for p in work.glob('*.d'))
        assert str(runtime / 'include/verilated_funcs.h') in dependencies
        assert str(Path(runtime_info['originalRoot']) / 'include/verilated_funcs.h') not in dependencies
        exe = work / 'hub-test'
        if repaired:
            #  9 = arbiter fairness / starvation override. Needs the 4-slot
            #  configuration so both cores can hold AW requests outstanding
            #  while the memory side refuses, which is what drives the starve
            #  counters to AXI_STARVE_LIMIT.
            scenarios = [0, 1, 2, 3, 4, 5, 6, 8, 9] if outstanding == 4 else [0, 1, 2, 7, 8]
            # Scenario 5 (accepted writes vs delivered invalidations) now passes:
            # the hub retains an accepted write's invalidation obligation in a
            # registered slot and refuses further invalidating writes while it is
            # occupied, so no write completes without its invalidation.
            trials = [(i, False, None) for i in scenarios]
        else:
            expected = [None, 'HUB_AR_STABILITY', 'HUB_AW_STABILITY', 'HUB_ID_STABILITY', 'HUB_AW_CREDIT', 'HUB_INV_LOSS']
            trials = [(i, False, error) for i, error in enumerate(expected)]
        for scenario, negative, error in trials + [(0, True, 'HUB_RESPONSE')]:
            cmd = [str(exe), f'+scenario={scenario}'] + (['+oracle_negative'] if negative else [])
            p = subprocess.run(cmd, cwd=work, capture_output=True, text=True, timeout=30)
            text = p.stdout + p.stderr
            (work / f'scenario-{scenario}-negative-{int(negative)}.log').write_text(text)
            matched = (p.returncode != 0 and error in text and 'HUB_PASS ' not in text) if error else (p.returncode == 0 and text.count('HUB_PASS ') == 1 and '%Error' not in text)
            records.append({'outstandingLimit': outstanding, 'scenario': scenario, 'negativeControl': negative, 'expectedError': error, 'rc': p.returncode, 'matched': matched, 'executableSha256': digest(exe), 'hubSha256': hashes['g6lc_coherence_hub.sv'], 'strictQualification': False})
            (out / 'results.json').write_text(json.dumps(records, indent=2))
            assert matched, (outstanding, scenario)
    assert all(digest(source / name) == value for name, value in hashes.items())
    return 0


def main():
    out = Path(os.environ['TH_OUT_DIR'])
    data = Path(os.environ['TH_DATA_DIR'])
    if os.environ.get('REVIEW_HUB_QUALITY') == '1':
        return hub_quality(out, data)
    if os.environ.get('REVIEW_INVAL_QUALITY') == '1':
        return quality_review(out, data)
    baseline = os.environ.get('REVIEW_INVAL_BASELINE') == '1'
    runtime_info = json.loads(Path('/opt/testharness/runs/review-cacheability-pair-20260916/output/runtime.json').read_text())
    runtime = Path(runtime_info['privateRoot'])
    header_sha = digest(runtime / 'include/verilated_funcs.h')
    assert header_sha == 'dfbc2c4aa3c1065d4465027c893c9677de10da4cfe7fb152e485eb32b8125166'
    canaries = Path('/opt/testharness/runs/review-private-runtime-rebuild-20260915/output/canaries.json')
    assert [(r['tag'], r['rc']) for r in json.loads(canaries.read_text())] == [('original', 1), ('fixed', 0)]
    if os.environ.get('REVIEW_HUB_BASELINE') == '1' or os.environ.get('REVIEW_HUB_RESERVATIONS') == '1':
        if os.environ.get('REVIEW_HUB_BASELINE') == '1' and os.environ.get('REVIEW_HUB_RESERVATIONS') == '1':
            raise ValueError('select baseline or reservation repair, not both')
        return hub_review(out, data, runtime_info, runtime)
    source = out / 'source'
    source.mkdir()
    names = ['g6lc_coherence_pkg.sv', 'g6lc_inval_bus.sv', 'tb_g6lc_inval_bus.sv']
    for name in names:
        shutil.copy2(data / name, source / name)
    sources = {name: digest(source / name) for name in names}
    (out / 'sources.json').write_text(json.dumps(sources, indent=2))
    (out / 'runtime.json').write_text(json.dumps(runtime_info, indent=2))
    cases = [(3, 2)] if baseline else [(1, 1), (2, 1), (3, 2), (4, 3), (4, 4)]
    results = []
    for cores, depth in cases:
        work = out / f'n{cores}-d{depth}'
        work.mkdir()
        command = ['verilator', '--cc', '--main', '--exe', '--timing', '--assert', '--threads', '1', '-Wno-fatal', '--top-module', 'tb_g6lc_inval_bus', f'-GCORES={cores}', f'-GDEPTH={depth}', '--Mdir', str(work), '-o', 'inval-test', *[str(source / name) for name in names]]
        make = ['make', '-C', str(work), '-f', 'Vtb_g6lc_inval_bus.mk', '-j4', 'VERILATOR_ROOT=' + str(runtime)]
        for label, cmd in [('verilate', command), ('build', make)]:
            (work / (label + '-command.json')).write_text(json.dumps(cmd, indent=2))
            with (work / (label + '.log')).open('w') as log:
                proc = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT, timeout=180)
            assert proc.returncode == 0, str(work / (label + '.log'))
        dependencies = '\n'.join(p.read_text(errors='replace') for p in work.glob('*.d'))
        assert str(runtime / 'include/verilated_funcs.h') in dependencies
        assert str(Path(runtime_info['originalRoot']) / 'include/verilated_funcs.h') not in dependencies
        exe = work / 'inval-test'
        trials = [(0, False, None), (1, False, 'INVBUS_READY'), (2, False, 'INVBUS_DELIVERY')] if baseline else [(3, False, None), (3, True, 'INVBUS_READY')]
        for scenario, negative, expected_error in trials:
            cmd = [str(exe), f'+scenario={scenario}'] + (['+oracle_negative'] if negative else [])
            run = subprocess.run(cmd, cwd=work, capture_output=True, text=True, timeout=30)
            text = run.stdout + run.stderr
            logfile = work / f'scenario-{scenario}-negative-{int(negative)}.log'
            logfile.write_text(text)
            matched = (run.returncode != 0 and expected_error in text and 'INVBUS_PASS ' not in text) if expected_error else (run.returncode == 0 and text.count('INVBUS_PASS ') == 1 and '%Error' not in text)
            results.append({'cores': cores, 'depth': depth, 'scenario': scenario, 'negativeControl': negative, 'expectedError': expected_error, 'rc': run.returncode, 'matched': matched, 'sourceSha256': sources['g6lc_inval_bus.sv'], 'executableSha256': digest(exe), 'log': str(logfile), 'strictQualification': False})
            (out / 'results.json').write_text(json.dumps(results, indent=2))
            assert matched, str(logfile)
    assert all(digest(source / name) == value for name, value in sources.items())
    return 0


if __name__ == '__main__':
    sys.exit(main())
