#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
import contextlib
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


OCCUPANCY = r'''
// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
module l2_occupancy
  import g6lc_l2_tb_pkg::*;
#(parameter int DEPTH=16, BYTES=512, WAYS=2, BANKS=2)(input logic clk_i, input req_t request,
  input resp_t memory_response, input logic invalidate, input addr_t invalidate_addr,
  output logic seen_live=0, seen_done=0);
  logic initial_reset=1;
  wire rst_n = !initial_reset;
  always_ff @(posedge clk_i) initial_reset <= 0;
  g6lc_l2_top #(.BYTE_SIZE(BYTES),.SET_ASSOC(WAYS),.LINE_WIDTH(512),
    .MSHR_DEPTH(DEPTH),.DATA_BANKS(BANKS),.RR_EN(0),.axi_req_t(req_t),.axi_resp_t(resp_t)) dut (
    .clk_i,.rst_ni(rst_n),.slv_req_i(request),.slv_resp_o(),.mst_req_o(),.mst_resp_i(memory_response),
    .l2_hit_o(),.l2_miss_o(),.l2_bypass_o(),.l2_mshr_full_o(),.l2_bank_conflict_o(),
    .l2_selfinv_hit_o(),
    .l2_evict_valid_o(),.l2_evict_addr_o(),.l2_evict_ready_i(1'b1),
    .l2_back_inval_valid_i(invalidate),
    .l2_back_inval_addr_i(invalidate_addr),.l2_back_inval_ready_o()
  );
  logic miss_active;
  assign miss_active = dut.gen_l2.state_q inside {4'd4, 4'd5, 4'd6};
  always_ff @(posedge clk_i) if (rst_n) begin
    assert (int'(dut.gen_l2.i_mshr.count_o) == int'(miss_active));
    assert (dut.gen_l2.i_mshr.mem_q[0].valid == miss_active);
    assert (dut.gen_l2.mshr_idx_q == 0);
    for (int i=0; i<DEPTH; i++) begin
      assert (dut.gen_l2.i_mshr.mem_q[i].nwait == 0);
      if (i != 0) assert (!dut.gen_l2.i_mshr.mem_q[i].valid);
    end
    if (dut.gen_l2.mshr_alloc) begin
      assert (!miss_active && dut.gen_l2.mshr_ready && !dut.gen_l2.mshr_merged);
      assert (dut.gen_l2.mshr_alloc_idx == 0);
    end
    if (dut.gen_l2.mshr_complete) begin
      assert (miss_active && dut.gen_l2.mshr_complete_idx == 0);
      seen_done <= 1;
    end
    if (miss_active) seen_live <= 1;
  end
endmodule
'''


def occupancy_proof(data, out):
    rtl_text = (data/'g6lc_l2_top.sv').read_text()
    states = re.search(r'typedef enum logic \[3:0\] \{(.*?)\} state_e;', rtl_text, re.S)
    assert states and [s.strip() for s in states[1].split(',')] == ['S_IDLE','S_TAG','S_HIT_WAIT','S_HIT_RESP','S_MISS_AR','S_MISS_R','S_MISS_INSTALL','S_BYPASS_AR','S_BYPASS_R','S_BYPASS_AW','S_BYPASS_W','S_BYPASS_B'], 'state encoding changed'
    work = out / 'proof'
    work.mkdir()
    types = re.findall(r'package g6lc_l2_tb_pkg;.*?endpackage', (data/'tb_g6lc_l2.sv').read_text(),re.S)
    assert len(types)==1
    type_file=work/'types.sv'
    type_file.write_text('// Copyright (c) 2026 Etienne Cimon\n// SPDX-License-Identifier: MIT\n'+types[0]+'\n')
    names=['axi_pkg.sv','tc_sram.sv','g6lc_l2_pkg.sv','g6lc_l2_tag.sv','g6lc_l2_data.sv','g6lc_l2_mshr.sv','g6lc_l2_top.sv']
    common=' '.join(str(data/name) for name in names)+' '+str(type_file)
    results=[]
    production = os.environ.get('REVIEW_L2_SIZE_PRODUCTION') == '1'
    template = OCCUPANCY.replace('BYTES=512, WAYS=2, BANKS=2', 'BYTES=262144, WAYS=8, BANKS=4') if production else OCCUPANCY
    cutpoints = ('select -assert-count 1 w:dut.gen_l2.tag_hit\nselect -assert-count 1 w:dut.gen_l2.bank_conflict\ncutpoint w:dut.gen_l2.tag_hit w:dut.gen_l2.bank_conflict\nopt_clean -purge\n') if production else ''
    for depth in ([16,8,2] if production else [16,2]):
        harness=work/f'occupancy-{depth}.sv'
        harness.write_text(template.replace('DEPTH=16',f'DEPTH={depth}'))
        script=f'read_slang --std 1800-2017 --unroll-limit=16384 --top l2_occupancy -DSYNTHESIS {common} {harness}\n{cutpoints}prep -top l2_occupancy\nasync2sync\nchformal -lower\nflatten\nmemory_map\nopt -full\ndffunmap\nopt_clean -purge\nwrite_rtlil depth{depth}.il\nsat -seq 4 -prove-asserts -verify\nsat -seq 1 -tempinduct -maxsteps 4 -prove-asserts -verify\n'
        path=work/f'depth{depth}.ys'
        path.write_text(script)
        with (work/f'depth{depth}.log').open('w') as log:
            p=subprocess.run(['yosys','-s',str(path)],cwd=work,stdout=log,stderr=subprocess.STDOUT,timeout=180)
        text=(work/f'depth{depth}.log').read_text()
        matched=p.returncode==0 and 'Induction step proven' in text
        results.append({'depth':depth,'productionGeometry':production,'unconstrainedCacheControlCutpoints':production,'rc':p.returncode,'inductionPassed':matched})
        (out/'proof.json').write_text(json.dumps(results,indent=2))
        assert matched, str(work/f'depth{depth}.log')
    negative = work/'negative.sv'
    negative.write_text(template.replace('assert (dut.gen_l2.mshr_alloc_idx == 0)', 'assert (dut.gen_l2.mshr_alloc_idx == 1)'))
    script=f'read_slang --std 1800-2017 --unroll-limit=16384 --top l2_occupancy -DSYNTHESIS {common} {negative}\n{cutpoints}prep -top l2_occupancy\nasync2sync\nchformal -lower\nflatten\nmemory_map\nopt -full\ndffunmap\nopt_clean -purge\nsat -seq 4 -prove-asserts -dump_vcd negative.vcd -verify\n'
    (work/'negative.ys').write_text(script)
    with (work/'negative.log').open('w') as log:
        p=subprocess.run(['yosys','-s',str(work/'negative.ys')],cwd=work,stdout=log,stderr=subprocess.STDOUT,timeout=180)
    text=(work/'negative.log').read_text()
    assert p.returncode!=0 and 'model found: FAIL!' in text and 'proof did fail' in text
    results.append({'negativeDetected':True})
    (out/'proof.json').write_text(json.dumps(results,indent=2))
    for goal in ['seen_live','seen_done']:
        path=work/(goal+'.ys')
        path.write_text(f'read_rtlil depth16.il\nchformal -assert -remove\nsat -seq 16 -prove {goal} 0 -prove-skip 15 -dump_vcd {goal}.vcd -verify\n')
        with (work/(goal+'.log')).open('w') as log:
            p=subprocess.run(['yosys','-s',str(path)],cwd=work,stdout=log,stderr=subprocess.STDOUT,timeout=180)
        text=(work/(goal+'.log')).read_text()
        assert p.returncode!=0 and 'model found: FAIL!' in text and 'proof did fail' in text
        results.append({'goal':goal,'reached':True,'depth':16})
        (out/'proof.json').write_text(json.dumps(results,indent=2))
    (out/'sources.json').write_text(json.dumps({name:digest(data/name) for name in names},indent=2))
    return 0


def assess_saved(root, out):
    out.mkdir(exist_ok=True)
    rows=json.loads((root/'results.json').read_text())
    areas=json.loads((root/'area.json').read_text())
    assert len(rows)==32 and all(r['matched'] for r in rows)
    cases=[]
    for latency,stalls in [(6,0),(24,3)]:
        selected=[r for r in rows if r['latency']==latency and r['stalls']==stalls and r['role']=='on']
        assert {r['depth'] for r in selected}=={16,8,4,2}
        assert all(r['normalized']==selected[0]['normalized'] and r['portsSha256']==selected[0]['portsSha256'] for r in selected)
        totals=next(line for line in selected[0]['normalized'] if line.startswith('[L2TB] totals '))
        totals={k:int(v) for k,v in (part.split('=',1) for part in totals.split()[2:])}
        cases.append({'latency':latency,'stalls':stalls,'depthsMatched':[16,8,4,2],'totals':totals,'occupancy':selected[0]['occupancy'],'portsSha256':selected[0]['portsSha256']})
    summaries=[]
    for bytes_,macro in [(512,False),(4096,True)]:
        selected=[r for r in areas if r['bytes']==bytes_ and r['dataMacro']==macro]
        base=next(r for r in selected if r['depth']==16)
        base_logic=base['cells']-base['cellTypes'].get('$scopeinfo',0)-base['macroCells']
        for r in selected:
            logic=r['cells']-r['cellTypes'].get('$scopeinfo',0)-r['macroCells']
            summaries.append({'bytes':bytes_,'ways':r['ways'],'depth':r['depth'],'dataMacro':macro,'logicCells':logic,'rawYosysCells':r['cells'],'scopeMetadataCells':r['cellTypes'].get('$scopeinfo',0),'fixedMacroCells':r['macroCells'],'sequentialCells':r['sequentialCells'],'logicSavedFrom16':base_logic-logic,'logicReductionPercentFrom16':100*(base_logic-logic)/base_logic,'stateSavedFrom16':base['sequentialCells']-r['sequentialCells']})
    report={'inputResultsSha256':digest(root/'results.json'),'inputAreaSha256':digest(root/'area.json'),'cases':cases,'area':summaries,'physicalArea':None,'productionPromotion':False,'assessment':'Depth2 is an area candidate with identical measured service, not a speedup. Matched named-package integration/production-geometry and physical qualification remain separate.'}
    (out/'assessment.json').write_text(json.dumps(report,indent=2))
    return 0


@contextlib.contextmanager
def local_environment(values):
    previous={key:os.environ.get(key) for key in values}
    os.environ.update(values)
    try:
        yield
    finally:
        for key,value in previous.items():
            if value is None: os.environ.pop(key,None)
            else: os.environ[key]=value


def integration_review(data, out):
    root=Path(os.environ['TH_RUN_DIR'])
    modules={}
    for name in ['run_restart_review','run_checked_work_review']:
        spec=importlib.util.spec_from_file_location(name,data/(name+'.py'))
        module=importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        modules[name]=module
    restart=modules['run_restart_review']
    checked=modules['run_checked_work_review']
    suffixes={'.sv','.svh','.v','.vh','.h','.hpp','.c','.cpp','.mk','.sh','.py','.tcl','.ld','.S','.f','.bin'}
    def closure(repo):
        return {str(p.relative_to(repo)):digest(p) for p in repo.rglob('*') if p.is_file() and '.git' not in p.relative_to(repo).parts and (p.suffix in suffixes or p.name=='Makefile' or p.name.startswith('Flist'))}
    comparisons=[]
    models=[]
    for target, baseline in [('g6lc64_smt2',16),('g6lc64_stream8',8)]:
        pair=[]
        for depth in [baseline,2]:
            leg=root/f'{target}-depth{depth}'
            leg.mkdir()
            result=leg/'output'
            result.mkdir()
            if target=='g6lc64_smt2':
                with local_environment({'TH_RUN_DIR':str(leg),'TH_OUT_DIR':str(result),'REVIEW_PREDICTOR_INTEGRATION':'1','REVIEW_L2_SMT_DEPTH':str(depth)}):
                    restart.iq_ring_review()
            else:
                prior=Path('/opt/testharness/runs/review-predictor-absolute-sc-20260916/output')
                identity=json.loads((prior/'model.json').read_text())
                sources=json.loads((prior/'sources.json').read_text())
                repo=leg/'repo'
                shutil.copytree(Path(identity['sourceRoot']),repo)
                for name,value in sources.items(): assert digest(repo/name)==value, name
                info=restart.apply_l2_size_overlay(repo,data,target,depth)
                core=repo/'core/cva6.sv'
                text=core.read_text()
                old=str(Path(identity['sourceRoot'])/'verif/tb/core/g6lc_operand_trace.svh')
                assert text.count(old)==1
                core.write_text(text.replace(old,str(repo/'verif/tb/core/g6lc_operand_trace.svh')))
                builder=repo/'verif/regress/soft-ladder-build-harness.sh'
                text=builder.read_text()
                if 'VLT_WRAP=/tmp/soft-ladder-vlt-wrap' in text:
                    assert text.count('VLT_WRAP=/tmp/soft-ladder-vlt-wrap')==1
                    builder.write_text(text.replace('VLT_WRAP=/tmp/soft-ladder-vlt-wrap','VLT_WRAP="$VERLIB_DIR/tool-wrap"'))
                else: assert 'VLT_WRAP="$VERLIB_DIR/tool-wrap"' in text
                runtime_info=identity['runtime']
                runtime=Path(runtime_info['privateRoot'])
                assert digest(runtime/'include/verilated_funcs.h')=='dfbc2c4aa3c1065d4465027c893c9677de10da4cfe7fb152e485eb32b8125166'
                closed=closure(repo)
                model=leg/'model'
                command=['bash','-c','. /opt/testharness/env.sh; export VERILATOR_ROOT="$3" CVA6_REPO_DIR="$1" SOFT_LADDER_VERLIB="$2" SOFT_LADDER_VERILATOR_THREADS=1 SOFT_LADDER_BUILD_TARGET=g6lc64_stream8 SOFT_LADDER_BUILD_JOBS=4; bash verif/regress/soft-ladder-build-harness.sh B','l2-size',str(repo),str(model),str(runtime)]
                with (result/'build.log').open('w') as log:
                    p=subprocess.run(command,cwd=repo,stdout=log,stderr=subprocess.STDOUT,timeout=900)
                assert p.returncode==0 and closure(repo)==closed, 'stream build/source identity'
                dependencies='\n'.join(p.read_text(errors='replace') for p in model.glob('*.d'))
                assert str(runtime/'include/verilated_funcs.h') in dependencies
                assert str(Path(runtime_info['originalRoot'])/'include/verilated_funcs.h') not in dependencies
                exe=model/'Variane_testharness'
                identity={'exe':str(exe),'sha256':digest(exe),'sourceRoot':str(repo),'runtime':runtime_info,'l2Size':info,'predictorCandidate':True,'absoluteCorrector':True,'build':command,'strictQualification':False}
                (result/'model.json').write_text(json.dumps(identity,indent=2))
                (result/'sources.json').write_text(json.dumps(closed,indent=2))
                workload=result/'workloads'
                workload.mkdir()
                with local_environment({'TH_OUT_DIR':str(workload),'REVIEW_PREDICTOR_WORK':'1','REVIEW_L2_STREAM_MODEL':str(result/'model.json')}):
                    assert checked.cacheability_work_review()==0
            identity=json.loads((result/'model.json').read_text())
            repo=Path(identity['sourceRoot'])
            for name in ['config_pkg.sv','build_config_pkg.sv']:
                assert digest(repo/'core/include'/name)==digest(data/name), name
            for name in ['g6lc_l2_top.sv','g6lc_l2_tag.sv','g6lc_l2_data.sv','g6lc_l2_mshr.sv']:
                assert digest(repo/'corev_apu/l2_cache'/name)==digest(data/name), name
            records_path=result/'results.json' if target=='g6lc64_smt2' else result/'workloads/results.json'
            records=json.loads(records_path.read_text())
            assert len(records)==(13 if target=='g6lc64_smt2' else 11)
            for record in records:
                assert record.get('status')=='pass' or record.get('negativeControl') and record.get('matchedExpected'), record
            pair.append({'depth':depth,'result':result,'repo':repo,'model':identity,'records':records,'sources':json.loads((result/'sources.json').read_text())})
            models.append({'target':target,'depth':depth,'model':identity,'records':str(records_path)})
            (out/'models.json').write_text(json.dumps(models,indent=2))
        before,after=pair
        assert before['sources'].keys()==after['sources'].keys()
        different=[name for name in before['sources'] if before['sources'][name]!=after['sources'][name]]
        allowed={'core/cva6.sv','corev_apu/src/g6lc_cluster.sv',f'core/include/{target}_config_pkg.sv'}
        assert set(different)<=allowed, different
        for name in different:
            normalized=[]
            for leg in pair:
                text=(leg['repo']/name).read_text().replace(str(leg['repo']),'<ROOT>')
                info=leg['model']['l2Size']
                text=text.replace(f"L2MshrDepth: unsigned'({info['declaredDepth']})",'L2MshrDepth: <DEPTH>')
                text=text.replace(f"G6lcSizeExpected = {info['effectiveDepth']};",'G6lcSizeExpected = <DEPTH>;')
                normalized.append(text)
            assert normalized[0]==normalized[1], ('unexpected source delta',name)
        key=(lambda r:r['tag']) if target=='g6lc64_smt2' else (lambda r:(r['payload'],r['trial']))
        before_records={key(r):r for r in before['records']}
        after_records={key(r):r for r in after['records']}
        assert before_records.keys()==after_records.keys()
        for name,a in before_records.items():
            b=after_records[name]
            for field in ['status','rc','cookie','retirement','elfSha256']:
                assert a[field]==b[field], (target,name,field)
            if target=='g6lc64_stream8': assert a['report']==b['report'],(target,name,'ROI report')
            else: assert a['traceSha256']==b['traceSha256'],(target,name,'operand trace')
        if target=='g6lc64_smt2':
            assert json.loads((before['result']/'analysis.json').read_text())==json.loads((after['result']/'analysis.json').read_text())
        comparisons.append({'target':target,'depths':[baseline,2],'allChecksAndTimingMatched':True,'sourceDelta':different,'baselineModelSha256':before['model']['sha256'],'candidateModelSha256':after['model']['sha256'],'productionDefaultsChanged':False,'strictQualification':False})
        (out/'comparisons.json').write_text(json.dumps(comparisons,indent=2))
    return 0


def production_area_review(saved, out):
    rows=json.loads((saved/'results.json').read_text())
    assert len(rows)==12 and all(r['matched'] for r in rows)
    positive=[r for r in rows if r['role']=='on']
    assert {r['depth'] for r in positive}=={16,8,2}
    assert all(r['bytes']==262144 and r['ways']==8 and r['banks']==4 for r in positive)
    assert all(r['normalized']==positive[0]['normalized'] and r['portsSha256']==positive[0]['portsSha256'] for r in positive)
    hashes=json.loads((saved/'sources.json').read_text())
    source=out/'source'
    source.mkdir()
    for name,value in hashes.items():
        assert digest(saved/'source'/name)==value
        shutil.copy2(saved/'source'/name,source/name)
    rtl=' '.join(str(source/name) for name in hashes if name.endswith('.sv'))
    areas=[]
    for depth in [16,8,2]:
        work=out/f'depth{depth}'
        work.mkdir()
        script=f'read_slang {rtl} -DL2TB_STATIC -DL2TB_SYNTH --keep-hierarchy --unroll-limit=16384 --top g6lc_l2_fixture -GBYTE_SIZE=262144 -GSET_ASSOC=8 -GMSHR_DEPTH={depth} -GDATA_BANKS=4\nblackbox tc_sram*\nblackbox g6lc_l2_tag*\nsynth -top g6lc_l2_fixture -flatten\ncheck -assert\nselect -assert-none t:$dlatch t:$_DLATCH_*\ntee -o stats.json stat -json\n'
        (work/'synth.ys').write_text(script)
        with (work/'synth.log').open('w') as log:
            p=subprocess.run(['yosys','-s',str(work/'synth.ys')],cwd=work,stdout=log,stderr=subprocess.STDOUT,timeout=180)
        assert p.returncode==0, str(work/'synth.log')
        stats=json.loads((work/'stats.json').read_text())['modules']['\\g6lc_l2_fixture']
        types=stats['num_cells_by_type']
        data_macros=sum(n for t,n in types.items() if 'tc_sram' in t)
        tag_macros=sum(n for t,n in types.items() if 'g6lc_l2_tag' in t)
        assert data_macros==4 and tag_macros==1
        areas.append({'depth':depth,'bytes':262144,'ways':8,'banks':4,'rawCells':stats['num_cells'],'mappedPortionCells':stats['num_cells']-types.get('$scopeinfo',0)-data_macros-tag_macros,'sequentialCells':sum(n for t,n in types.items() if 'DFF' in t.upper()),'dataMacroCells':data_macros,'tagMacroCells':tag_macros,'cellTypes':types,'physicalArea':None})
        (out/'area.json').write_text(json.dumps(areas,indent=2))
    (out/'inputs.json').write_text(json.dumps({'savedResults':str(saved/'results.json'),'resultsSha256':digest(saved/'results.json'),'sources':hashes,'measurementRerun':False},indent=2))
    return 0


def capture_integrations(root, out):
    statuses=[]
    for target,depths in [('g6lc64_smt2',[16,2]),('g6lc64_stream8',[8,2])]:
        for depth in depths:
            child=root/f'{target}-depth{depth}'/'output'
            status={'target':target,'depth':depth,'path':str(child),'present':child.exists()}
            if child.exists():
                dest=out/f'{target}-depth{depth}'
                if os.environ.get('REVIEW_L2_CAPTURE_FULL') == '1':
                    shutil.copytree(child,dest)
                else:
                    dest.mkdir()
                    for name in ['model.json','sources.json','analysis.json','results.json','l2-size.json','build.log']:
                        if (child/name).exists(): shutil.copy2(child/name,dest/name)
                    if (child/'workloads/results.json').exists(): shutil.copy2(child/'workloads/results.json',dest/'workload-results.json')
                status['modelBuilt']=(child/'model.json').exists()
            statuses.append(status)
    for name in ['models.json','comparisons.json','run_l2_size_review.log']:
        if (root/'output'/name).exists(): shutil.copy2(root/'output'/name,out/name)
    (out/'status.json').write_text(json.dumps(statuses,indent=2))
    return 0


def main():
    if os.environ.get('REVIEW_L2_CAPTURE_INTEGRATION'):
        return capture_integrations(Path(os.environ['REVIEW_L2_CAPTURE_INTEGRATION']),Path(os.environ['TH_OUT_DIR']))
    if os.environ.get('REVIEW_L2_PRODUCTION_AREA'):
        return production_area_review(Path(os.environ['REVIEW_L2_PRODUCTION_AREA']),Path(os.environ['TH_OUT_DIR']))
    if os.environ.get('REVIEW_L2_SIZE_ASSESS'):
        return assess_saved(Path(os.environ['REVIEW_L2_SIZE_ASSESS']),Path(os.environ['TH_OUT_DIR']))
    data = Path(os.environ['TH_DATA_DIR'])
    out = Path(os.environ['TH_OUT_DIR'])
    if os.environ.get('REVIEW_L2_SIZE_INTEGRATION') == '1':
        return integration_review(data, out)
    if os.environ.get('REVIEW_L2_SIZE_PROOF') == '1':
        return occupancy_proof(data, out)
    source = out / 'source'
    source.mkdir()
    names = ['axi_pkg.sv', 'tc_sram.sv', 'g6lc_l2_pkg.sv', 'g6lc_l2_tag.sv', 'g6lc_l2_data.sv', 'g6lc_l2_mshr.sv', 'g6lc_l2_top.sv', 'tb_g6lc_l2.sv', 'tb_g6lc_l2.vlt']
    for name in names:
        shutil.copy2(data / name, source / name)
    hashes = {name: digest(source / name) for name in names}
    (out / 'sources.json').write_text(json.dumps(hashes, indent=2))
    runtime_info = json.loads(Path('/opt/testharness/runs/review-cacheability-pair-20260916/output/runtime.json').read_text())
    runtime = Path(runtime_info['privateRoot'])
    assert digest(runtime / 'include/verilated_funcs.h') == 'dfbc2c4aa3c1065d4465027c893c9677de10da4cfe7fb152e485eb32b8125166'
    canaries = Path('/opt/testharness/runs/review-private-runtime-rebuild-20260915/output/canaries.json')
    assert [(r['tag'], r['rc']) for r in json.loads(canaries.read_text())] == [('original', 1), ('fixed', 0)]
    (out / 'runtime.json').write_text(json.dumps(runtime_info, indent=2))
    rtl = [str(source / name) for name in names[:-1]]
    records = []
    phase_names = {'warm','warm_hits','capacity','thrash','hot_scan','wr_rd','nc','lfsr','reset_fill','all_ways_hit','protected_hot','invalidate_masked','exclusive_nc','bypass_backpressure','post_atop_fill','short_last_fill_guard','replacement_hole','fill_error_no_install'}
    references = {}
    production = os.environ.get('REVIEW_L2_SIZE_PRODUCTION') == '1'
    geometry = (262144, 8, 4) if production else (4096, 4, 2)
    profiles = [(6, 0)] if production else [(6, 0), (24, 3)]
    depths = [16, 8, 2] if production else [16, 8, 4, 2]
    for latency, stalls in profiles:
        for depth in depths:
            work = out / f'lat{latency}-stall{stalls}-depth{depth}'
            work.mkdir()
            model = work / 'model'
            command = ['verilator', '--cc', '--main', '--exe', '--timing', '--assert', '--threads', '1', '-Wno-fatal', '-Wno-TIMESCALEMOD', str(source / 'tb_g6lc_l2.vlt'), '--top-module', 'tb_g6lc_l2', f'-GBYTE_SIZE={geometry[0]}', f'-GSET_ASSOC={geometry[1]}', f'-GDATA_BANKS={geometry[2]}', '-GRR_EN=0', f'-GMSHR_DEPTH={depth}', f'-GMEM_LATENCY={latency}', f'-GSTALL_EVERY={stalls}', f'-GTAG_SRAM={os.environ.get("REVIEW_L2_TAG_SRAM", "0")}', '--Mdir', str(model), '-o', 'l2-test', *rtl]
            commands = [('verilate',command), ('build',['make','-C',str(model),'-f','Vtb_g6lc_l2.mk','-j4','VERILATOR_ROOT='+str(runtime)])]
            for label, cmd in commands:
                (work / (label+'-command.json')).write_text(json.dumps(cmd, indent=2))
                with (work / (label+'.log')).open('w') as log:
                    p = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT, timeout=900 if production else 180)
                assert p.returncode == 0, str(work / (label+'.log'))
            dependencies = '\n'.join(p.read_text(errors='replace') for p in model.glob('*.d'))
            assert str(runtime / 'include/verilated_funcs.h') in dependencies
            assert str(Path(runtime_info['originalRoot']) / 'include/verilated_funcs.h') not in dependencies
            exe = model / 'l2-test'
            variants = {}
            for role in ['off','on','repeat','negative']:
                trial = work / role
                trial.mkdir()
                cmd = [str(exe), '+bypass-backpressure', '+atop-drain', '+amo-arith']
                if role != 'off': cmd += ['+mshr-observe', '+mshr-trace']
                if role == 'negative': cmd += ['+mshr-negative']
                p = subprocess.run(cmd, cwd=trial, capture_output=True, text=True, timeout=240 if production else 90)
                text = p.stdout + p.stderr
                (trial / 'sim.log').write_text(text)
                negative = role == 'negative'
                matched = (p.returncode != 0 and 'L2SIZE_OCCUPANCY' in text and '[L2TB] RESULT pass' not in text) if negative else (p.returncode == 0 and text.count('[L2TB] RESULT pass') == 1 and '%Error' not in text)
                phases = {}
                for line in text.splitlines():
                    if line.startswith('[L2TB] phase='):
                        fields = dict(x.split('=',1) for x in line.split()[1:])
                        name = fields.pop('phase')
                        assert name not in phases
                        phases[name] = {k:int(v) for k,v in fields.items()}
                normalized = [line for line in text.splitlines() if re.match(r'\[L2TB\] (phase=|traffic |totals |policy checks |ATOP |AMO arith )',line)]
                peak = re.search(r'\[L2SIZE\] peak=(\d+) allocated=(\d+) completed=(\d+)',text)
                trace = trial / 'ports.log'
                record = {'bytes':geometry[0],'ways':geometry[1],'banks':geometry[2],'latency':latency,'stalls':stalls,'depth':depth,'role':role,'rc':p.returncode,'matched':matched,'phases':phases,'normalized':normalized,'occupancy':list(map(int,peak.groups())) if peak else None,'portsSha256':digest(trace) if trace.exists() and not negative else None,'executableSha256':digest(exe),'strictQualification':False}
                records.append(record)
                (out / 'results.json').write_text(json.dumps(records,indent=2))
                assert matched, str(trial / 'sim.log')
                if not negative:
                    assert set(phases)==phase_names
                    assert '[L2TB] AMO arith add=1 swap=1 cas_hit=1 cas_miss=1 lrsc_ok=1 lrsc_fail=1' in text
                    assert all(f'[L2TB] ATOP mode={m} ' in text for m in range(3))
                    if role!='off': assert peak and int(peak[1])==1 and int(peak[2])==int(peak[3]) and int(peak[2])>0 and trace.stat().st_size>0
                    variants[role] = record
            assert variants['off']['normalized']==variants['on']['normalized']==variants['repeat']['normalized']
            assert variants['on']['portsSha256']==variants['repeat']['portsSha256']
            key = (latency,stalls)
            if depth==16: references[key]=variants['on']
            else:
                assert variants['on']['normalized']==references[key]['normalized'], ('timing/traffic mismatch',key,depth)
                assert variants['on']['portsSha256']==references[key]['portsSha256'], ('port trace mismatch',key,depth)
    areas = []
    for bytes_, ways, macro_data in ([(262144,8,True)] if production else [(512,2,False),(4096,4,True)]):
        for depth in depths:
            label = f'synth-b{bytes_}-w{ways}-depth{depth}'
            work = out / label
            work.mkdir()
            script = 'read_slang ' + ' '.join(rtl) + f' -DL2TB_STATIC -DL2TB_SYNTH --keep-hierarchy --unroll-limit=16384 --top g6lc_l2_fixture -GBYTE_SIZE={bytes_} -GSET_ASSOC={ways} -GMSHR_DEPTH={depth} -GDATA_BANKS={geometry[2]} -GTAG_SRAM={os.environ.get("REVIEW_L2_TAG_SRAM", "0")}\n'
            if macro_data: script += 'blackbox tc_sram*\n'
            if production: script += 'blackbox g6lc_l2_tag*\n'
            script += 'synth -top g6lc_l2_fixture -flatten\ncheck -assert\nselect -assert-none t:$dlatch t:$_DLATCH_*\ntee -o stats.json stat -json\n'
            (work / 'synth.ys').write_text(script)
            with (work / 'synth.log').open('w') as log:
                p = subprocess.run(['yosys','-s',str(work/'synth.ys')],cwd=work,stdout=log,stderr=subprocess.STDOUT,timeout=180)
            assert p.returncode==0, str(work/'synth.log')
            stats = json.loads((work/'stats.json').read_text())['modules']['\\g6lc_l2_fixture']
            cell_types = stats['num_cells_by_type']
            macro_cells = sum(n for t,n in cell_types.items() if 'tc_sram' in t)
            tag_sram = int(os.environ.get('REVIEW_L2_TAG_SRAM', '0'))
            assert macro_cells == ((geometry[2] + tag_sram) if macro_data else 0), 'memory treatment mismatch'
            tag_cells = sum(n for t,n in cell_types.items() if 'g6lc_l2_tag' in t)
            assert tag_cells == int(production), 'tag treatment mismatch'
            areas.append({'bytes':bytes_,'ways':ways,'banks':geometry[2],'depth':depth,'dataMacro':macro_data,'tagMacro':production,'tagMacroCells':tag_cells,'dataCapacityBits':bytes_*8,'cells':stats['num_cells'],'sequentialCells':sum(n for t,n in cell_types.items() if 'DFF' in t.upper()),'macroCells':macro_cells,'cellTypes':cell_types,'physicalArea':None})
            (out/'area.json').write_text(json.dumps(areas,indent=2))
    assert all(digest(source/name)==value for name,value in hashes.items())
    (out/'assessment.json').write_text(json.dumps({'functionalAndTimingMatched':True,'depths':depths,'geometry':geometry,'latencyProfiles':profiles,'productionDefaultsChanged':False,'promotionQualified':False,'tagDataBlackboxedForAreaOnly':production},indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main())
