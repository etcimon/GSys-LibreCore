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
    historical_common = ' '.join(str(original.parent / n) for n in source_names) + ' ' + str(types_file)
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
        if role == 'before': text=text.replace('coh_sc_noresv_o', 'coh_sc_fail_o')
        formal.write_text(text)
        role_common = historical_common if role == 'before' else common
        script = f'read_slang --std 1800-2017 --top hub_contract {role_common} {rtl} {formal}\nprep -top hub_contract\nasync2sync\nchformal -lower\nflatten\nmemory_map\nopt -full\ndffunmap\nopt_clean -purge\nwrite_rtlil {role}.il\nsat -seq 8 -set-assumes -prove-asserts -show-ports -dump_vcd {role}.vcd -verify\n'
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
            role_common = historical_common if role == 'before' else common
            role_wrapper = work / f'{label}.sv'
            wrapper_text = wrapper.read_text()
            if role == 'before': wrapper_text = wrapper_text.replace('coh_sc_noresv_o', 'coh_sc_fail_o')
            role_wrapper.write_text(wrapper_text)
            run(label,f'read_slang --std 1800-2017 --top leaf {role_common} {rtl} {role_wrapper}\nsynth -top leaf -flatten\ncheck -assert\nwrite_json {label}.json\n')
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
    signature = os.environ.get('REVIEW_HUB_SIGNATURE') == '1'
    if signature:
        names[1:1] = ['tc_sram.sv', 'g6lc_ooo_snoop_filter.sv']
    for name in names:
        shutil.copy2(data / name, source / name)
    b_fault = os.environ.get('REVIEW_HUB_B_FAULT')
    if b_fault:
        path = source / 'g6lc_coherence_hub.sv'
        text = path.read_text()
        old, new = {
            'lock': ("b_offer_locked_q[c] <= 1'b1;", "b_offer_locked_q[c] <= 1'b0;"),
            'order': ("b_predecessors_q[s] <= b_predecessors_d[s];", "b_predecessors_q[s] <= '0;"),
            # Restored defect: a younger same-(core, id) AR is granted while the
            # older read slot is still live, so the L2 may answer it first.
            'r-order': ("assign ar_req[c] = core_req_i[c].ar_valid && !ar_same_id_live[c] &&",
                        "assign ar_req[c] = core_req_i[c].ar_valid &&"),
            # Restored defect: the signature filter acquires presence only on
            # AR fire, so a writer is never recorded as a sharer.
            'writer': (".alloc_valid_i(ar_fire | aw_fire),",
                       ".alloc_valid_i(ar_fire),"),
            # Restored defect: a same-line AR is forwarded while the write is
            # still in flight, so the refill can publish pre-write data after
            # the invalidation was already consumed (stale refill).
            'refill': ("assign ar_req[c] = core_req_i[c].ar_valid && !ar_same_id_live[c] &&\n                         !ar_wr_line_live[c];",
                       "assign ar_req[c] = core_req_i[c].ar_valid && !ar_same_id_live[c];")
        }[b_fault]
        assert text.count(old) == 1, 'B mutation site changed'
        path.write_text(text.replace(old, new))
    inv_source = source / 'g6lc_inval_bus.sv'
    assert digest(inv_source) in {'2cafee7fbcda6f30274461a4486fd613698e61ef67691e08dda94b2ff0592945',
                                  # adds inv_enq_seq_o/inv_deq_seq_o delivery sequences
                                  'bb43a41f43482bd7d937728ca4d20dee984ce47225f46f7ebfe4cdde637215da',
                                  # wrap-compare pointer advance instead of `% DP`
                                  '054d606f80f4250e532f280baf7c5df1e961860b0ad24cc7133cecd45b6a2c72',
                                  # shared per-core tail_m1 continuous assignment
                                  '2818440e3679428319243d284fa589ca0a14e6da1270bcafde6ed4674a199bd6'} or \
        hashlib.sha256(inv_source.read_text().encode()).hexdigest() in {
        '6edb90f8d3c26d3d599ecb25ff87848b70400e62521c6b5f25229caa02bfd079',
        '2c18cbe614eef7767e08074ea3dadbd3bad018aa0712de3a50d09e694c62d30e'}
    hashes = {name: digest(source / name) for name in names}
    types = re.findall(r'package g6lc_l2_tb_pkg;.*?endpackage', (source / 'tb_g6lc_l2.sv').read_text(), re.S)
    assert len(types) == 1
    (source / 'types.sv').write_text('// Copyright (c) 2026 Etienne Cimon\n// SPDX-License-Identifier: MIT\n' + types[0] + '\n')
    (out / 'sources.json').write_text(json.dumps(hashes, indent=2))
    (out / 'runtime.json').write_text(json.dumps(runtime_info, indent=2))
    repaired = os.environ.get('REVIEW_HUB_RESERVATIONS') == '1'
    files = [str(source / name) for name in names[:-2]] + [str(source / 'types.sv'), str(source / names[-1])]
    records = []
    lifetime = os.environ.get('REVIEW_HUB_LIFETIME') == '1'
    before_lifetime = os.environ.get('REVIEW_HUB_LIFETIME_BEFORE') == '1'
    bad_signature = signature and os.environ.get('REVIEW_HUB_SIGNATURE_BAD_CREDITS') == '1'
    # Restored-defect build: writer B returns before invalidation delivery.
    ack_before = os.environ.get('REVIEW_HUB_ACK_BEFORE') == '1'
    publication = os.environ.get('REVIEW_HUB_PUBLICATION') == '1'
    stability = os.environ.get('REVIEW_HUB_B_STABILITY') == '1'
    stability_before = os.environ.get('REVIEW_HUB_B_STABILITY_BEFORE') == '1'
    # REVIEW_HUB_OT sweeps the shared credit count (default 4); used to
    # re-prove the signature/b-order arms at the configured CohMaxOutstanding.
    ot_env = int(os.environ.get('REVIEW_HUB_OT', '4'))
    for outstanding in ([1] if bad_signature else [ot_env] if (signature or ack_before or stability or publication or b_fault) else [4, 1, 16] if lifetime else [4, 1] if repaired else [4]):
        work = out / f'model-{outstanding}'
        work.mkdir()
        command = ['verilator', '--cc', '--main', '--exe', '--timing', '--assert', '--threads', '1', '-Wno-fatal', '-Werror-LATCH', '-Werror-UNOPTFLAT', '-Werror-USERERROR', '--top-module', 'tb_g6lc_coherence_hub', f'-GOT={outstanding}', *(['-GOOO=1', '-GNC=3'] if signature else []), *(['-GACK_AFTER_INVAL=0'] if ack_before else []), '--Mdir', str(work), '-o', 'hub-test', *files]
        commands = [('verilate', command), ('build', ['make', '-C', str(work), '-f', 'Vtb_g6lc_coherence_hub.mk', '-j4', 'VERILATOR_ROOT=' + str(runtime)])]
        for label, cmd in commands:
            (work / (label + '-command.json')).write_text(json.dumps(cmd, indent=2))
            with (work / (label + '.log')).open('w') as log:
                p = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT, timeout=180)
            if bad_signature and label == 'verilate':
                text = (work / (label + '.log')).read_text()
                refused = p.returncode != 0 and 'require at least two transaction credits' in text
                (out / 'results.json').write_text(json.dumps([{
                    'configurationRefused': refused, 'outstandingLimit': outstanding,
                    'rc': p.returncode, 'hubSha256': hashes['g6lc_coherence_hub.sv']}], indent=2))
                assert refused, 'signature credit guard did not refuse elaboration'
                return 0
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
        if lifetime:
            trials = ([(10, False, 'HUB_ATOP_LIFETIME' if before_lifetime else None)]
                      if outstanding < 16 else
                      [(11, False, 'HUB_R_HOLD' if before_lifetime else None)])
            if not before_lifetime:
                trials.append((13, False, None))
                # B-after-delivery lifetime scenarios. 15/16/18 keep more than
                # one write slot occupied at once, so the single-credit build
                # only runs the scenarios a parked B cannot deadlock.
                trials += [(14, False, None), (14, True, 'HUB_B_BEFORE_INVAL'),
                           (17, False, None), (17, True, 'HUB_B_FAST_PATH')]
                if outstanding >= 4:
                    trials += [(15, False, None), (15, True, 'HUB_B_HOLD'),
                               (16, False, None), (16, True, 'HUB_B_BEFORE_INVAL'),
                               (18, False, None), (18, True, 'HUB_B_BEFORE_INVAL'),
                               (19, False, None), (19, True, 'HUB_B_STABILITY'),
                               (20, False, None), (20, True, 'HUB_B_STABILITY'),
                               (24, False, None), (24, True, 'HUB_B_ID_ORDER'),
                               (25, False, None), (25, True, 'HUB_R_ID_ORDER'),
                               (27, False, None), (27, True, 'HUB_ATOP_R_WITHHELD')]
        if ack_before:
            trials = [(14, False, 'HUB_B_BEFORE_INVAL')]
        if signature:
            trials = [(12, False, None), (12, True, 'HUB_SIGNATURE_TARGET'),
                      (26, False, None), (26, True, 'HUB_WRITER_ACQUISITION')]
        if stability:
            trials = [(s, False, 'HUB_B_STABILITY' if stability_before else None) for s in (19, 20)]
            if not stability_before:
                trials += [(s, True, 'HUB_B_STABILITY') for s in (19, 20)]
        if publication:
            codes = {21:'HUB_ATOMIC_BEFORE_INVAL', 22:'HUB_ATOMIC_MISSING_INVAL',
                     23:'HUB_STALE_REFILL_PUBLICATION', 24:'HUB_B_ID_ORDER', 25:'HUB_R_ID_ORDER'}
            before = os.environ.get('REVIEW_HUB_PUBLICATION_BEFORE') == '1'
            selected = os.environ.get('REVIEW_HUB_PUBLICATION_CASES', '21,22,23')
            trials = [(int(s), False, codes[int(s)] if before else None) for s in selected.split(',')]
        if b_fault:
            trials = ([(24, False, 'HUB_B_ID_ORDER')] if b_fault == 'order' else
                      [(25, False, 'HUB_R_ID_ORDER')] if b_fault == 'r-order' else
                      [(26, False, 'HUB_WRITER_ACQUISITION'), (12, False, None)] if b_fault == 'writer' else
                      [(23, False, 'HUB_STALE_REFILL_PUBLICATION')] if b_fault == 'refill' else
                      [(s, False, 'HUB_B_STABILITY') for s in (19, 20)])
        elif publication and not before:
            trials += [(int(s), True, codes[int(s)]) for s in selected.split(',') if int(s) in (21, 22, 24, 25)]
        for scenario, negative, error in trials + ([] if lifetime or signature or ack_before or stability or publication else [(0, True, 'HUB_RESPONSE')]):
            cmd = [str(exe), f'+scenario={scenario}'] + (['+oracle_negative'] if negative else [])
            p = subprocess.run(cmd, cwd=work, capture_output=True, text=True, timeout=30)
            text = p.stdout + p.stderr
            (work / f'scenario-{scenario}-negative-{int(negative)}.log').write_text(text)
            matched = (p.returncode != 0 and error in text and 'HUB_PASS ' not in text) if error else (p.returncode == 0 and text.count('HUB_PASS ') == 1 and '%Error' not in text)
            records.append({'outstandingLimit': outstanding, 'scenario': scenario, 'negativeControl': negative, 'ackBefore': ack_before, 'expectedError': error, 'rc': p.returncode, 'matched': matched, 'executableSha256': digest(exe), 'hubSha256': hashes['g6lc_coherence_hub.sv'], 'strictQualification': False})
            (out / 'results.json').write_text(json.dumps(records, indent=2))
            assert matched, (outstanding, scenario)
    if os.environ.get('REVIEW_HUB_SYNTH') == '1':
        cores = 3 if signature else 2
        policy = 'config_pkg::COH_OOO' if signature else 'config_pkg::COH_BROADCAST'
        wrapper = out / 'hub_leaf.sv'
        wrapper.write_text(f'''module hub_leaf
import g6lc_coherence_pkg::*;
import g6lc_l2_tb_pkg::*;
(input logic clk_i,rst_ni,
 input req_t [{cores-1}:0] requests,input resp_t memory_response,
 input logic [{cores-1}:0] inv_ready,
 output resp_t [{cores-1}:0] responses,output req_t memory_request,
 output coh_inval_t [{cores-1}:0] invalidations,output logic [6:0] events);
g6lc_coherence_hub #(.NR_CORES({cores}),.MAX_OUTSTANDING(4),.INVAL_DEPTH(2),
 .SNOOP_FILTER_EN({int(signature)}),.SNOOP_FILTER_ENTRIES(4),.POLICY({policy}),
 .axi_req_t(req_t),.axi_resp_t(resp_t)) dut (
 .clk_i,.rst_ni,.core_req_i(requests),.core_resp_o(responses),
 .mem_req_o(memory_request),.mem_resp_i(memory_response),
 .inv_core_o(invalidations),.inv_core_ready_i(inv_ready),
 .lr_valid_i(1'b0),.lr_addr_i('0),.lr_core_i('0),
 .coh_inv_fire_o(events[0]),.coh_sf_hit_o(events[1]),.coh_sf_overapprox_o(events[2]),
 .coh_arb_starve_o(events[3]),.coh_split_conflict_o(events[4]),
 .coh_sc_noresv_o(events[5]),.coh_lr_kill_o(events[6]));
endmodule
''')
        script = ('read_slang --top hub_leaf ' + ' '.join(files[:-1]) + f' {wrapper}; '
                  'synth -top hub_leaf -flatten; check -assert; stat')
        (out / 'hub-synth.ys').write_text(script)
        with (out / 'hub-synth.log').open('w') as log:
            rc = subprocess.run(['yosys','-p',script],stdout=log,stderr=subprocess.STDOUT,timeout=300).returncode
        log_text = (out / 'hub-synth.log').read_text()
        (out / 'synth-result.json').write_text(json.dumps({'rc':rc,'signature':signature,
            'cores':cores,'outstandingLimit':4,'passed':rc==0,
            'wrapperSha256':digest(wrapper),'hubSha256':hashes['g6lc_coherence_hub.sv']},indent=2))
        assert rc == 0 and 'found logic loop' not in log_text and 'Latch inferred' not in log_text
    assert all(digest(source / name) == value for name, value in hashes.items())
    return 0


def composed_review(out, data, runtime_info, runtime):
    source = out / 'source'
    source.mkdir()
    names = ['config_pkg.sv','axi_pkg.sv','tc_sram.sv','g6lc_l2_pkg.sv',
             'g6lc_l2_tag.sv','g6lc_l2_data.sv','g6lc_l2_mshr.sv','g6lc_l2_wtrk.sv',
             'g6lc_l2_top.sv',
             'g6lc_l3_pkg.sv','g6lc_l3_top.sv','axi_cut.sv','spill_register.sv',
             'g6lc_coherence_pkg.sv','g6lc_inval_bus.sv','g6lc_snoop_filter.sv',
             'g6lc_ooo_snoop_filter.sv','g6lc_lr_sc_tracker.sv','g6lc_coherence_hub.sv',
             'g6lc_cmo_engine.sv','g6lc_l3_inclusive_inv.sv',
             'tb_g6lc_l2.sv','tb_g6lc_coherence_hub.sv']
    for name in names:
        shutil.copy2(data / name, source / name)
    # axi_cut includes "axi/assign.svh"/"axi/typedef.svh" (header text, not
    # compile units) — mirror the hum runner's source/axi/ layout.
    (source / 'axi').mkdir(exist_ok=True)
    for header in ('assign.svh', 'typedef.svh'):
        shutil.copy2(data / header, source / 'axi' / header)
    original = {name:digest(source/name) for name in names}
    chosen=os.environ.get('REVIEW_COMPOSED_PROFILE','small')
    # 'stack-fault' is a profile: the bench parameter SELF_INVAL_FAULT
    # disconnects only the L3's write self-invalidation (no RTL splice).
    fault = 'stack' if chosen=='stack-fault' else os.environ.get('REVIEW_COMPOSED_FAULT')
    if fault:
        assert fault in ('self-inval','stack')
        if fault == 'self-inval':
            path = source/'g6lc_l2_top.sv'
            text = path.read_text()
            old = '  assign tag_match_inval = l2_back_inval_valid_i | self_inval_req;'
            assert text.count(old)==1
            path.write_text(text.replace(old,'  assign tag_match_inval = l2_back_inval_valid_i;'))
    hashes = {name:digest(source/name) for name in names}
    types = re.findall(r'package g6lc_l2_tb_pkg;.*?endpackage', (source/'tb_g6lc_l2.sv').read_text(), re.S)
    assert len(types)==1
    (source/'types.sv').write_text(types[0]+'\n')
    (out/'sources.json').write_text(json.dumps({'original':original,'effective':hashes,
        'scope':'hub COH_OOO plus actual L2 (and optional L3 stack); modeled WT invalidation consumer; not CPU/ISA simulation'},indent=2))
    (out/'runtime.json').write_text(json.dumps(runtime_info,indent=2))
    env=dict(os.environ,VERILATOR_ROOT=str(runtime),VPATH=str(runtime/'include'))
    profiles = {
        'small': [],
        'mod-only': ['-GCACHE_ATTR=2'],
        'stalled': ['-GWRITE_DELAY=4','-GW_STALL=16','-GB_DELAY=16','-GINV_HOLD=64','-GR_HOLD=100','-GB_HOLD=96'],
        'target': ['-GBYTE_SIZE=262144','-GSET_ASSOC=8','-GMSHR_DEPTH=4','-GDATA_BANKS=4'],
        'no-l2': ['-GUSE_L2=0'],
        # Composed hub+L2+L3 stack: small geometry mirrors tb_g6lc_l2_hum's
        # CHAIN_L3; target exercises the g6lc64_ooo_int2_l3 1 MiB/16/MSHR 4
        # geometry point; stack-fault drops the L3 write self-invalidation.
        'stack-small': ['-GUSE_L3=1'],
        'stack-target': ['-GUSE_L3=1','-GBYTE_SIZE=262144','-GSET_ASSOC=8','-GMSHR_DEPTH=4',
                         '-GDATA_BANKS=4','-GL3_BYTES=1048576','-GL3_SET_ASSOC=16',
                         '-GL3_MSHR_DEPTH=4','-GL3_DATA_BANKS=4'],
        'stack-fault': ['-GUSE_L3=1','-GSELF_INVAL_FAULT=1'],
    }
    # REVIEW_COMPOSED_TAG_SRAM=1 routes every profile through the tc_sram tag
    # path — the flop path stays the default (identity control).
    if os.environ.get('REVIEW_COMPOSED_TAG_SRAM') == '1':
        profiles = {name: args + ['-GTAG_SRAM=1'] for name, args in profiles.items()}
    # REVIEW_COMPOSED_WU=1 enables the resident-line write merge on both
    # cache levels; the bench's WU-conditional expectations do the rest.
    if os.environ.get('REVIEW_COMPOSED_WU') == '1':
        profiles = {name: args + ['-GWRITE_UPDATE=1'] for name, args in profiles.items()}
    # REVIEW_COMPOSED_POSTED=1 enables posted writes + bypass-read tracking
    # on the L2 (and the L3 in stack profiles) — T9b.
    if os.environ.get('REVIEW_COMPOSED_POSTED') == '1':
        profiles = {name: args + ['-GPOSTED_WRITES=1'] for name, args in profiles.items()}
    assert chosen in profiles and not (fault and chosen=='no-l2')
    assert not (fault=='self-inval' and chosen.startswith('stack'))
    assert fault!='stack' or chosen=='stack-fault'
    files=[str(source/n) for n in names[:-2]]+[str(source/'types.sv'),str(source/names[-1])]
    model=out/'model'
    if os.environ.get('REVIEW_COMPOSED_SCC')=='1':
        bench=(source/'tb_g6lc_coherence_hub.sv').read_text().split('module tb_g6lc_coherence_l2;',1)[1]
        # The structural wrapper needs only the hub and the L2(+L3) instances.
        # The T9a CMO engine/broadcaster sit textually between them and refer
        # to bench-only stimulus state, so splice the hub instance and the
        # cache segment separately and tie the match-inval inputs off below.
        hub_seg = '  g6lc_coherence_hub #(' + \
            bench.split('  g6lc_coherence_hub #(', 1)[1].split(');', 1)[0] + ');\n'
        after_l2 = bench.split('  g6lc_l2_top #(', 1)[1]
        end = len(after_l2)
        for marker in ('\n  always_comb', '\n  function automatic data_t other_word'):
            stop = after_l2.find(marker)
            if stop != -1 and stop < end:
                end = stop
        instances = hub_seg + '  g6lc_l2_top #(' + after_l2[:end]
        wrapper=out/'composed_graph.sv'
        scc_l3 = os.environ.get('REVIEW_COMPOSED_SCC_L3') == '1'
        wrapper.write_text('''module composed_graph import g6lc_coherence_pkg::*; import g6lc_l2_tb_pkg::*;
(input logic clk,rst_n,input req_t[1:0] requests,input resp_t dram_rsp,
 input logic[1:0] inv_ready,output resp_t[1:0] responses,output req_t dram_req,
 output coh_inval_t[1:0] invalidations);
localparam bit USE_L2=1;
localparam bit USE_L3=%d;
localparam bit SELF_INVAL_FAULT=0;
localparam bit TAG_SRAM=%d;
localparam bit WRITE_UPDATE=%d;
localparam bit POSTED_WRITES=%d;
localparam int unsigned WTRK_DEPTH=4,RDTRK_DEPTH=4;
localparam int BYTE_SIZE=4096,SET_ASSOC=4,MSHR_DEPTH=4,DATA_BANKS=2;
localparam int L3_BYTES=2048,L3_SET_ASSOC=2,L3_MSHR_DEPTH=2,L3_DATA_BANKS=2;
req_t hub_req;resp_t hub_rsp;
req_t l2m_req;resp_t l2m_rsp;
logic l3_hit_p,l3_miss_p,l2_hit_p,l2_miss_p,l2_wupd_p,l3_wupd_p;
logic cmo_l2_rdy,cmo_l2_idle,cmo_l3_rdy,cmo_l3_idle;
addr_t cmo_l2_a,cmo_l3_a;
logic cmo_l2_v,cmo_l3_v;
assign cmo_l2_v = 1'b0;
assign cmo_l3_v = 1'b0;
''' % (scc_l3, int(os.environ.get('REVIEW_COMPOSED_TAG_SRAM') == '1'),
       int(os.environ.get('REVIEW_COMPOSED_WU') == '1'),
       int(os.environ.get('REVIEW_COMPOSED_POSTED') == '1'))
       + instances + '\nendmodule\n')
        script='read_slang -I' + str(source) + ' --top composed_graph ' + ' '.join(files[:-1]) + f' {wrapper}; hierarchy -check -top composed_graph; flatten; proc; opt; check -assert; scc -expect 0'
        (out/'scc.ys').write_text(script)
        with (out/'scc.log').open('w') as log:
            rc=subprocess.run(['yosys','-p',script],stdout=log,stderr=subprocess.STDOUT,timeout=180).returncode
        (out/'results.json').write_text(json.dumps({'sccRc':rc,'passed':rc==0,'scope':'signal-driven hub plus L2 combinational graph'}))
        assert rc==0,'composed combinational graph'
        return 0
    control=out/'composed.vlt'
    control.write_text('`verilator_config\n' + '\n'.join(
        f'split_var -module "{module}" -var "{port}"' for module, ports in (
            ('g6lc_coherence_hub',('mem_req_o','mem_resp_i','core_req_i','core_resp_o')),
            ('g6lc_l2_top',('slv_req_i','slv_resp_o','mst_req_o','mst_resp_i')),
            ('g6lc_l3_top',('slv_req_i','slv_resp_o','mst_req_o','mst_resp_i')),
            ('axi_cut',('slv_req_i','slv_resp_o','mst_req_o','mst_resp_i')))
        for port in ports) + '\nisolate_assignments -module "g6lc_coherence_hub" -var "mem_req_o"\n'
        'isolate_assignments -module "g6lc_l2_top" -var "slv_resp_o"\n')
    (out/'compiler-control.json').write_text(json.dumps({'sha256':digest(control)}))
    # Struct-granular UNOPTFLAT across the hub/L2 AXI seam is not a bit-level
    # loop: REVIEW_COMPOSED_SCC=1 proves the flattened graph has none.
    command=['verilator','--cc','--main','--exe','--timing','--assert','--threads','1','--flatten',
             '-Wno-fatal','-Werror-LATCH','-Werror-USERERROR',
             str(control),'-I'+str(source),'--top-module','tb_g6lc_coherence_l2',*profiles[chosen],
             '--Mdir',str(model),'-o','composed-test',*files]
    commands=[('verilate',command),('build',['make','-C',str(model),'-f','Vtb_g6lc_coherence_l2.mk','-j4'])]
    for label, cmd in commands:
        (out/f'{label}-command.json').write_text(json.dumps(cmd,indent=2))
        with (out/f'{label}.log').open('w') as log:
            rc=subprocess.run(cmd,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=300).returncode
        assert rc==0,label
    deps='\n'.join(p.read_text(errors='replace') for p in model.glob('*.d'))
    assert str(runtime/'include/verilated_funcs.h') in deps
    assert str(Path(runtime_info['originalRoot'])/'include/verilated_funcs.h') not in deps
    exe=model/'composed-test'
    records=[]
    # Scenario 3 is the self-invalidation discriminator: run it under the
    # 'self-inval' fault (disconnecting the write self-invalidation) so the
    # post-B re-read must expose the stale resident line. Scenarios 2/3 assert
    # line-fill geometry (a miss fetches one full line, later offsets hit),
    # which only exists when the request stream carries allocate attributes —
    # the 'mod-only' profile is the modifiable-only identity control and runs
    # the classic scenarios only.
    for scenario in ([0,3] if fault else ([0] if chosen=='no-l2' else
                     [0,1] if chosen=='mod-only' else
                     # stack-target's L3 (1 MiB/16w) retains the evicted L2
                     # line across the probe sweep; the small stack's L3
                     # aliases the same set and cannot. Scenario 6 is the T9a
                     # composed CMO (cbo.inval through the engine into the
                     # resident line at L2 and the stacked L3); scenario 7 is
                     # the M1a HPDCACHE store-shape stream (partial strobes,
                     # full-line burst, NC attribute) qualifying write-update.
                     [0,1,2,3,4,6,7] if chosen=='stack-target' else [0,1,2,3,6,7])):
        for negative in ([False] if fault or chosen=='no-l2' else [False,True]):
            cmd=[str(exe),f'+scenario={scenario}']+(['+oracle_negative'] if negative else [])
            if os.environ.get('REVIEW_COMPOSED_DIAGNOSE')=='1':cmd.append('+diagnose')
            result=subprocess.run(cmd,cwd=model,capture_output=True,text=True,timeout=30)
            text=result.stdout+result.stderr
            label=f'scenario-{scenario}-negative-{int(negative)}'
            (out/f'{label}.log').write_text(text)
            if fault or (chosen=='no-l2' and scenario==0):
                error='COH_L2_STALE_VALUE'
            elif negative:
                error={2:'COH_L2_DATA',3:'COH_L2_STALE_VALUE',4:'COH_L3_PROBE',
                       # +oracle_negative severs the L2 match-inval wire: the
                       # engine completes but the resident line survives, so
                       # the re-read hits and PROP must fire.
                       6:'COH_L2_CMO_PROP',
                       # Same severed wire in scenario 7: the post-CMO re-read
                       # hits the resident line, so the DRAM-AR count is short.
                       7:'COH_L2_SHAPE_AR'}.get(scenario,'COH_L2_FINAL_VALUE')
            else:
                error=None
            matched=(result.returncode!=0 and error in text and 'COH_L2_PASS' not in text) if error else (
                result.returncode==0 and text.count('COH_L2_PASS')==1 and '%Error' not in text)
            metrics=re.findall(r'COH_L2_PASS ([^\n]+)',text)
            records.append({'profile':chosen,'fault':fault,'scenario':scenario,'negative':negative,
                'expectedError':error,'rc':result.returncode,'matched':matched,'metrics':metrics,
                'modelSha256':digest(exe)})
            (out/'results.json').write_text(json.dumps(records,indent=2))
            assert matched,label
    assert all(digest(source/name)==value for name,value in hashes.items())
    return 0


def credits_review(out, data, runtime_info, runtime):
    source = out / 'source'
    source.mkdir()
    names = ['config_pkg.sv','axi_pkg.sv','tc_sram.sv','g6lc_l2_pkg.sv',
             'g6lc_l2_tag.sv','g6lc_l2_data.sv','g6lc_l2_mshr.sv','g6lc_l2_wtrk.sv',
             'g6lc_l2_top.sv',
             'g6lc_l3_pkg.sv','g6lc_l3_top.sv','axi_cut.sv','spill_register.sv',
             'g6lc_coherence_pkg.sv','g6lc_inval_bus.sv','g6lc_snoop_filter.sv',
             'g6lc_ooo_snoop_filter.sv','g6lc_lr_sc_tracker.sv','g6lc_coherence_hub.sv',
             'tb_g6lc_l2.sv','tb_g6lc_coherence_hub.sv']
    for name in names:
        shutil.copy2(data / name, source / name)
    (source / 'axi').mkdir(exist_ok=True)
    for header in ('assign.svh', 'typedef.svh'):
        shutil.copy2(data / header, source / 'axi' / header)
    hashes = {name: digest(source/name) for name in names}
    types = re.findall(r'package g6lc_l2_tb_pkg;.*?endpackage', (source/'tb_g6lc_l2.sv').read_text(), re.S)
    assert len(types) == 1
    (source/'types.sv').write_text(types[0]+'\n')
    (out/'sources.json').write_text(json.dumps({'effective':hashes,
        'scope':'hub COH_OOO plus actual L2; queued DRAM; credit-bound measurement'},indent=2))
    (out/'runtime.json').write_text(json.dumps(runtime_info,indent=2))
    env = dict(os.environ, VERILATOR_ROOT=str(runtime), VPATH=str(runtime/'include'))
    mshr = int(os.environ.get('REVIEW_CREDITS_MSHR','2'))
    # Credit-geometry sweep knobs (M1a): MAX_OT drives the hub shared AR/AW
    # slot count (CohMaxOutstanding), READS/CORES shape the burst, WRITES adds
    # the mixed AW/W phase.
    credit_gargs = [f'-GMSHR_DEPTH={mshr}']
    for env_name, gparam in (('REVIEW_CREDITS_OT', 'MAX_OT'),
                             ('REVIEW_CREDITS_READS', 'READS_PER_CORE'),
                             ('REVIEW_CREDITS_WRITES', 'WRITES_PER_CORE'),
                             ('REVIEW_CREDITS_CORES', 'CORES')):
        value = os.environ.get(env_name)
        if value is not None:
            credit_gargs.append(f'-G{gparam}={int(value)}')
    files = [str(source/n) for n in names[:-2]]+[str(source/'types.sv'),str(source/names[-1])]
    model = out/'model'
    control = out/'credits.vlt'
    control.write_text('`verilator_config\n' + '\n'.join(
        f'split_var -module "{module}" -var "{port}"' for module, ports in (
            ('g6lc_coherence_hub',('mem_req_o','mem_resp_i','core_req_i','core_resp_o')),
            ('g6lc_l2_top',('slv_req_i','slv_resp_o','mst_req_o','mst_resp_i')),
            ('g6lc_l3_top',('slv_req_i','slv_resp_o','mst_req_o','mst_resp_i')),
            ('axi_cut',('slv_req_i','slv_resp_o','mst_req_o','mst_resp_i')))
        for port in ports) + '\nisolate_assignments -module "g6lc_coherence_hub" -var "mem_req_o"\n'
        'isolate_assignments -module "g6lc_l2_top" -var "slv_resp_o"\n')
    (out/'compiler-control.json').write_text(json.dumps({'sha256':digest(control)}))
    # REVIEW_CREDITS_L3_MSHR stacks the L3 between L2 and DRAM at the given MSHR
    # depth; the 4-vs-16 sweep must yield identical drain/service cycles.
    l3_mshr = int(os.environ.get('REVIEW_CREDITS_L3_MSHR','0'))
    l3_args = ['-GUSE_L3=1',f'-GL3_MSHR_DEPTH={l3_mshr}'] if l3_mshr else []
    if os.environ.get('REVIEW_CREDITS_TAG_SRAM') == '1':
        l3_args += ['-GTAG_SRAM=1']
    if os.environ.get('REVIEW_CREDITS_POSTED') == '1':
        l3_args += ['-GPOSTED_WRITES=1']
    command = ['verilator','--cc','--main','--exe','--timing','--assert','--threads','1','--flatten',
               '-Wno-fatal','-Werror-LATCH','-Werror-USERERROR',
               str(control),'-I'+str(source),'--top-module','tb_g6lc_coherence_credits',*credit_gargs,
               *l3_args,
               '--Mdir',str(model),'-o','credits-test',*files]
    commands = [('verilate',command),('build',['make','-C',str(model),'-f','Vtb_g6lc_coherence_credits.mk','-j4'])]
    for label, cmd in commands:
        (out/f'{label}-command.json').write_text(json.dumps(cmd,indent=2))
        with (out/f'{label}.log').open('w') as log:
            rc = subprocess.run(cmd,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=300).returncode
        assert rc == 0,label
    deps = '\n'.join(p.read_text(errors='replace') for p in model.glob('*.d'))
    assert str(runtime/'include/verilated_funcs.h') in deps
    assert str(Path(runtime_info['originalRoot'])/'include/verilated_funcs.h') not in deps
    exe = model/'credits-test'
    records = []
    for negative in [False,True]:
        cmd = [str(exe)]+(['+oracle_negative'] if negative else [])
        result = subprocess.run(cmd,cwd=model,capture_output=True,text=True,timeout=60)
        text = result.stdout+result.stderr
        label = f'negative-{int(negative)}'
        (out/f'{label}.log').write_text(text)
        error = 'COH_CREDIT_DATA' if negative else None
        matched = (result.returncode!=0 and error in text and 'COH_CREDIT_PASS' not in text) if error else (
            result.returncode==0 and text.count('COH_CREDIT_PASS')==1 and '%Error' not in text)
        metrics = re.findall(r'COH_CREDIT_PASS ([^\n]+)',text)
        records.append({'mshr':mshr,'maxOt':int(os.environ.get('REVIEW_CREDITS_OT','4')),
            'cores':int(os.environ.get('REVIEW_CREDITS_CORES','2')),
            'readsPerCore':int(os.environ.get('REVIEW_CREDITS_READS','4')),
            'writesPerCore':int(os.environ.get('REVIEW_CREDITS_WRITES','0')),
            'negative':negative,'expectedError':error,
            'rc':result.returncode,'matched':matched,'metrics':metrics,
            'modelSha256':digest(exe)})
        (out/'results.json').write_text(json.dumps(records,indent=2))
        assert matched,label
    assert all(digest(source/name)==value for name,value in hashes.items())
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
    if os.environ.get('REVIEW_HUB_L2_COMPOSED') == '1':
        return composed_review(out, data, runtime_info, runtime)
    if os.environ.get('REVIEW_HUB_L2_CREDITS') == '1':
        return credits_review(out, data, runtime_info, runtime)
    hub_modes = ('REVIEW_HUB_BASELINE', 'REVIEW_HUB_RESERVATIONS',
                 'REVIEW_HUB_ACK_BEFORE', 'REVIEW_HUB_SIGNATURE',
                 'REVIEW_HUB_PUBLICATION', 'REVIEW_HUB_B_STABILITY',
                 'REVIEW_HUB_LIFETIME', 'REVIEW_HUB_LIFETIME_BEFORE',
                 'REVIEW_HUB_PUBLICATION_BEFORE',
                 'REVIEW_HUB_SIGNATURE_BAD_CREDITS', 'REVIEW_HUB_SYNTH')
    if any(os.environ.get(k) == '1' for k in hub_modes) or \
            os.environ.get('REVIEW_HUB_B_FAULT'):
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
