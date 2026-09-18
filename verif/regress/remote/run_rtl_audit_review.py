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
    before=os.environ.get('REVIEW_RTL_BEFORE')=='1'
    source=out/'source';source.mkdir()
    names=['config_pkg.sv','g6lc64_smt2_config_pkg.sv','riscv_pkg.sv','ariane_pkg.sv','g6lc_iq.sv','g6lc_bp_tage_table.sv','g6lc_bp_tage.sv','g6lc_bp_ghist.sv','g6lc_bp_ckpt.sv','g6lc_bp_ittage.sv','g6lc_l2_mshr.sv','g6lc_coherence_pkg.sv','g6lc_l3_inclusive_inv.sv','g6lc_cluster.sv','g6lc_core_types.svh','tb_g6lc_rtl_review.sv']
    # scoreboard.sv (and its smt_legacy/fetch_A helper packages) are only
    # needed by the commit kind; every other kind leaves that bench module
    # unelaborated, so the legacy files stay out of the payload.
    if os.environ.get('REVIEW_RTL_COMMIT')=='1':
        names[-1:-1]=['g6lc_sb_keep.sv','g6lc_rvc_enc.sv','g6lc_fe_keep.sv','g6lc_jalr_usable.sv','g6lc_sib_cjalr.sv','scoreboard.sv']
    dispatch_mode=os.environ.get('REVIEW_RTL_DISPATCH')=='1' or os.environ.get('REVIEW_RTL_LSQ')=='1' or os.environ.get('REVIEW_RTL_RENAME')=='1'
    if dispatch_mode:
        names[4:4]=['g6lc_ooo_pkg.sv']
        names+=['g6lc_rename.sv','g6lc_rob.sv','g6lc_lsq.sv','g6lc_prf.sv','g6lc_memdep.sv','g6lc_ooo_dispatch.sv']
    for name in names:shutil.copy2(data/name,source/name)
    # Fault control for the checkpoint-retirement repair: with retirement
    # disabled the pool behaves as it did before the fix, so the new scenario
    # has to fail. Anything else means the scenario is not the discriminator.
    # Same shape for the LSQ group-credit repair: restoring the any-free-entry
    # admission term must make the group-credit scenario fail.
    credit_fault=os.environ.get('REVIEW_RTL_CREDIT_FAULT')=='1'
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
        old='      n_ret = $countones(ckpt_retire_i);'
        assert text.count(old)==1,'rename fault injection site changed'
        path.write_text(text.replace(old,'      n_ret = 0;'))
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
        cases=[(0,None),(1,'IQ_VALID'),(2,'IQ_ISSUE'),(3,'IQ_CREDIT')] if before else [(n,None) for n in range(5)]
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
    if os.environ.get('REVIEW_RTL_COMMIT')=='1':
        configurations=[('commit','p4',['-GNPC=4'],[(0,None),(1,None)])]
    elif os.environ.get('REVIEW_RTL_RENAME')=='1':
        configurations=[('rename','direct',[],
                         [(7,'RENAME_CKPT_NO_RELEASE')] if rename_fault
                         else [(n,None) for n in range(9)])]
    elif os.environ.get('REVIEW_RTL_LSQ')=='1':
        configurations=[('lsq','direct',[],[(n,None) for n in range(12)])]
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
    elif dispatch_mode:
        cases=[(0,None),(1,'DISPATCH_STORE_PROGRESS' if before else None)]
        # Scenarios 6-8 previously pinned the alloc_id_i -> 0 Verilator
        # artefact. The rename admission rework (valid_i ungated from can_go)
        # removed the circular comb settle that produced it: real trans_ids now
        # propagate (scenario 6 retires its store by genuine id match), so 6-8
        # run as real evidence with live negative controls.
        if not before:cases+=[(2,None),(3,None),(6,None),(7,None),(8,None),(9,None),(10,None)]
        configurations=[('dispatch','n2',[],
                         [(10,'DISPATCH_LSQ_CREDIT')] if credit_fault else cases)]
        # MemDepPredEn=1 elaboration/liveness. Feedback is promoted to an error:
        # a settled combinational cycle is not evidence of a working predictor.
        if os.environ.get('REVIEW_RTL_MEMDEP')=='1':
            configurations=[('dispatch','mdp1',['-GMDP=1'],cases)]
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
        for label,cmd in [('verilate',command),('build',['make','-C',str(model),'-f','V'+top+'.mk','-j4','VERILATOR_ROOT='+str(runtime)])]:
            (work/(label+'-command.json')).write_text(json.dumps(cmd,indent=2))
            with (work/(label+'.log')).open('w') as log:p=subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT,timeout=180)
            assert p.returncode==0,str(work/(label+'.log'))
        dependencies='\n'.join(p.read_text(errors='replace') for p in model.glob('*.d'))
        assert str(runtime/'include/verilated_funcs.h') in dependencies
        assert str(Path(runtime_info['originalRoot'])/'include/verilated_funcs.h') not in dependencies
        exe=model/'review-test'
        trials=[(scenario,False,error) for scenario,error in cases]
        if not before and not rename_fault and not credit_fault:
            if kind=='rename':trials+=[(0,True,'RENAME_MAP'),(1,True,'RENAME_OLDER_LOST'),(2,True,'RENAME_BUSY_RESURRECT'),(3,True,'RENAME_STALE_LEVEL'),(4,True,'RENAME_CKPT2_UNWIND'),(5,True,'RENAME_CKPT_FULL'),(6,True,'RENAME_EXCLUSIVE'),(7,True,'RENAME_CKPT_NO_RELEASE'),(8,True,'RENAME_RETIRE_WINDOW')]
            elif kind=='lsq':trials+=[(0,True,'LSQ_WB_RETIRE'),(1,True,'LSQ_STL_DATA'),(2,True,'LSQ_COMMIT_DOUBLE_FREE'),(3,True,'LSQ_STL_AGE'),(4,True,'LSQ_AGE_STALL'),(5,True,'LSQ_WRAP_DATA'),(6,True,'LSQ_BYTE_DISJOINT'),(7,True,'LSQ_BYTE_COVER'),(8,True,'LSQ_PARTIAL_NODATA'),(9,True,'LSQ_PARTIAL_MERGE'),(10,True,'LSQ_CANCEL_DROP'),(11,True,'LSQ_FLUSH')]
            elif dispatch_mode:trials+=[(1,True,'DISPATCH_ID'),(3,True,'DISPATCH_LOAD_ORDER'),(6,True,'DISPATCH_STORE_WB_RETIRE'),(7,True,'DISPATCH_LOAD_UNBLOCKED'),(8,True,'DISPATCH_WRAP_ORDER'),(9,True,'DISPATCH_TAG_REUSE'),(10,True,'DISPATCH_LSQ_CREDIT')]
            elif kind=='tage':trials+=[(0,True,'TAGE_SLOT_BROADCAST'),(1,True,'TAGE_UPDATE_FOLD'),(2,True,'TAGE_BASE_ALIAS'),(3,True,'ITTAGE_SLOT_ALIAS')]
            elif kind=='ghist':trials+=[(0,True,'GHIST_FOLD_TRAIN')]
            elif kind=='ckpt':trials+=[(0,True,'CKPT_MULTI'),(1,True,'CKPT_DOUBLE_ADV'),(3,True,'CKPT_DESYNC_RV'),(5,True,'CKPT_DROPPED_OWNER'),(6,True,'CKPT_EMPTY_RESTORE_HEAD')]
            else:
                trials.append((0,True,{'iq':'IQ_ISSUE','mshr':'MSHR_ADMISSION','decay':'TAGE_DECAY','incl':'L3_PAYLOAD','commit':'COMMIT4_TID'}[kind]))
                if kind=='incl':trials+=[(1,True,'L3_EVICT_NO_BACKPRESSURE'),(2,True,'L3_EVICT_LOST_B')]
        for scenario,negative,error in trials:
            cmd=[str(exe),f'+scenario={scenario}']+(['+oracle_negative'] if negative else [])+(['+vcd'] if os.environ.get('REVIEW_RTL_TRACE')=='1' else [])
            p=subprocess.run(cmd,cwd=work,capture_output=True,text=True,timeout=30)
            text=p.stdout+p.stderr;(work/f'case-{scenario}-negative-{int(negative)}.log').write_text(text)
            matched=(p.returncode!=0 and error in text and 'RTL_REVIEW_PASS' not in text) if error else p.returncode==0 and text.count('RTL_REVIEW_PASS')==1 and '%Error' not in text
            results.append({'kind':kind,'geometry':geometry,'scenario':scenario,'negative':negative,'expectedError':error,'rc':p.returncode,'matched':matched,'executableSha256':digest(exe),'strictQualification':False})
            (out/'results.json').write_text(json.dumps(results,indent=2))
            assert matched,(kind,geometry,scenario)
    assert all(digest(source/name)==value for name,value in hashes.items())
    return 0


if __name__=='__main__':sys.exit(main())
