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
  logic clk=0,rst_n=0,evict=0;
  logic [NC-1:0] inv_core_ready='0,inv_incl_ready;
  coh_inval_t [NC-1:0] inv_hub='0,inv_incl,inv_to_core;
  int delivered[NC];
  bit negative;
  @MUX@
  g6lc_l3_inclusive_inv #(.InclusiveEn(1),.NR_CORES(NC)) dut(
    .clk_i(clk),.rst_ni(rst_n),.evict_valid_i(evict),.evict_addr_i(64'h4000),
    .inv_ready_i(@READY@),.inv_o(inv_incl),.inv_busy_o());
  task automatic tick;clk=1;#2;clk=0;#2;endtask
  initial begin
    negative=$test$plusargs("oracle_negative");#2;tick();rst_n=1;evict=1;#2;tick();evict=0;
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
    $display("RTL_REVIEW_PASS incl");$finish;
  end
endmodule
'''


def main():
    data=Path(os.environ['TH_DATA_DIR']);out=Path(os.environ['TH_OUT_DIR'])
    before=os.environ.get('REVIEW_RTL_BEFORE')=='1'
    source=out/'source';source.mkdir()
    names=['config_pkg.sv','g6lc64_smt2_config_pkg.sv','riscv_pkg.sv','ariane_pkg.sv','g6lc_iq.sv','g6lc_bp_tage_table.sv','g6lc_bp_tage.sv','g6lc_l2_mshr.sv','g6lc_coherence_pkg.sv','g6lc_l3_inclusive_inv.sv','g6lc_cluster.sv','tb_g6lc_rtl_review.sv']
    dispatch_mode=os.environ.get('REVIEW_RTL_DISPATCH')=='1' or os.environ.get('REVIEW_RTL_LSQ')=='1'
    if dispatch_mode:
        names[4:4]=['g6lc_ooo_pkg.sv']
        names+=['g6lc_rename.sv','g6lc_rob.sv','g6lc_lsq.sv','g6lc_prf.sv','g6lc_memdep.sv','g6lc_ooo_dispatch.sv']
    for name in names:shutil.copy2(data/name,source/name)
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
    rtl=[str(source/name) for name in names if name!='g6lc_cluster.sv']+[str(source/'incl.sv')]
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
        configurations.append(('incl',f'n{nc}',[f'-GNC={nc}'],[(0,'L3_SOURCE_ACK' if before else None)]))
    if os.environ.get('REVIEW_RTL_LSQ')=='1':
        configurations=[('lsq','direct',[],[(0,None),(1,None)])]
    elif dispatch_mode:
        cases=[(0,None),(1,'DISPATCH_STORE_PROGRESS' if before else None)]
        # scenario 6 is a known-red reproducer: a store's writeback does not
        # retire its LSQ entry. Expect the failure until that is repaired.
        if not before:cases+=[(2,None),(3,None),(6,'DISPATCH_STORE_WB_RETIRE')]
        configurations=[('dispatch','n2',[],cases)]
    results=[]
    for kind,geometry,parameters,cases in configurations:
        if os.environ.get('REVIEW_RTL_KIND') and kind != os.environ['REVIEW_RTL_KIND']:continue
        work=out/(kind+'-'+geometry);work.mkdir();model=work/'model'
        top='tb_g6lc_review_'+kind
        command=['verilator','--cc','--main','--exe','--timing','--assert','--threads','1','-Wno-fatal','--top-module',top,*parameters,'--Mdir',str(model),'-o','review-test',*rtl]
        for label,cmd in [('verilate',command),('build',['make','-C',str(model),'-f','V'+top+'.mk','-j4','VERILATOR_ROOT='+str(runtime)])]:
            (work/(label+'-command.json')).write_text(json.dumps(cmd,indent=2))
            with (work/(label+'.log')).open('w') as log:p=subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT,timeout=180)
            assert p.returncode==0,str(work/(label+'.log'))
        dependencies='\n'.join(p.read_text(errors='replace') for p in model.glob('*.d'))
        assert str(runtime/'include/verilated_funcs.h') in dependencies
        assert str(Path(runtime_info['originalRoot'])/'include/verilated_funcs.h') not in dependencies
        exe=model/'review-test'
        trials=[(scenario,False,error) for scenario,error in cases]
        if not before:
            if kind=='lsq':trials+=[(0,True,'LSQ_WB_RETIRE'),(1,True,'LSQ_STL_DATA')]
            elif dispatch_mode:trials+=[(1,True,'DISPATCH_ID'),(3,True,'DISPATCH_LOAD_ORDER')]
            else:trials.append((0,True,{'iq':'IQ_ISSUE','mshr':'MSHR_ADMISSION','decay':'TAGE_DECAY','incl':'L3_PAYLOAD'}[kind]))
        for scenario,negative,error in trials:
            cmd=[str(exe),f'+scenario={scenario}']+(['+oracle_negative'] if negative else [])
            p=subprocess.run(cmd,cwd=work,capture_output=True,text=True,timeout=30)
            text=p.stdout+p.stderr;(work/f'case-{scenario}-negative-{int(negative)}.log').write_text(text)
            matched=(p.returncode!=0 and error in text and 'RTL_REVIEW_PASS' not in text) if error else p.returncode==0 and text.count('RTL_REVIEW_PASS')==1 and '%Error' not in text
            results.append({'kind':kind,'geometry':geometry,'scenario':scenario,'negative':negative,'expectedError':error,'rc':p.returncode,'matched':matched,'executableSha256':digest(exe),'strictQualification':False})
            (out/'results.json').write_text(json.dumps(results,indent=2))
            assert matched,(kind,geometry,scenario)
    assert all(digest(source/name)==value for name,value in hashes.items())
    return 0


if __name__=='__main__':sys.exit(main())
