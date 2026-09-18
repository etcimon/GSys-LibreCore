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


def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()


IQ = r'''
// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
package audit_types;
  typedef struct packed {ariane_pkg::fu_t fu;logic[3:0] trans_id;logic[31:0] pc;} sbe_t;
endpackage
module leaf import ariane_pkg::*; import audit_types::*;
#(parameter int NP=2,D=8,PW=4)(input logic clk_i,rst_ni,flush,mem_stall,
 input logic[15:0] cancel,input logic[NP-1:0] dv,r1,r2,ia,
 input sbe_t[NP-1:0] ds,input logic[NP-1:0][31:0] di,
 input logic[NP-1:0][PW-1:0] p1,p2,pd,input logic[1:0] wv,input logic[1:0][PW-1:0] wp,
 output logic[NP-1:0] da,iv,output sbe_t[NP-1:0] issued,output logic[NP-1:0][31:0] instruction,
 output logic[NP-1:0][PW-1:0] ip,output logic full
`ifdef AUDIT_FORMAL
 ,input logic[3:0] watched_id,input logic[PW-1:0] watched_tag,input logic watched_rs2
 ,output logic seen_wait=0,seen_drain=0
`endif
);
 function automatic config_pkg::cva6_cfg_t cfg();
  config_pkg::cva6_cfg_t c=config_pkg::cva6_cfg_empty;
  c.NrIssuePorts=NP;c.NrWbPorts=2;c.NR_SB_ENTRIES=16;c.TRANS_ID_BITS=4;return c;
 endfunction
 g6lc_iq #(.CVA6Cfg(cfg()),.DEPTH(D),.PRF_W(PW),.scoreboard_entry_t(sbe_t)) dut(
 .clk_i,.rst_ni,.flush_i(flush),.cancelled_mask_i(cancel),.disp_valid_i(dv),.disp_sbe_i(ds),.disp_orig_i(di),
 .disp_prs1_i(p1),.disp_prs2_i(p2),.disp_prd_i(pd),.disp_rs1_ready_i(r1),.disp_rs2_ready_i(r2),
 .disp_ack_o(da),.full_o(full),.wb_valid_i(wv),.wb_prd_i(wp),.issue_sbe_o(issued),.issue_orig_o(instruction),
 .issue_prd_o(ip),.issue_valid_o(iv),.issue_ack_i(ia),.mem_stall_i(mem_stall),
 .st_live_mask_i('0),.commit_ptr_i('0));
`ifdef AUDIT_FORMAL
 logic history_valid=0;
 always_ff @(posedge clk_i)begin
  history_valid<=rst_ni;
  if(rst_ni && history_valid)begin
   assume(watched_id==$past(watched_id));assume(watched_tag==$past(watched_tag));assume(watched_rs2==$past(watched_rs2));
  end
 end
 logic active=0,waiting=0,wb_match;
 always_comb begin
  wb_match=0;
  for(int w=0;w<2;w++)if(wv[w] && wp[w]!=0 && wp[w]==watched_tag)wb_match=1;
 end
 always_ff @(posedge clk_i) begin
  if(!rst_ni || flush)begin active<=0;waiting<=0;end
  else begin
   assert(full==(int'(dut.count_q)+NP>D));
   assert(int'(dut.count_q)<=D);
   for(int e=0;e<D;e++)assert(dut.q_q[e].valid==(e<int'(dut.count_q)));
   begin
    int found;
    found=0;
    for(int e=0;e<D;e++)if(dut.q_q[e].valid && dut.q_q[e].sbe.trans_id==watched_id)begin
     found++;
     if(waiting)begin
      assert(watched_rs2 ? dut.q_q[e].prs2==watched_tag : dut.q_q[e].prs1==watched_tag);
      assert(watched_rs2 ? !dut.q_q[e].rs2_rdy : !dut.q_q[e].rs1_rdy);
     end
    end
    assert(found==int'(active));
    assert(!waiting || active);
   end
   if(active && waiting)seen_wait<=1;
   if(wb_match)waiting<=0;
   if(cancel[watched_id])begin active<=0;waiting<=0;end
   for(int p=0;p<NP;p++)begin
    if(active && iv[p] && issued[p].trans_id==watched_id)begin
     assert(!waiting || wb_match);
     if(ia[p])begin active<=0;waiting<=0;if(seen_wait)seen_drain<=1;end
    end
    if(dv[p] && da[p] && ds[p].trans_id==watched_id)begin
     assume(!active);
     for(int q=0;q<p;q++)assume(!(dv[q] && da[q] && ds[q].trans_id==watched_id));
     active<=1;
     waiting<=!wb_match && (watched_rs2 ? (!r2[p] && p2[p]==watched_tag) : (!r1[p] && p1[p]==watched_tag));
    end
   end
  end
 end
`endif
endmodule
'''

MSHR = r'''
// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
module leaf #(parameter int D=4,NW=2,parameter bit NEG=0)(
 input logic clk_i,rst_ni,flush,av,complete,pop,input logic[15:0] line,input logic[3:0] id,
 input logic[$clog2(D)-1:0] ci,output logic ready,merged,wvalid,empty,full,mfull,lhit,
 output logic[3:0] cid,wid,output logic[$clog2(D)-1:0] ai,li,output logic[$clog2(D):0] count
`ifdef AUDIT_FORMAL
 ,output logic seen_full=0,seen_joint=0,seen_retained=0
`endif
);
 g6lc_l2_mshr #(.DEPTH(D),.ADDR_WIDTH(16),.ID_WIDTH(4),.MAX_WAITERS(NW)) dut(
 .clk_i,.rst_ni,.flush_i(flush),.alloc_i(av),.alloc_line_addr_i(line),.alloc_id_i(id),.alloc_is_write_i(1'b0),
 .alloc_ready_o(ready),.alloc_merged_o(merged),.alloc_idx_o(ai),.lookup_line_addr_i(line),.lookup_hit_o(lhit),.lookup_idx_o(li),
 .complete_i(complete),.complete_idx_i(ci),.complete_id_o(cid),.waiter_valid_o(wvalid),.waiter_id_o(wid),.waiter_pop_i(pop),
 .empty_o(empty),.full_o(full),.merge_full_o(mfull),.count_o(count));
`ifdef AUDIT_FORMAL
 always_ff @(posedge clk_i)if(rst_ni)begin
  int valid_count;
  bit match_found,space_found,can_merge;
  valid_count=0;match_found=0;space_found=0;can_merge=0;
  for(int i=0;i<D;i++)begin
   if(dut.mem_q[i].valid)begin
    valid_count++;
    if(dut.mem_q[i].line_addr==line)begin
     match_found=1;
     can_merge=int'(dut.mem_q[i].nwait)<NW || (pop && int'(ci)==i && dut.mem_q[i].nwait!=0);
    end
   end else begin space_found=1;assert(dut.mem_q[i].nwait==0);end
   assert(int'(dut.mem_q[i].nwait)<=NW);
   for(int j=0;j<i;j++)assert(!(dut.mem_q[i].valid && dut.mem_q[j].valid && dut.mem_q[i].line_addr==dut.mem_q[j].line_addr));
  end
  assert(int'(count)==valid_count);
  assert((ready ^ (NEG && av))==(match_found?can_merge:space_found));
  if(mfull && !full)seen_full<=1;
  if(av && ready && merged && pop && ci==ai)seen_joint<=1;
  if(av && ready && merged && complete && ci==ai)seen_retained<=1;
 end
`endif
endmodule
'''

TAGE = r'''
// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
package tage_types;
 typedef struct packed {logic valid;logic[31:0] pc;logic taken;} update_t;
endpackage
module leaf import ariane_pkg::*; import tage_types::*;
(input logic clk_i,rst_ni,flush,debug_mode,input logic[31:0] pc,input logic[7:0] history,
 input logic[1:0][7:0] folded,input update_t update,output bht_prediction_t[1:0] prediction,output logic hv,ht);
 function automatic config_pkg::cva6_cfg_t cfg();
  config_pkg::cva6_cfg_t c=config_pkg::cva6_cfg_empty;c.VLEN=32;c.RVC=1;c.INSTR_PER_FETCH=2;c.DebugEn=1;return c;
 endfunction
 g6lc_bp_tage #(.CVA6Cfg(cfg()),.bht_update_t(update_t),.NR_ENTRIES(16),.NR_TABLES(2),.TABLE_ENTRIES(8),.TAG_BITS(4),.GHIST_LEN(8)) dut(
 .clk_i,.rst_ni,.flush_bp_i(flush),.debug_mode_i(debug_mode),.vpc_i(pc),.ghist_i(history),.folded_i(folded),
 .bht_update_i(update),.bht_prediction_o(prediction),.hist_update_valid_o(hv),.hist_update_taken_o(ht));
endmodule
'''


DISPATCH_TID=r'''
// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Independent-elaborator check for the dispatch -> LSQ allocation id. The
// simulator reports i_lsq.alloc_id_i as a constant zero while
// dispatch_sbe_i[p].trans_id carries the dispatched value; this asks a second
// frontend (slang/yosys) whether that connection is structurally sound.
module dispatch_tid_check
 (input logic clk_i,rst_ni,input logic[1:0] dv,input logic[3:0] tid0,tid1,input logic[2:0] rawfu);
 import ariane_pkg::*;
 typedef struct packed {fu_t fu;fu_op op;logic[4:0] rs1,rs2,rd;logic[3:0] trans_id;
   logic[63:0] pc,result;logic[7:0] p_rs1,p_rs2,p_rd;logic ooo_renamed;} sbe_t;
 function automatic config_pkg::cva6_cfg_t cfg();
  config_pkg::cva6_cfg_t c=config_pkg::cva6_cfg_empty;
  c.XLEN=64;c.VLEN=64;c.PLEN=56;c.NrHarts=1;c.NrCores=1;c.NrIssuePorts=2;c.NrCommitPorts=2;
  c.NrWbPorts=2;c.NR_SB_ENTRIES=16;c.TRANS_ID_BITS=4;c.PrfEntries=40;c.RobEntries=8;
  c.IqEntries=8;c.LsqLoadEntries=4;c.LsqStoreEntries=4;c.BPCkptDepth=2;c.OoOEn=1;return c;
 endfunction
 sbe_t [1:0] ds;
 always_comb begin
  ds='0;
  ds[0].trans_id=tid0;ds[1].trans_id=tid1;
  ds[0].fu=fu_t'(rawfu);ds[1].fu=fu_t'(rawfu);
  ds[0].op=SD;ds[1].op=SD;
 end
 g6lc_ooo_dispatch #(.CVA6Cfg(cfg()),.scoreboard_entry_t(sbe_t)) dut(
  .clk_i,.rst_ni,.flush_i(1'b0),.flush_unissued_i(1'b0),.cancelled_mask_i('0),
  .dispatch_sbe_i(ds),.dispatch_orig_i('0),.dispatch_valid_i(dv),.dispatch_ack_o(),
  .issue_sbe_o(),.issue_orig_o(),.issue_valid_o(),.issue_ack_i(2'b11),
  .issue_op_a_o(),.issue_op_b_o(),.issue_op_a_valid_o(),.issue_op_b_valid_o(),
  .wb_valid_i('0),.wb_id_i('0),.wb_data_i('0),.wb_exc_i('0),
  .commit_ack_i('0),.commit_instr_i('0),.commit_ptr_i('0),.mispredict_i(1'b0),.mispredict_id_i('0),
  .freelist_empty_o(),.rob_full_o(),.iq_full_o(),.lsq_stall_o(),.rename_stall_o(),.stl_forward_o());
 // Purely combinational, so a single step settles it.
 always_comb begin
  assert(dut.alloc_ids[0]==ds[0].trans_id);
  assert(dut.alloc_ids[1]==ds[1].trans_id);
 end
endmodule
'''


IQ_AGE=r'''
// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Independent-elaborator check for the IQ store-age gate: a queued ready LOAD
// must issue exactly when no live store OLDER than it exists (circular
// trans_id distance anchored at the commit pointer). The integrated dispatch
// suite also covers this end-to-end (scenarios 7/8); this proof keeps the gate
// honest for arbitrary mask/commit-pointer combinations a directed bench
// cannot enumerate.
module iq_age_check
 (input logic clk_i,rst_ni,input logic[3:0] ltid,cp,input logic[15:0] smask);
 import ariane_pkg::*;
 typedef struct packed {fu_t fu;fu_op op;logic[4:0] rs1,rs2,rd;logic[3:0] trans_id;
   logic[63:0] pc,result;logic[7:0] p_rs1,p_rs2,p_rd;logic ooo_renamed;} sbe_t;
 function automatic config_pkg::cva6_cfg_t cfg();
  config_pkg::cva6_cfg_t c=config_pkg::cva6_cfg_empty;
  c.XLEN=64;c.VLEN=64;c.PLEN=56;c.NrHarts=1;c.NrCores=1;c.NrIssuePorts=1;c.NrCommitPorts=1;
  c.NrWbPorts=1;c.NR_SB_ENTRIES=16;c.TRANS_ID_BITS=4;c.PrfEntries=40;c.RobEntries=8;
  c.IqEntries=4;c.LsqLoadEntries=4;c.LsqStoreEntries=4;c.BPCkptDepth=2;c.OoOEn=1;return c;
 endfunction
 logic started=0,pending=0,dv,da,iv;
 sbe_t[0:0] ds;
 always_ff @(posedge clk_i)begin
  if(!rst_ni)begin started<=0;pending<=0;end
  else begin
   started<=1;
   if(da)pending<=1;
   else if(pending&&iv)pending<=0;
  end
 end
 always_comb begin
  dv=!started;
  ds='0;ds[0].fu=LOAD;ds[0].op=LD;ds[0].trans_id=ltid;
 end
 logic older_ref;
 always_comb begin
  older_ref=1'b0;
  for(int s=0;s<16;s++)
   if(smask[s]&&(4'(s)-cp)<(ltid-cp))older_ref=1'b1;
 end
 g6lc_iq #(.CVA6Cfg(cfg()),.DEPTH(4),.PRF_W(4),.scoreboard_entry_t(sbe_t)) dut(
  .clk_i,.rst_ni,.flush_i(1'b0),.cancelled_mask_i('0),
  .disp_valid_i(dv),.disp_sbe_i(ds),.disp_orig_i('0),.disp_prs1_i('0),.disp_prs2_i('0),
  .disp_prd_i('0),.disp_rs1_ready_i(1'b1),.disp_rs2_ready_i(1'b1),.disp_ack_o(da),
  .full_o(),.wb_valid_i('0),.wb_prd_i('0),
  .issue_sbe_o(),.issue_orig_o(),.issue_prd_o(),.issue_valid_o(iv),.issue_ack_i(1'b1),
  .mem_stall_i(1'b0),.st_live_mask_i(smask),.commit_ptr_i(cp));
 always_ff @(posedge clk_i)begin
  if(rst_ni&&started)begin
   // ltid is baked into the queued entry at dispatch; smask/cp are free per
   // step and the gate is combinational, so the reference tracks them live.
   assume(ltid==$past(ltid));
   assume(!smask[ltid]);
   if(pending)assert(iv==!older_ref);
  end
 end
endmodule
'''


def main():
 out=Path(os.environ['TH_OUT_DIR']);data=Path(os.environ['TH_DATA_DIR'])
 base=Path('/opt/testharness/runs/review-rtl-audit-before-v2/output/source')
 hashes=json.loads((base.parent/'sources.json').read_text())
 for name,value in hashes.items():assert digest(base/name)==value
 packages=' '.join(str(data/n) for n in ['config_pkg.sv','g6lc64_smt2_config_pkg.sv','riscv_pkg.sv','ariane_pkg.sv'])
 results=[];areas=[]
 def run(label,script,expected=None):
  work=out/label;work.mkdir();(work/'run.ys').write_text(script)
  with (work/'run.log').open('w') as log:p=subprocess.run(['yosys','-s',str(work/'run.ys')],cwd=work,stdout=log,stderr=subprocess.STDOUT,timeout=180)
  text=(work/'run.log').read_text();ok=(p.returncode!=0 and expected in text) if expected else p.returncode==0
  results.append({'label':label,'rc':p.returncode,'expectedError':expected,'matched':ok});(out/'results.json').write_text(json.dumps(results,indent=2))
  assert ok,label
  return work,text
 if os.environ.get('REVIEW_AUDIT_DISPATCH_TID')=='1':
  wrapper=out/'dispatch_tid.sv';wrapper.write_text(DISPATCH_TID)
  ooo=' '.join(str(data/n) for n in ['g6lc_ooo_pkg.sv','g6lc_rename.sv','g6lc_rob.sv','g6lc_lsq.sv','g6lc_prf.sv','g6lc_memdep.sv','g6lc_iq.sv','g6lc_ooo_dispatch.sv'])
  script=(f'read_slang --top dispatch_tid_check {packages} {ooo} {wrapper}\n'
          'prep -top dispatch_tid_check\nasync2sync\nchformal -lower\nflatten\nmemory_map\n'
          'opt -full\ndffunmap\nopt_clean -purge\n'
          'sat -seq 1 -set rst_ni 1 -prove-asserts -verify\n')
  run('dispatch-tid',script)
  return 0
 if os.environ.get('REVIEW_AUDIT_IQ_AGE')=='1':
  wrapper=out/'iq_age.sv';wrapper.write_text(IQ_AGE)
  script=(f'read_slang --top iq_age_check {packages} {data}/g6lc_iq.sv {wrapper}\n'
          'prep -top iq_age_check\nasync2sync\nchformal -lower\nflatten\nmemory_map\n'
          'opt -full\ndffunmap\nopt_clean -purge\n'
          'sat -seq 4 -set-at 1 rst_ni 0 -set rst_ni 1 -set-assumes -prove-asserts -verify\n')
  run('iq-age',script)
  return 0
 for kind,template,filename in [('iq',IQ,'g6lc_iq.sv'),('mshr',MSHR,'g6lc_l2_mshr.sv'),('tage',TAGE,'g6lc_bp_tage.sv')]:
  if os.environ.get('REVIEW_AUDIT_TAIL')=='1' and kind!='tage':continue
  if os.environ.get('REVIEW_AUDIT_SKIP_IQ')=='1' and kind=='iq':continue
  if os.environ.get('REVIEW_AUDIT_ONLY_IQ')=='1' and kind!='iq':continue
  wrapper=out/(kind+'.sv');wrapper.write_text(template)
  deps=(str(data/'g6lc_bp_tage_table.sv')+' ') if kind=='tage' else ''
  cases=[('-GNP=2 -GD=8 -GPW=4','n2-d8'),('-GNP=4 -GD=16 -GPW=7','n4-d16')] if kind=='iq' else [('-GD=4 -GNW=2','d4'),('-GD=8 -GNW=3','d8')] if kind=='mshr' else [('', 's2')]
  if kind=='iq' and os.environ.get('REVIEW_AUDIT_REUSE_IQ_AREA'):
   saved=json.loads(Path(os.environ['REVIEW_AUDIT_REUSE_IQ_AREA']).read_text())
   assert len(saved)==4 and all(r['kind']=='iq' and r['rtlSha256']==digest((base if r['role']=='before' else data)/filename) for r in saved)
   areas.extend(saved);(out/'area.json').write_text(json.dumps(areas,indent=2));cases=[]
  if os.environ.get('REVIEW_AUDIT_TAIL')=='1':
   saved=json.loads(Path('/opt/testharness/runs/review-rtl-audit-quality-rest-v3/output/area.json').read_text())
   assert len(saved)==6
   for r in saved:
    rtl='g6lc_l2_mshr.sv' if r['kind']=='mshr' else 'g6lc_bp_tage.sv'
    assert r['rtlSha256']==digest((base if r['role']=='before' else data)/rtl)
   areas.extend(saved);(out/'area.json').write_text(json.dumps(areas,indent=2));cases=[]
  for params,geometry in cases:
   for role,root in [('before',base),('after',data)]:
    label=f'synth-{kind}-{geometry}-{role}'
    script=f'read_slang --top leaf {params} {packages} {deps}{root/filename} {wrapper}\nsynth -top leaf -flatten\ncheck -assert\nselect -assert-none t:$dlatch t:$_DLATCH_*\ntee -o stats.json stat -json\n'
    work,text=run(label,script)
    stats=json.loads((work/'stats.json').read_text())['modules']['\\leaf'];types=stats['num_cells_by_type']
    areas.append({'kind':kind,'geometry':geometry,'role':role,'cells':stats['num_cells']-types.get('$scopeinfo',0),'sequentialCells':sum(v for k,v in types.items() if 'DFF' in k.upper()),'cellTypes':types,'rtlSha256':digest(root/filename),'physicalArea':None})
    (out/'area.json').write_text(json.dumps(areas,indent=2))
  if kind in {'iq','mshr'}:
   for role,root,negative in [('before',base,False),('after',data,False),('negative',data,True)]:
    formal=out/(kind+'-'+role+'.sv')
    text=template
    if kind=='mshr' and negative:text=text.replace('NEG=0','NEG=1')
    if kind=='iq' and negative:text=text.replace('assert(full==','assert(!full==')
    formal.write_text(text)
    script=f'read_slang --top leaf -DAUDIT_FORMAL {packages} {root/filename} {formal}\nprep -top leaf\nasync2sync\nchformal -lower\nflatten\nmemory_map\nopt -full\ndffunmap\nopt_clean -purge\nwrite_rtlil model.il\nsat -seq 10 -set-at 1 rst_ni 0 -set rst_ni 1 -set-assumes -prove-asserts -show-ports -dump_vcd witness.vcd -verify\n'
    if kind=='iq' and role=='after':
     script=script.replace('sat -seq 10 -set-at 1 rst_ni 0 -set rst_ni 1 -set-assumes -prove-asserts -show-ports -dump_vcd witness.vcd -verify', 'sat -seq 4 -set-at 1 rst_ni 0 -set rst_ni 1 -set-assumes -prove-asserts -verify\nsat -seq 1 -tempinduct -tempinduct-inductonly -maxsteps 4 -set rst_ni 1 -set-assumes -prove-asserts -show-inputs -show watched_id -show watched_tag -show watched_rs2 -show active -show waiting -dump_vcd induction.vcd -verify')
    work,text=run(f'formal-{kind}-{role}',script,'proof did fail' if role!='after' else None)
    assert ('model found: FAIL!' if role!='after' else 'no model found: SUCCESS!') in text
    if kind=='iq' and role=='after':assert 'Induction step proven' in text
   for goal in (['seen_wait','seen_drain'] if kind=='iq' else ['seen_full','seen_joint','seen_retained']):
    model_path=out/('formal-'+kind+'-after')/'model.il'
    script=f'read_rtlil {model_path}\nchformal -assert -remove\nsat -seq 10 -set-at 1 rst_ni 0 -set rst_ni 1 -set-assumes -prove {goal} 0 -prove-skip 9 -dump_vcd witness.vcd -verify\n'
    work,text=run(kind+'-'+goal,script,'proof did fail');assert 'model found: FAIL!' in text
  if kind=='tage':
   for role,root in [('gold',base),('gate',data)]:
    text=(root/filename).read_text();assert text.count('module g6lc_bp_tage\n')==1
    (out/('tage-'+role+'.sv')).write_text(text.replace('module g6lc_bp_tage\n','module g6lc_bp_tage_'+role+'\n'))
   miter=out/'tage-miter.sv'
   prefix=template[:template.index('module leaf')]
   body=r'''
module miter import ariane_pkg::*; import tage_types::*;
#(parameter bit NEG=0)(input logic clk_i,rst_ni,flush,debug_mode,input logic[31:0] pc,
 input logic[7:0] history,input logic[1:0][7:0] folded,input update_t update);
 function automatic config_pkg::cva6_cfg_t cfg();
  config_pkg::cva6_cfg_t c=config_pkg::cva6_cfg_empty;c.VLEN=32;c.RVC=1;c.INSTR_PER_FETCH=2;c.DebugEn=1;return c;
 endfunction
 bht_prediction_t[1:0] pg,pa;
 logic hg,ha,tg,ta;
 @INSTANCES@
 always_ff @(posedge clk_i)if(rst_ni)begin
  assert((pa ^ (NEG?4'd1:4'd0))==pg);assert(ha==hg && ta==tg);
  assert(gold.base_q==gate.base_q);
 end
 for(genvar t=0;t<2;t++)begin
  always_ff @(posedge clk_i)if(rst_ni)for(int e=0;e<8;e++)begin
   assert(gold.gen_tables[t].i_table.mem_q[e]==gate.gen_tables[t].i_table.mem_q[e]);
   assert(!gold.gen_tables[t].i_table.mem_q[e].u && !gate.gen_tables[t].i_table.mem_q[e].u);
  end
 end
endmodule
'''
   instances=[]
   for role,suffix in [('gold','g'),('gate','a')]:
    instances.append(f'g6lc_bp_tage_{role} #(.CVA6Cfg(cfg()),.bht_update_t(update_t),.NR_ENTRIES(16),.NR_TABLES(2),.TABLE_ENTRIES(8),.TAG_BITS(4),.GHIST_LEN(8)) {role} (.clk_i,.rst_ni,.flush_bp_i(flush),.debug_mode_i(debug_mode),.vpc_i(pc),.ghist_i(history),.folded_i(folded),.bht_update_i(update),.bht_prediction_o(p{suffix}),.hist_update_valid_o(h{suffix}),.hist_update_taken_o(t{suffix}));')
   miter.write_text(prefix+body.replace('@INSTANCES@','\n'.join(instances)))
   for negative in [False,True]:
    params='-GNEG=1' if negative else ''
    script=f'read_slang --top miter {params} {packages} {deps} {out/"tage-gold.sv"} {out/"tage-gate.sv"} {miter}\nprep -top miter\nasync2sync\nchformal -lower\nflatten\nmemory_map\nopt -full\ndffunmap\nopt_clean -purge\nsat -seq 4 -set-at 1 rst_ni 0 -set rst_ni 1 -prove-asserts -verify\n'
    if not negative:script+='sat -seq 1 -tempinduct -tempinduct-inductonly -maxsteps 4 -set rst_ni 1 -prove-asserts -verify\n'
    _,text=run('tage-output-negative' if negative else 'tage-output-equivalence',script,'proof did fail' if negative else None)
    assert ('model found: FAIL!' if negative else 'Induction step proven') in text
 if os.environ.get('REVIEW_AUDIT_ONLY_IQ')=='1':return 0
 for role,root in [('before',base),('after',data)]:
  cluster=(root/'g6lc_cluster.sv').read_text();start=cluster.index('  always_comb begin',cluster.index('  // Merge hub + inclusive inv'));end=cluster.index('  // --------------------',start)
  mux=cluster[start:end];ready=re.findall(r'\.evict_addr_i\s*\(evict_a\),\s*\.inv_ready_i\s*\((\w+)\)',cluster)[0]
  wrapper=out/('incl-'+role+'.sv')
  wrapper.write_text('// Copyright (c) 2026 Etienne Cimon\n// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial\nmodule leaf import g6lc_coherence_pkg::*; #(parameter int NC=3)(input logic[NC-1:0] inv_core_ready,input coh_inval_t[NC-1:0] inv_hub,inv_incl,output coh_inval_t[NC-1:0] inv_to_core,output logic[NC-1:0] ack);logic[NC-1:0] inv_incl_ready;\n'+mux+f'assign ack={ready};\n'+'''`ifdef AUDIT_FORMAL
 always_comb for(int c=0;c<NC;c++)begin
  assert(ack[c]==(inv_core_ready[c] && !inv_hub[c].valid));
  assert(inv_to_core[c]==(inv_hub[c].valid?inv_hub[c]:inv_incl[c]));
 end
`endif
endmodule
''')
  deps=f'{data/"config_pkg.sv"} {data/"g6lc_coherence_pkg.sv"}'
  script=f'read_slang --top leaf -DAUDIT_FORMAL {deps} {wrapper}\nprep -top leaf\nchformal -lower\nflatten\nopt -full\nsat -prove-asserts -verify\n'
  run('incl-formal-'+role,script,'proof did fail' if role=='before' else None)
  script=f'read_slang --top leaf {deps} {wrapper}\nsynth -top leaf -flatten\ncheck -assert\ntee -o stats.json stat -json\n'
  work,_=run('incl-synth-'+role,script);stats=json.loads((work/'stats.json').read_text())['modules']['\\leaf'];types=stats['num_cells_by_type']
  areas.append({'kind':'incl','geometry':'n3','role':role,'cells':stats['num_cells']-types.get('$scopeinfo',0),'sequentialCells':sum(v for k,v in types.items() if 'DFF' in k.upper()),'physicalArea':None});(out/'area.json').write_text(json.dumps(areas,indent=2))
 (out/'sources.json').write_text(json.dumps({p.name:digest(p) for p in data.iterdir() if p.is_file()},indent=2))
 return 0


if __name__=='__main__':sys.exit(main())
