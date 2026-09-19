"""Port-driven WT fixup freshness regression using lowered RTL simulation.

Copyright (c) 2026 Etienne Cimon
SPDX-License-Identifier: MIT
"""
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import subprocess


def main():
    data, out = Path(os.environ['TH_DATA_DIR']), Path(os.environ['TH_OUT_DIR'])
    source = out / 'source'
    source.mkdir()
    names = ['config_pkg.sv', 'g6lc64_smt2_config_pkg.sv', 'riscv_pkg.sv', 'ariane_pkg.sv',
             'wt_cache_pkg.sv', 'cf_math_pkg.sv', 'lzc.sv', 'rr_arb_tree.sv', 'cva6_fifo_v3.sv',
             'wt_dcache_wbuffer.sv', 'tb_g6lc_rtl_review.sv']
    for name in names:
        shutil.copy2(data / name, source / name)
    fault = os.environ.get('WT_FIXUP_FAULT', '')
    if fault:
        rtl_path = source / 'wt_dcache_wbuffer.sv'
        rtl = rtl_path.read_text()
        if fault == 'capacity':
            old, new = '(!fixup_full || fixup_match)', '!fixup_full'
        elif fault == 'bytes':
            old, new = 'merged.be = prior.be | be;', 'merged.be = be;'
        elif fault == 'retire':
            old, new = ' && !fixup_active_coalesced', ''
        elif fault == 'export':
            start = rtl.index('        if (fixup_push) begin', rtl.index('p_fixup_wbuffer'))
            end = rtl.index('\n      end\n    end\n  endgenerate', start)
            old = rtl[start:end]
            new = '''        if (fixup_push) begin
          fixup_wbuffer_o[0].wtag = wbuffer_q[rtrn_ptr].wtag;
          fixup_wbuffer_o[0].data = fixup_data_push;
          fixup_wbuffer_o[0].valid = fixup_be_push;
        end'''
        else:
            raise ValueError('unknown fixup fault')
        if rtl.count(old) != (3 if fault == 'retire' else 1):
            raise RuntimeError('fixup mutation site changed')
        rtl_path.write_text(rtl.replace(old, new))
    (out / 'sources.json').write_text(json.dumps({n: hashlib.sha256((source / n).read_bytes()).hexdigest()
                                                 for n in names}, indent=2))
    bench = (source / 'tb_g6lc_rtl_review.sv').read_text()
    prefix = 'module tb_g6lc_review_wt_tag;' + bench.split('module tb_g6lc_review_wt_tag;', 1)[1].split('  task automatic cycle(', 1)[0]
    prefix = prefix.replace('module tb_g6lc_review_wt_tag;', 'module wt_fixup_copy(input logic clk, output logic checked=0);')
    prefix = prefix.replace('logic clk=0, rst_n=0, empty;', 'logic rst_n, empty;')
    prefix = prefix.replace('  assign rd_hit = previous_read && rd_tag == previous_tag ? 2\'b01 : 2\'b00;', '''
  logic [6:0] step=0;
  logic [7:0] read_index=0, write_index;
  logic [3:0] write_offset;
  logic refill;
  logic [7:0] refill_index;
  logic [63:0] cache_word=0, golden_word=0, visible_word;
  logic saw_old=0, saw_other, race_seen=0, race_done=0, race_check=0, wr_grant;
  logic [7:0] mask_seen;
  localparam logic [63:0] OLD=64'h1122334455667788;
  localparam logic [63:0] NEW=64'h8877665544332211;
  localparam logic [52:0] WORD={TAG_A,9'h25};
  assign rd_hit = previous_read && rd_tag == TAG_A &&
      ((read_index == 8'h12 && step >= @RESIDENT@) ||
       (read_index == 8'h13 && step >= 55) ||
       (read_index == 8'h14 && step >= 56)) ? 2'b01 : 2'b00;
''')
    prefix = prefix.replace(".wr_cl_vld_i(1'b0), .wr_cl_idx_i('0)", '.wr_cl_vld_i(refill), .wr_cl_idx_i(refill_index)')
    prefix = prefix.replace('.wr_idx_o(), .wr_off_o()', '.wr_idx_o(write_index), .wr_off_o(write_offset)')
    prefix = prefix.replace(".wr_ack_i(1'b1)", '.wr_ack_i(wr_grant)')
    driver = '''
  always_comb begin
    rst_n=step != 0;
    request='0;
    request.address_tag=TAG_A;
    request.data_be='1;
    request.data_wdata=OLD;
    request.data_req=step == 1 || step == 10 || step == 19 || step == 32;
    request.address_index=step == 1 ? 12'h138 : step == 19 ? 12'h148 : 12'h128;
    if (step == 32) begin
      request.data_wdata=NEW;
      request.data_be=@BE@;
    end
    rd_ack=1;
    miss_ack=step == 6 || step == 15 || step == 24 || step == 39;
    return_valid=step == 7 || step == 16 || step == 25 || (@RACE@ ?
        ((|wr_req) && write_index == 8'h12 && !race_seen) : step == 40);
    wr_grant=!@RACE@ || !(|wr_req) || write_index != 8'h12 || race_seen;
    refill=step == @RESIDENT@ || step == 55 || step == 56;
    refill_index=step == 55 ? 8'h13 : step == 56 ? 8'h14 : 8'h12;
    visible_word=cache_word;
    mask_seen='0;
    saw_other=0;
    for (int f=0; f<=FIXUP; f++) begin
      if (fixups[f].wtag == {TAG_A,9'h29} && fixups[f].valid == 8'hff && fixups[f].data == OLD)
        saw_other=1;
      if (fixups[f].wtag == WORD) begin
        for (int b=0; b<8; b++) begin
          if (fixups[f].valid[b] && !mask_seen[b]) begin
            visible_word[b*8+:8]=fixups[f].data[b*8+:8];
            mask_seen[b]=1'b1;
          end
        end
      end
    end
    for (int f=0; f<4; f++) begin
      if (buffered[f].wtag == WORD) begin
        for (int b=0; b<8; b++)
          if (buffered[f].valid[b]) visible_word[b*8+:8]=buffered[f].data[b*8+:8];
      end
    end
  end
  always @(posedge clk) begin
    if (step < 90) step <= step+1'b1;
    previous_read <= rst_n && rd_req && rd_ack;
    read_index <= rd_index;
    if (miss_req && miss_ack) return_id <= miss_id;
    if (rst_n) begin
      if (request.data_req) accepted_write: assert(response.data_gnt);
      if (miss_ack) accepted_tx: assert(miss_req);
      if (request.data_req && response.data_gnt && request.address_index == 12'h128)
        for (int b=0; b<8; b++)
          if (request.data_be[b]) golden_word[b*8+:8] <= request.data_wdata[b*8+:8];
      if (step == 30) begin
        for (int f=0; f<=FIXUP; f++)
          if (fixups[f].wtag == WORD && fixups[f].valid == 8'hff && fixups[f].data == OLD) saw_old <= 1;
      end
      if (step == 41 && !@RACE@) other_copy_survives: assert(saw_other);
      if (@RACE@ && (|wr_req) && write_index == 8'h12) begin
        race_seen <= 1;
        if (race_seen) race_done <= 1;
      end
      race_check <= @RACE@ && (|wr_req) && write_index == 8'h12 && race_seen && !race_done;
      if (race_check) coalesce_retire: assert((visible_word ^ @NEG@) == golden_word);
      if (|wr_req && wr_grant && write_index == 8'h12 && write_offset == 8)
        for (int b=0; b<8; b++)
          if (wr_be[b]) cache_word[b*8+:8] <= wr_data[b*8+:8];
      if ((step == 55 && !@RACE@) || step == 80) begin
        if (@RACE@) race_reached: assert(race_done);
        setup_old: assert(saw_old || FIXUP == 0);
        buffer_drained: assert(empty);
        latest_word: assert((visible_word ^ @NEG@) == golden_word);
        checked <= 1;
      end
    end
  end
endmodule
'''
    before = os.environ.get('WT_FIXUP_BEFORE') == '1'
    export_before = os.environ.get('WT_FIXUP_EXPORT_BEFORE') == '1'
    results = []
    for depth in (2, 4):
        for scenario, resident, mask in ((0, 54, "8'hff"), (1, 54, "8'h03"), (2, 30, "8'hff"), (3, 54, "8'hff")):
            if fault and (depth != 2 or scenario != {'capacity': 0, 'bytes': 1, 'retire': 3, 'export': 0}[fault]):
                continue
            for negative in ([False] if before or export_before or fault else [False, True]):
                label = f'd{depth}-s{scenario}-n{int(negative)}'
                harness = source / (label + '.sv')
                text = prefix.replace('parameter int FIXUP=2;', f'parameter int FIXUP={depth};') + driver
                text = text.replace('@RESIDENT@', str(resident)).replace('@BE@', mask).replace('@RACE@', "1'b1" if scenario == 3 else "1'b0").replace('@NEG@', "64'd1" if negative else "64'd0")
                harness.write_text(text)
                script = out / (label + '.ys')
                rtl = [str(source / n) for n in names if n.endswith('.sv') and not n.startswith('tb_')]
                script.write_text('read_slang --std 1800-2017 -DG6LC_FETCH_B -DVERILATOR --top wt_fixup_copy '
                                  + ' '.join(rtl + [str(harness)])
                                  + '\nprep -top wt_fixup_copy\nflatten\nasync2sync\nchformal -lower\nmemory_map\nopt\ncheck -assert\n'
                                  + f'sim -clock clk -n 85 -assert -q -vcd {out}/{label}.vcd -summary {out}/{label}-summary.json\n')
                with (out / (label + '.log')).open('w') as log:
                    rc = subprocess.run(['/opt/testharness/toolchains/formal/bin/yosys', '-s', str(script)],
                                        stdout=log, stderr=subprocess.STDOUT, timeout=180).returncode
                log_text = (out / (label + '.log')).read_text()
                expected_failure = bool(fault) or negative or before or (export_before and scenario < 3)
                markers = ('other_copy_survives',) if export_before else ('latest_word', 'coalesce_retire', 'other_copy_survives')
                matched = (rc != 0 and any(m in log_text for m in markers) and 'failed' in log_text) if expected_failure else rc == 0
                if matched and not expected_failure:
                    wave = (out / (label + '.vcd')).read_text()
                    token = re.search(r'\$var\s+\w+\s+1\s+(\S+)\s+checked\s+\$end', wave)
                    if not token or not re.search(r'^(?:b1\s+' + re.escape(token[1]) + r'|1' + re.escape(token[1]) + r')$', wave, re.M):
                        raise RuntimeError('freshness checker was not reached')
                results.append({'depth': depth, 'scenario': scenario, 'negative': negative,
                                'rc': rc, 'matched': matched})
                (out / 'results.json').write_text(json.dumps(results, indent=2))
                if not matched:
                    raise RuntimeError(f'fixup outcome mismatch: {label}')
    print('WT_FIXUP_COPY ' + json.dumps(results))


if __name__ == '__main__':
    main()
