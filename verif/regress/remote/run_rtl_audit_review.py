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


L3_BENCH = r'''
// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
module tb_g6lc_review_incl;
  import g6lc_coherence_pkg::*;
  parameter int NC=3;
  logic clk=0,rst_n=0,evict=0,evict_rdy;
  logic [63:0] evict_addr=64'h4000;
  logic [NC-1:0] inv_core_ready='0,inv_incl_ready;
  coh_inval_t [NC-1:0] inv_hub='0,inv_incl,inv_to_core;
  int delivered[NC];
  int got_a[NC],got_b[NC];
  int scenario;
  bit negative;
  @MUX@
  g6lc_l3_inclusive_inv #(.InclusiveEn(1),.NR_CORES(NC)) dut(
    .clk_i(clk),.rst_ni(rst_n),.evict_valid_i(evict),.evict_addr_i(evict_addr),
    .inv_ready_i(@READY@),.inv_o(inv_incl),.inv_busy_o(),.evict_ready_o(evict_rdy));
  task automatic tick;clk=1;#2;clk=0;#2;endtask
  initial begin
    negative=$test$plusargs("oracle_negative");scenario=0;
    void'($value$plusargs("scenario=%d",scenario));
    #2;tick();rst_n=1;
    if(scenario==0)begin
      evict=1;#2;tick();evict=0;
      for(int n=0;n<8;n++)begin
        inv_hub='0;inv_core_ready='1;
        if(n<3)begin inv_hub[0].valid=1;inv_hub[0].dcache=1;inv_hub[0].line_addr=coh_line_tag(64'h9000,64);end
        #2;
        for(int c=0;c<NC;c++)if(inv_to_core[c].valid && inv_core_ready[c])begin
          if(inv_hub[c].valid)begin if(inv_to_core[c]!==inv_hub[c])$fatal(1,"L3_PRIORITY got=%h expected=%h",inv_to_core[c],inv_hub[c]);end
          else begin
            if((inv_to_core[c].line_addr ^ (negative?56'd1:56'd0))!==coh_line_tag(64'h4000,64))$fatal(1,"L3_PAYLOAD");
            delivered[c]++;
          end
        end
        tick();
      end
      for(int c=0;c<NC;c++)if(delivered[c]!=1)$fatal(1,"L3_SOURCE_ACK core=%0d delivered=%0d",c,delivered[c]);
    end
    // Backpressure must be asserted while a back-invalidation is draining, so a
    // producer can tell that offering another victim now would lose it.
    else if(scenario==1)begin
      inv_core_ready='0;
      if(!evict_rdy)$fatal(1,"L3_EVICT_READY_IDLE");
      evict=1;evict_addr=64'h4000;#2;tick();evict=0;
      #2;
      if(evict_rdy!==(negative?1'b1:1'b0))
        $fatal(1,"L3_EVICT_NO_BACKPRESSURE rdy=%b while draining",evict_rdy);
    end
    // A producer that HOLDS the victim until accepted must lose nothing: both
    // victims are invalidated on every core, exactly once each.
    else if(scenario==2)begin
      fork
        begin : producer
          logic [63:0] queue[2];
          queue[0]=64'h4000;queue[1]=64'h8000;
          for(int k=0;k<2;k++)begin
            evict_addr=queue[k];evict=1;
            while(!evict_rdy) @(negedge clk);
            @(negedge clk);
            evict=0;
            @(negedge clk);
          end
        end
        begin : consumer
          for(int n=0;n<40;n++)begin
            inv_hub='0;inv_core_ready='1;
            #2;
            for(int c=0;c<NC;c++)if(inv_to_core[c].valid && inv_core_ready[c])begin
              if(inv_to_core[c].line_addr===coh_line_tag(64'h4000,64))got_a[c]++;
              if(inv_to_core[c].line_addr===coh_line_tag(64'h8000,64))got_b[c]++;
            end
            tick();
          end
        end
      join
      for(int c=0;c<NC;c++)begin
        if(got_a[c]!=1)$fatal(1,"L3_EVICT_LOST_A core=%0d n=%0d",c,got_a[c]);
        if(got_b[c]!=(negative?0:1))$fatal(1,"L3_EVICT_LOST_B core=%0d n=%0d",c,got_b[c]);
      end
    end
    else $fatal(1,"L3_SCENARIO");
    $display("RTL_REVIEW_PASS incl");$finish;
  end
endmodule
'''


def main():
    data=Path(os.environ['TH_DATA_DIR']);out=Path(os.environ['TH_OUT_DIR'])
    wb_fault=os.environ.get('REVIEW_RTL_WB_FAULT')=='1'
    drop_fault=os.environ.get('REVIEW_RTL_DROP_FAULT')
    # Restores the missing commit-time PRF mirror, so scenario 19 must fail again.
    lateresult_fault=os.environ.get('REVIEW_RTL_LATERESULT_FAULT')=='1'
    before=os.environ.get('REVIEW_RTL_BEFORE')=='1' or wb_fault or bool(drop_fault) or lateresult_fault
    source=out/'source';source.mkdir()
    names=['config_pkg.sv','g6lc64_smt2_config_pkg.sv','riscv_pkg.sv','ariane_pkg.sv','g6lc_iq.sv','g6lc_bp_tage_table.sv','g6lc_bp_tage.sv','g6lc_bp_ghist.sv','g6lc_bp_ckpt.sv','g6lc_bp_ittage.sv','g6lc_l2_mshr.sv','g6lc_coherence_pkg.sv','g6lc_l3_inclusive_inv.sv','g6lc_cluster.sv','g6lc_core_types.svh','tb_g6lc_rtl_review.sv']
    # scoreboard.sv (and its smt_legacy/fetch_A helper packages) are only
    # needed by the commit kind; every other kind leaves that bench module
    # unelaborated, so the legacy files stay out of the payload.
    if os.environ.get('REVIEW_RTL_STORE_RECOVERY')=='1':
        names[-1:-1]=['store_buffer.sv']
    if os.environ.get('REVIEW_RTL_WFI')=='1':
        names[-1:-1]=['commit_stage.sv','controller.sv']
    if os.environ.get('REVIEW_RTL_COMMIT')=='1':
        names[-1:-1]=['g6lc_sb_keep.sv','g6lc_rvc_enc.sv','g6lc_fe_keep.sv','g6lc_jalr_usable.sv','g6lc_sib_cjalr.sv','scoreboard.sv']
    if os.environ.get('REVIEW_RTL_SBHEAD')=='1':
        names[-1:-1]=['g6lc_sb_keep.sv','g6lc_rvc_enc.sv','g6lc_fe_keep.sv','g6lc_jalr_usable.sv','g6lc_sib_cjalr.sv','scoreboard.sv']
    if os.environ.get('REVIEW_RTL_CSRBUF')=='1':
        names[-1:-1]=['csr_buffer.sv']
    # g6lc_iq.sv is in the base source list and calls g6lc_ooo_pkg::ooo_age_*,
    # so every cell needs the package ahead of it.
    names[4:4]=['g6lc_ooo_pkg.sv']
    dispatch_mode=os.environ.get('REVIEW_RTL_DISPATCH')=='1' or os.environ.get('REVIEW_RTL_LSQ')=='1' or os.environ.get('REVIEW_RTL_RENAME')=='1'
    if dispatch_mode:
        names+=['g6lc_rename.sv','g6lc_rob.sv','g6lc_lsq.sv','g6lc_prf.sv','g6lc_memdep.sv','g6lc_ooo_dispatch.sv']
    for name in names:shutil.copy2(data/name,source/name)
    # Fault control for the checkpoint-retirement repair: with retirement
    # disabled the pool behaves as it did before the fix, so the new scenario
    # has to fail. Anything else means the scenario is not the discriminator.
    # Same shape for the LSQ group-credit repair: restoring the any-free-entry
    # admission term must make the group-credit scenario fail.
    credit_fault=os.environ.get('REVIEW_RTL_CREDIT_FAULT')=='1'
    # Restores the free-list-snapshot recovery, so the allocation-leak scenario
    # must fail.
    leak_fault=os.environ.get('REVIEW_RTL_LEAK_FAULT')=='1'
    if leak_fault:
        assert os.environ.get('REVIEW_RTL_RENAME')=='1'
        path=source/'g6lc_rename.sv';text=path.read_text()
        # Both halves are needed to reproduce the original semantics: seed the
        # per-level mask with the free list AND drop the accumulation, so
        # squashed becomes exactly (free at checkpoint) & ~(free now). Seeding
        # alone leaves the accumulation to re-add the later allocation.
        # The accumulation is now hart-qualified (Phase4 per-hart namespaces),
        # so the injection text tracks that form.
        accumulate = ("            for (int unsigned s = 0; s < CKPT_DEPTH; s++)\n"
                      "              if (ckpt_hart_d[s] == hart_i[p]) "
                      "ckpt_alloc_d[s][picked] = 1'b1;")
        for old, new in (
            ("          ckpt_alloc_d[ckpt_slot_c[p]] = '0;",
             "          ckpt_alloc_d[ckpt_slot_c[p]] = free_d;"),
            (accumulate, "            /* accumulation removed by fault control */"),
        ):
            assert text.count(old)==1,'leak fault injection site changed'
            text=text.replace(old,new)
        path.write_text(text)
    # Restores the identity-map flush, so the committed-state scenario must fail.
    flush_fault=os.environ.get('REVIEW_RTL_FLUSH_FAULT')=='1'
    if flush_fault:
        assert os.environ.get('REVIEW_RTL_RENAME')=='1'
        path=source/'g6lc_rename.sv';text=path.read_text()
        old='      map_d  = amap_d;'
        assert text.count(old)==1,'flush fault injection site changed'
        text=text.replace(old,"      for (int unsigned i = 0; i < 32; i++) map_d[i] = PRF_W'(i);")
        path.write_text(text)
    if credit_fault:
        assert os.environ.get('REVIEW_RTL_DISPATCH')=='1'
        path=source/'g6lc_ooo_dispatch.sv';text=path.read_text()
        old="    lsq_disp_block = (n_ld > int'(ld_free)) || (n_st > int'(st_free));"
        assert text.count(old)==1,'credit fault injection site changed'
        path.write_text(text.replace(
            old,"    lsq_disp_block = ((|is_ld) && ld_full) || ((|is_st) && st_full);"))
    rename_fault=os.environ.get('REVIEW_RTL_RENAME_FAULT')
    if rename_fault:
        assert rename_fault=='release' and os.environ.get('REVIEW_RTL_RENAME')=='1'
        path=source/'g6lc_rename.sv';text=path.read_text()
        # Retirement is now counted per hart, so the fault clamps that hart's
        # count to zero instead of the old single-ring $countones.
        old="      if (n_ret > int'(ckpt_cnt_d[h])) n_ret = int'(ckpt_cnt_d[h]);"
        assert text.count(old)==1,'rename fault injection site changed'
        path.write_text(text.replace(old,'      n_ret = 0;'))
    if lateresult_fault:
        path=source/'g6lc_ooo_dispatch.sv';text=path.read_text()
        old="      prf_we[CVA6Cfg.NrWbPorts+c]    = commit_we_i[c] && (commit_prd[c] != '0);"
        assert text.count(old)==1,'late-result fault injection site changed'
        path.write_text(text.replace(old,"      prf_we[CVA6Cfg.NrWbPorts+c]    = 1'b0;"))
    if wb_fault:
        path=source/'g6lc_ooo_dispatch.sv';text=path.read_text()
        for old,new in (
            ('.wb_valid_i(data_wb_valid)', '.wb_valid_i(wb_valid_i)'),
            ('.wb_valid_i      (data_wb_valid)', '.wb_valid_i      (wb_valid_i)'),
            ('if (wb_value_valid[w] && issue_sbe_o[p].ooo_renamed)',
             'if (wb_valid_i[w] && !wb_exc_i[w] && issue_sbe_o[p].ooo_renamed)')):
            assert text.count(old)==1,'writeback fault site changed'
            text=text.replace(old,new)
        path.write_text(text)
    if drop_fault:
        target={'map':'commit_wr[c]  =','free':'free_en[c]  =','checkpoint':'ckpt_retire[c] ='}[drop_fault]
        path=source/'g6lc_ooo_dispatch.sv';text=path.read_text()
        old=target+' commit_arch[c]'
        assert text.count(old)==1,'retirement fault site changed'
        path.write_text(text.replace(old,target+' commit_ack_i[c]'))
    hart_dispatch=os.environ.get('REVIEW_RTL_HART_DISPATCH')=='1'
    if hart_dispatch:
        # T6a qualified integer multi-hart OoO under the drained handoff, so the
        # generic gen_err_ooo_smt elaboration guard is gone on purpose. Assert it
        # stays absent; the FP multi-hart leg (gen_err_ooo_fp_mh) remains.
        text=(source/'g6lc_ooo_dispatch.sv').read_text()
        assert text.count('gen_err_ooo_smt')==0,'gen_err_ooo_smt guard reappeared'
    fp_dispatch=os.environ.get('REVIEW_RTL_FP_DISPATCH')=='1'
    fp_zero_fault=os.environ.get('REVIEW_RTL_FP_ZERO_FAULT')=='1'
    fp_commit_fault=os.environ.get('REVIEW_RTL_FP_COMMIT_FAULT')=='1'
    if fp_zero_fault or fp_commit_fault:
        assert fp_dispatch,'FP fault requires the FP dispatch fixture'
        path=source/'g6lc_ooo_dispatch.sv';text=path.read_text()
        old=".ZERO_REG_ZERO(1'b0)" if fp_zero_fault else "(commit_is_fpr[c] || commit_instr_i[c].rd != 5'd0)"
        new=".ZERO_REG_ZERO(1'b1)" if fp_zero_fault else "(!commit_is_fpr[c] && commit_instr_i[c].rd != 5'd0)"
        assert text.count(old)==1,'FP fault site changed'
        path.write_text(text.replace(old,new))
    if fp_dispatch:
        path=source/'g6lc_ooo_dispatch.sv';text=path.read_text()
        old='  if (CVA6Cfg.FpPresent) begin : gen_err_ooo_fp'
        assert text.count(old)==1,'FP qualification guard site changed'
        path.write_text(text.replace(old,'  if (CVA6Cfg.FpPresent && CVA6Cfg.NrHarts > 1) begin : gen_err_ooo_fp'))
    hashes={name:digest(source/name) for name in names}
    (out/'sources.json').write_text(json.dumps(hashes,indent=2))
    cluster=(source/'g6lc_cluster.sv').read_text()
    begin=cluster.index('  // Merge hub + inclusive inv')
    start=cluster.index('  always_comb begin',begin)
    end=cluster.index('  // --------------------',start)
    mux=cluster[start:end]
    ready=re.findall(r'\.evict_addr_i\s*\(evict_a\),\s*\.inv_ready_i\s*\((\w+)\)',cluster)
    assert len(ready)==1 and ready[0] in {'inv_core_ready','inv_incl_ready'}
    (source/'incl.sv').write_text(L3_BENCH.replace('@MUX@',mux).replace('@READY@',ready[0]))
    runtime_info=json.loads(Path('/opt/testharness/runs/review-private-runtime-rebuild-20260915/output/runtime.json').read_text())
    runtime=Path(runtime_info['privateRoot'])
    assert digest(runtime/'include/verilated_funcs.h')=='dfbc2c4aa3c1065d4465027c893c9677de10da4cfe7fb152e485eb32b8125166'
    (out/'runtime.json').write_text(json.dumps(runtime_info,indent=2))
    rtl=[str(source/name) for name in names if name!='g6lc_cluster.sv' and not name.endswith('.svh')]+[str(source/'incl.sv')]
    configurations=[]
    for np,d in ([(2,8)] if before else [(1,8),(2,8),(4,8),(2,16)]):
        cases=[(0,None),(1,'IQ_VALID'),(2,'IQ_ISSUE'),(3,'IQ_CREDIT')] if before else [(n,None) for n in range(10)]
        configurations.append(('iq',f'n{np}-d{d}',[f'-GNP={np}',f'-GDEPTH={d}'],cases))
    for d,nw in ([(4,2)] if before else [(2,1),(4,2),(8,3)]):
        cases=[(0,None),(1,'MSHR_ADMISSION'),(2,'MSHR_ADMISSION'),(3,'MSHR_RETENTION'),(4,None)] if before else [(n,None) for n in range(5)]
        configurations.append(('mshr',f'd{d}-w{nw}',[f'-GD={d}',f'-GNW={nw}'],cases))
    for slots,rvc in ([(2,1)] if before else [(1,0),(2,1),(4,1)]):
        configurations.append(('decay',f's{slots}-c{rvc}',[f'-GSLOTS={slots}',f'-GRVC={rvc}'],[(0,'TAGE_DECAY' if before else None)]))
    for nc in ([3] if before else [1,3,4]):
        cases=[(0,'L3_SOURCE_ACK' if before else None)]
        # 1: backpressure must be asserted while a back-invalidation drains.
        # 2: a producer that honours it must lose no victim.
        if not before:cases+=[(1,None),(2,None)]
        configurations.append(('incl',f'n{nc}',[f'-GNC={nc}'],cases))
    if os.environ.get('REVIEW_RTL_STORE_RECOVERY')=='1':
        configurations=[('store_recovery',f'nh{h}-ooo{o}',['-DG6LC_FETCH_B',f'-GNH={h}',f'-GOOO={o}'],
                         [(n,None) for n in range(8 if (h,o)==(2,1) else 6 if o else 4)])
                        for h,o in ((1,0),(1,1),(2,1))]
    elif os.environ.get('REVIEW_RTL_WFI')=='1':
        configurations=[('wfi',f'ooo{o}-a{a}',['-DG6LC_FETCH_B',f'-GOOO={o}',f'-GRVA_EN={a}'],
                         [(n,None) for n in range(7)]) for o in (0,1) for a in (0,1)]
    elif os.environ.get('REVIEW_RTL_COMMIT')=='1':
        configurations=[('commit','p4',['-GNPC=4'],[(0,None),(1,None)])]
    elif os.environ.get('REVIEW_RTL_RENAME')=='1':
        # Phase4 per-hart namespaces. g6lc_rename is package-free, so NR_HARTS=2
        # is exercised HERE without relaxing check_cfg's !(OoOEn && NrHarts>1)
        # refusal, which still governs the full core. PRF holds 31 committed
        # physicals per hart (62) plus a rename pool.
        # Phase5 split FP class. FP needs 32 committed physicals per hart (f0 is
        # real, so 32 not 31) plus a pool, hence the wider FP file.
        if os.environ.get('REVIEW_RTL_RENAME_FP_SMT')=='1':
            configurations=[('rename','fp-nh2',['-GNR_HARTS=2','-GPRF_ENTRIES=80','-GPRF_W=7',
                                              '-GFPRF_ENTRIES=80','-GFPRF_W=7'],[(24,None),(25,None)])]
        elif os.environ.get('REVIEW_RTL_RENAME_FP')=='1':
            configurations=[('rename','fp',['-GFPRF_ENTRIES=64','-GFPRF_W=7'],
                             [(n,None) for n in (20,21,22,23)])]
        elif os.environ.get('REVIEW_RTL_RENAME_SMT')=='1':
            configurations=[('rename','nh2',['-GNR_HARTS=2','-GPRF_ENTRIES=80','-GPRF_W=7'],
                             [(n,None) for n in (11,12,13,14,15)])]
        else:
            configurations=[('rename','direct',[],
                             [(7,'RENAME_CKPT_NO_RELEASE')] if rename_fault
                             else [(9,'RENAME_FLUSH_ARCH')] if flush_fault
                             else [(10,'RENAME_CKPT_ALLOC_LEAK')] if leak_fault
                             else [(n,None) for n in range(11)])]
    elif os.environ.get('REVIEW_RTL_LSQ')=='1':
        # T6b: nh2 runs the full single-hart suite (all ops hart 0 — must match
        # HARTS=1) plus the cross-hart scenarios 19-24.
        configurations=[('lsq','direct',[],[(n,None) for n in range(19)]),
                        ('lsq','nh2',['-GHARTS=2'],[(n,None) for n in range(25)])]
    elif os.environ.get('REVIEW_RTL_CSRBUF')=='1':
        # Per-tid CSR address table: out-of-order issue, commit-order lookup,
        # ready as table credit, cancel/flush drop; depth-1 identity in order.
        configurations=[('csrbuf','ooo',['-GOOO=1'],[(n,None) for n in range(4)]),
                        ('csrbuf','inorder',['-GOOO=0'],[(4,None)])]
    elif os.environ.get('REVIEW_RTL_TAGE')=='1':
        # Predictor-context ownership: per-slot tagged provider, update-fold
        # ownership, unaligned base/ITTAGE addressing, banked-GHR train folds.
        configurations=[('tage','s2-c1',[],[(n,None) for n in range(4)]),
                        ('ghist','h2',[],[(0,None)])]
    elif os.environ.get('REVIEW_RTL_CKPT')=='1':
        # Prediction-time checkpoint FIFO: conservation, full push+pop single
        # head advance, restore drains younger wrong-path entries, overflow
        # desync gating, cross-window ordering.
        configurations=[('ckpt','d4',[],[(n,None) for n in range(7)])]
    elif os.environ.get('REVIEW_RTL_SBHEAD')=='1':
        # T6b-2a: per-hart oldest-issued head. The parallel rotate/find-first
        # must reproduce the serial ring-order scan, including across a
        # commit-pointer wrap; hart-1-only traffic leaves hart 0 headless.
        configurations=[('sbhead','nh2',['-GHARTS=2','-GSBDEPTH=16'],[(n,None) for n in range(3)])]
    elif dispatch_mode:
        cases=[(0,None),(1,'DISPATCH_STORE_PROGRESS' if before else None)]
        # Scenarios 6-8 previously pinned the alloc_id_i -> 0 Verilator
        # artefact. The rename admission rework (valid_i ungated from can_go)
        # removed the circular comb settle that produced it: real trans_ids now
        # propagate (scenario 6 retires its store by genuine id match), so 6-8
        # run as real evidence with live negative controls.
        if not before:cases+=[(2,None),(3,None),(6,None),(7,None),(8,None),(9,None),(10,None),(20,None),(21,None),(22,None),(23,None),(28,None),(29,None)]
        if os.environ.get('REVIEW_RTL_RECOVERY')=='1':
            cases=[(20,None),(21,None),(22,None),(23,None)]
        if os.environ.get('REVIEW_RTL_WB_OWNER')=='1':
            cases=[(n,('DISPATCH_WB_VALUE' if n==13 else 'DISPATCH_STALE_WAKE') if before else None)
                   for n in (11,12,13,14)]
        if os.environ.get('REVIEW_RTL_DROP')=='1':
            cases=[(n,('DISPATCH_DROP_ARCH','DISPATCH_DROP_FREE','DISPATCH_DROP_CKPT')[n-15] if before else None)
                   for n in (15,16,17)]
            if drop_fault:cases=[entry for entry in cases if entry[0]=={'map':15,'free':16,'checkpoint':17}[drop_fault]]
        # Late writeback after trans_id reuse: the cancellation mask cannot
        # identify the stale result once the id belongs to a live instruction.
        if os.environ.get('REVIEW_RTL_TIDREUSE')=='1':
            cases=[(18,'DISPATCH_TIDREUSE' if before else None)]
        # Architectural result delivered at commit (CSR read, LR) never reaches the
        # PRF, while a renamed consumer reads the PRF in preference to the regfile.
        if os.environ.get('REVIEW_RTL_LATERESULT')=='1':
            cases=[(19,'DISPATCH_LATERESULT' if before else None)]
        if os.environ.get('REVIEW_RTL_LATE_WAKE')=='1':
            cases=[(28,None),(29,None)]
        configurations=[('dispatch','n2',[],
                         [(10,'DISPATCH_LSQ_CREDIT')] if credit_fault else cases)]
        if fp_dispatch:
            configurations=[('dispatch','fp',['-GFPEN=1'],
                             [(n,'DISPATCH_FP_COMMIT_FLUSH' if fp_commit_fault or (fp_zero_fault and n==27) else None)
                              for n in (24,25,27)])]
        if hart_dispatch:
            configurations=[('dispatch','nh2',['-GHARTS=2'],[(26,None)])]
        # T6a positive counterpart to the illegal cells: integer -GHARTS=2 must
        # elaborate and run the hart scenario plus the standard negative battery.
        if os.environ.get('REVIEW_RTL_LEGAL_SMT')=='1':
            # T6b: + the peer-hart / same-hart unresolved-store ordering cells.
            configurations=[('dispatch','legal-smt',['-GHARTS=2'],
                             [(26,None),(30,None),(31,None)])]
        # MemDepPredEn=1 elaboration/liveness. Feedback is promoted to an error:
        # a settled combinational cycle is not evidence of a working predictor.
        if os.environ.get('REVIEW_RTL_MEMDEP')=='1':
            configurations=[('dispatch','mdp1',['-GMDP=1'],cases)]
        # Elaboration guards: these configurations must FAIL to build. The
        # legality checks in check_cfg are simulation-only, so a build success
        # here would mean an aliasing configuration can be synthesised.
        if os.environ.get('REVIEW_RTL_ILLEGAL'):
            # Distinct name: the configuration loop below rebinds `kind` to the
            # configuration's own kind, which silently selected the wrong
            # expected message.
            illegal_kind=os.environ['REVIEW_RTL_ILLEGAL']
            assert illegal_kind in ('smt','fp')
            # 'smt' is the FP multi-hart guard (gen_err_ooo_fp_mh: integer
            # -GHARTS=2 is legal since T6a); 'fp' is the single-hart FP guard
            # (gen_err_ooo_fp).
            configurations=[('dispatch','illegal-'+illegal_kind,
                             ['-GHARTS=2','-GFPEN=1'] if illegal_kind=='smt' else ['-GFPEN=1'],[])]
    results=[]
    for kind,geometry,parameters,cases in configurations:
        if os.environ.get('REVIEW_RTL_KIND') and kind != os.environ['REVIEW_RTL_KIND']:continue
        work=out/(kind+'-'+geometry);work.mkdir();model=work/'model'
        top='tb_g6lc_review_'+kind
        trace=['--trace','--trace-structs'] if os.environ.get('REVIEW_RTL_TRACE')=='1' else []
        # -O0 discriminates a genuine RTL defect from a simulator optimisation
        # artefact: the RTL is unchanged, only the optimiser is disabled.
        if os.environ.get('REVIEW_RTL_NOOPT')=='1':trace+=['-O0']
        # scoreboard.sv's commit_instr_o SVA samples a wide unpacked-array port
        # at the TB boundary; Verilator 5.008 emits the __Vsampled copy loop
        # before the __Vilp declaration (a use-before-decl codegen bug), so the
        # commit kind runs without --assert. The SVA stays compiled and active
        # under every other flow that builds scoreboard.sv.
        asserts=[] if os.environ.get('REVIEW_RTL_NOASSERT')=='1' else ['--assert']
        strict=[]
        if os.environ.get('REVIEW_RTL_MEMDEP')=='1':strict+=['-Werror-UNOPTFLAT']
        if os.environ.get('REVIEW_RTL_LATCH')=='1':strict+=['-Werror-LATCH']
        command=['verilator','--cc','--main','--exe','--timing',*asserts,'--threads','1','-Wno-fatal',*strict,'-I'+str(source),*trace,'--top-module',top,*parameters,'--Mdir',str(model),'-o','review-test',*rtl]
        if os.environ.get('REVIEW_RTL_ILLEGAL'):
            # -Wno-fatal would demote the elaboration $error to a warning, which
            # is exactly the weakness being tested: the build must be refused.
            strict_cmd=[a for a in command if a!='-Wno-fatal']
            (work/'verilate-command.json').write_text(json.dumps(strict_cmd,indent=2))
            with (work/'verilate.log').open('w') as log:
                p=subprocess.run(strict_cmd,stdout=log,stderr=subprocess.STDOUT,timeout=180)
            text=(work/'verilate.log').read_text(errors='replace')
            # Matched on the guard's own text, so a reworded refusal fails here
            # rather than silently passing on a different guard. The refusals
            # are "FP with more than one hart is unqualified" and "FP class
            # implemented but unqualified".
            expected=('more than one hart is unqualified' if illegal_kind=='smt'
                      else 'implemented but unqualified')
            refused=p.returncode!=0 and expected in text
            results.append({'kind':kind,'geometry':geometry,'scenario':None,
                            'illegalKind':illegal_kind,
                            'negative':False,'expectedError':'elaboration refusal',
                            'rc':p.returncode,'matched':refused,
                            'strictQualification':False})
            (out/'results.json').write_text(json.dumps(results,indent=2))
            assert refused,'illegal configuration elaborated'
            continue
        for label,cmd in [('verilate',command),('build',['make','-C',str(model),'-f','V'+top+'.mk','-j4','VERILATOR_ROOT='+str(runtime)])]:
            (work/(label+'-command.json')).write_text(json.dumps(cmd,indent=2))
            with (work/(label+'.log')).open('w') as log:p=subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT,timeout=180)
            assert p.returncode==0,str(work/(label+'.log'))
        dependencies='\n'.join(p.read_text(errors='replace') for p in model.glob('*.d'))
        assert str(runtime/'include/verilated_funcs.h') in dependencies
        assert str(Path(runtime_info['originalRoot'])/'include/verilated_funcs.h') not in dependencies
        exe=model/'review-test'
        trials=[(scenario,False,error) for scenario,error in cases]
        if not before and not rename_fault and not credit_fault and not flush_fault and not leak_fault and not fp_zero_fault and not fp_commit_fault:
            # The nh2 geometry needs a bigger PRF (31 committed physicals per
            # hart), so the single-hart negatives are not comparable there; it
            # carries its own per-hart discriminators instead.
            if kind=='store_recovery':
                codes=('FLUSH','CANCEL','COMMITTED','REPLAY','YOUNGER_FWD','PROGRAM_ORDER',
                       'HART_PEER_FWD','HART_OWN_FWD')
                trials += [(n,True,'STORE_RECOVERY_'+codes[n]) for n,_ in cases]
            elif kind=='wfi':
                trials += [(n,True,'WFI_RETIRE_RECOVERY') for n in range(7)]
            elif kind=='rename' and os.environ.get('REVIEW_RTL_RENAME_FP_SMT')=='1':
                trials += [(24,True,'RENAME_FP_HART_FLUSH_MAP'),(25,True,'RENAME_FP_HART_FLUSH_MAP')]
            elif kind=='rename' and os.environ.get('REVIEW_RTL_RENAME_FP')=='1':
                trials+=[(20,True,'RENAME_FP_CLASS'),(21,True,'RENAME_FP_F0'),
                         (22,True,'RENAME_FP_RECOVER'),(23,True,'RENAME_FP_RS3')]
            elif kind=='rename' and os.environ.get('REVIEW_RTL_RENAME_SMT')=='1':
                trials+=[(11,True,'RENAME_HART_ALIAS'),(12,True,'RENAME_PEER_SQUASHED'),
                         (13,True,'RENAME_HART_FLUSH_SPILL'),(14,True,'RENAME_HART_REALLOC_FLUSH'),
                         (15,True,'RENAME_HART_REALLOC_FLUSH')]
            elif kind=='rename':trials+=[(0,True,'RENAME_MAP'),(1,True,'RENAME_OLDER_LOST'),(2,True,'RENAME_BUSY_RESURRECT'),(3,True,'RENAME_STALE_LEVEL'),(4,True,'RENAME_CKPT2_UNWIND'),(5,True,'RENAME_CKPT_FULL'),(6,True,'RENAME_EXCLUSIVE'),(7,True,'RENAME_CKPT_NO_RELEASE'),(8,True,'RENAME_RETIRE_WINDOW'),(9,True,'RENAME_FLUSH_ARCH'),(10,True,'RENAME_CKPT_ALLOC_LEAK')]
            elif kind=='lsq':
                trials+=[(0,True,'LSQ_WB_RETIRE'),(1,True,'LSQ_STL_DATA'),(2,True,'LSQ_COMMIT_DOUBLE_FREE'),(3,True,'LSQ_STL_AGE'),(4,True,'LSQ_AGE_STALL'),(5,True,'LSQ_WRAP_DATA'),(6,True,'LSQ_BYTE_DISJOINT'),(7,True,'LSQ_BYTE_COVER'),(8,True,'LSQ_PARTIAL_NODATA'),(9,True,'LSQ_PARTIAL_MERGE'),(10,True,'LSQ_CANCEL_DROP'),(11,True,'LSQ_FLUSH'),(12,True,'LSQ_VIOLATION'),(13,True,'LSQ_VIOLATION_YOUNGER'),(14,True,'LSQ_VIOLATION_WRAP'),(15,True,'LSQ_VIOLATION_OLDEST'),(16,True,'LSQ_VIOLATION_DISJOINT'),(17,True,'LSQ_VIOLATION_SAMECYCLE'),(18,True,'LSQ_UNRESOLVED_MASK')]
                if geometry=='nh2':
                    trials+=[(19,True,'LSQ_HART_PEER_STALL'),(20,True,'LSQ_HART_OWN_STALL'),
                             (21,True,'LSQ_HART_PEER_FWD'),(22,True,'LSQ_HART_PEER_VIOL'),
                             (23,True,'LSQ_HART_OWN_VIOL'),(24,True,'LSQ_HART_MASK')]
            elif dispatch_mode and os.environ.get('REVIEW_RTL_LATE_WAKE')=='1':
                trials += [(n,True,'DISPATCH_LATE_WAKE_EARLY') for n in (28,29)]
            elif dispatch_mode and os.environ.get('REVIEW_RTL_LEGAL_SMT')=='1':
                trials += [(26,True,'DISPATCH_HART_ARCH'),
                           (30,True,'DISPATCH_HART_LOAD_PEER'),
                           (31,True,'DISPATCH_HART_LOAD_OWN')]
            elif dispatch_mode and hart_dispatch:
                trials += [(26,True,'DISPATCH_HART_ARCH')]
            elif dispatch_mode and fp_dispatch:
                trials += [(n,True,'DISPATCH_FP_COMMIT_FLUSH') for n in (24,25,27)]
            elif dispatch_mode:
                trials+=([(n,True,('DISPATCH_DROP_ARCH','DISPATCH_DROP_FREE','DISPATCH_DROP_CKPT')[n-15]) for n in (15,16,17)]
                         if os.environ.get('REVIEW_RTL_DROP')=='1' else
                         [(n,True,'DISPATCH_WB_VALUE') for n in (11,12,13,14)]
                         if os.environ.get('REVIEW_RTL_WB_OWNER')=='1' else
                         [(1,True,'DISPATCH_ID'),(3,True,'DISPATCH_LOAD_ORDER'),(6,True,'DISPATCH_STORE_WB_RETIRE'),(7,True,'DISPATCH_LOAD_UNBLOCKED'),(8,True,'DISPATCH_WRAP_ORDER'),(9,True,'DISPATCH_TAG_REUSE'),(10,True,'DISPATCH_LSQ_CREDIT'),(20,True,'DISPATCH_RECOVERY_ISSUE'),(21,True,'DISPATCH_RECOVERY_WAKE'),(22,True,'DISPATCH_RECOVERY_ISSUE'),(23,True,'DISPATCH_RECOVERY_ISSUE'),(28,True,'DISPATCH_LATE_WAKE_EARLY'),(29,True,'DISPATCH_LATE_WAKE_EARLY')])
            elif kind=='tage':trials+=[(0,True,'TAGE_SLOT_BROADCAST'),(1,True,'TAGE_UPDATE_FOLD'),(2,True,'TAGE_BASE_ALIAS'),(3,True,'ITTAGE_SLOT_ALIAS')]
            elif kind=='ghist':trials+=[(0,True,'GHIST_FOLD_TRAIN')]
            elif kind=='ckpt':trials+=[(0,True,'CKPT_MULTI'),(1,True,'CKPT_DOUBLE_ADV'),(3,True,'CKPT_DESYNC_RV'),(5,True,'CKPT_DROPPED_OWNER'),(6,True,'CKPT_EMPTY_RESTORE_HEAD')]
            elif kind=='csrbuf':
                trials+=[(n,True,('CSRBUF_ADDR','CSRBUF_READY','CSRBUF_CANCEL','CSRBUF_FLUSH','CSRBUF_INORDER')[n]) for n,_ in cases]
            elif kind=='sbhead':
                trials+=[(0,True,'SBHEAD_ORDER'),(1,True,'SBHEAD_WRAP'),(2,True,'SBHEAD_HOLE')]
            else:
                trials.append((0,True,{'iq':'IQ_ISSUE','mshr':'MSHR_ADMISSION','decay':'TAGE_DECAY','incl':'L3_PAYLOAD','commit':'COMMIT4_TID'}[kind]))
                if kind=='iq':trials+=[(5,True,'IQ_UNRESOLVED_GATE'),(6,True,'IQ_BYPASS'),(7,True,'IQ_RESOLVED_PASS'),(8,True,'IQ_STORE_OOO'),(9,True,'IQ_CSR_HEAD')]
                if kind=='incl':trials+=[(1,True,'L3_EVICT_NO_BACKPRESSURE'),(2,True,'L3_EVICT_LOST_B')]
        for scenario,negative,error in trials:
            cmd=[str(exe),f'+scenario={scenario}']+(['+oracle_negative'] if negative else [])+(['+vcd'] if os.environ.get('REVIEW_RTL_TRACE')=='1' else [])
            if os.environ.get('REVIEW_RTL_WB_TRACE')=='1':cmd+=['+owner_trace']
            if os.environ.get('REVIEW_RTL_DUAL_COMMIT')=='1':cmd+=['+dual_commit']
            p=subprocess.run(cmd,cwd=work,capture_output=True,text=True,timeout=30)
            text=p.stdout+p.stderr;(work/f'case-{scenario}-negative-{int(negative)}.log').write_text(text)
            matched=(p.returncode!=0 and error in text and 'RTL_REVIEW_PASS' not in text) if error else p.returncode==0 and text.count('RTL_REVIEW_PASS')==1 and '%Error' not in text
            results.append({'kind':kind,'geometry':geometry,'scenario':scenario,'negative':negative,'expectedError':error,'rc':p.returncode,'matched':matched,'executableSha256':digest(exe),'strictQualification':False})
            (out/'results.json').write_text(json.dumps(results,indent=2))
            assert matched,(kind,geometry,scenario)
    assert all(digest(source/name)==value for name,value in hashes.items())
    return 0


if __name__=='__main__':sys.exit(main())
