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


def main():
 root=Path(os.environ['TH_RUN_DIR']);out=Path(os.environ['TH_OUT_DIR']);data=Path(os.environ['TH_DATA_DIR'])
 frozen=Path('/opt/testharness/runs/review-l2-size-integrations-20260916')
 overlays=['core/ooo/g6lc_iq.sv','core/frontend/g6lc_bp_tage.sv','corev_apu/l2_cache/g6lc_l2_mshr.sv','corev_apu/src/g6lc_cluster.sv']
 results=[];models=[]
 for target in ['g6lc64_smt2','g6lc64_stream8']:
  previous=frozen/(target+'-depth2')/'output'
  identity=json.loads((previous/'model.json').read_text());source_hashes=json.loads((previous/'sources.json').read_text())
  assert identity['l2Size']['effectiveDepth']==2
  oldrepo=Path(identity['sourceRoot']);repo=root/target/'repo';repo.parent.mkdir();shutil.copytree(oldrepo,repo)
  for name,value in source_hashes.items():assert digest(repo/name)==value,name
  package=f'core/include/{target}_config_pkg.sv'
  assert digest(repo/package)==digest(data/Path(package).name)==identity['l2Size']['packageSha256']
  cluster=(repo/'corev_apu/src/g6lc_cluster.sv').read_text()
  probes=re.findall(r'`ifndef SYNTHESIS\n//pragma translate_off\n  localparam int unsigned G6lcSizeExpected.*?`endif\n',cluster,re.S)
  assert len(probes)==1
  for name in overlays:shutil.copy2(data/Path(name).name,repo/name)
  cluster_file=repo/'corev_apu/src/g6lc_cluster.sv';text=cluster_file.read_text();marker='  // Silence unused';assert text.count(marker)==1
  cluster_file.write_text(text.replace(marker,probes[0]+'\n'+marker))
  core=repo/'core/cva6.sv';text=core.read_text();old=str(oldrepo/'verif/tb/core/g6lc_operand_trace.svh');assert text.count(old)==1
  core.write_text(text.replace(old,str(repo/'verif/tb/core/g6lc_operand_trace.svh')))
  closed={name:digest(repo/name) for name in source_hashes}
  changed=[name for name in closed if closed[name]!=source_hashes[name]]
  assert set(changed)<=set(overlays+['core/cva6.sv'])
  runtime_info=identity['runtime'] if 'runtime' in identity else json.loads((previous/'runtime.json').read_text())
  runtime=Path(runtime_info['privateRoot']);assert digest(runtime/'include/verilated_funcs.h')=='dfbc2c4aa3c1065d4465027c893c9677de10da4cfe7fb152e485eb32b8125166'
  model=root/target/'model';result=out/target;result.mkdir()
  oldmodel=Path(identity['exe']).parent
  command=[arg.replace(str(oldrepo),str(repo)).replace(str(oldmodel),str(model)) for arg in identity['build']]
  (result/'build-command.json').write_text(json.dumps(command,indent=2))
  with (result/'build.log').open('w') as log:p=subprocess.run(command,cwd=repo,stdout=log,stderr=subprocess.STDOUT,timeout=900)
  assert p.returncode==0,'build '+target
  assert all(digest(repo/name)==value for name,value in closed.items())
  deps='\n'.join(p.read_text(errors='replace') for p in model.glob('*.d'))
  assert str(runtime/'include/verilated_funcs.h') in deps and str(Path(runtime_info['originalRoot'])/'include/verilated_funcs.h') not in deps
  exe=model/'Variane_testharness';model_sha=digest(exe)
  (result/'sources.json').write_text(json.dumps(closed,indent=2))
  models.append({'target':target,'exe':str(exe),'sha256':model_sha,'sourceRoot':str(repo),'sourceDelta':changed,'baselineModelSha256':identity['sha256'],'runtime':runtime_info})
  (out/'models.json').write_text(json.dumps(models,indent=2))
  record_root=previous if target=='g6lc64_smt2' else previous/'workloads'
  golden=json.loads((record_root/'results.json').read_text())
  controls={} if target=='g6lc64_smt2' else {r['payload']:r for r in json.loads((record_root/'controls.json').read_text())}
  assert len(golden)==(13 if target=='g6lc64_smt2' else 11)
  for n,before in enumerate(golden):
   tag=before.get('tag',before.get('payload','case'))+'-'+str(n);work=result/tag;work.mkdir()
   elf=Path(before['command'][-1]);assert digest(elf)==before['elfSha256']
   command=[str(exe),*before['command'][1:]]
   rules='exit cookie off=0x1000 val=1; exit cookie off=0x1000 val=3' if target=='g6lc64_smt2' else '; '.join(controls[before['payload']]['traceRules'])
   with (work/'sim.log').open('w') as log:p=subprocess.run(command,cwd=work,env={'PATH':'/usr/bin:/bin','CVA6_TRACE_SPEC':rules},stdout=log,stderr=subprocess.STDOUT,timeout=240)
   text=(work/'sim.log').read_text(errors='replace');cookies=[list(x) for x in re.findall(r'\[cookie-exit\] t=(\d+) \[1000\]=0x([0-9a-fA-F]+)',text)]
   assert f'L2SIZE_CONFIG target={target} depth=2 bytes=262144 ways=8 banks=4' in text
   retirement={p.name:digest(p) for p in work.glob('trace_hart_*.dasm')}
   trace=work/'operand-trace-0.log';trace_sha=digest(trace) if trace.exists() else None
   report={}
   for field in before.get('report',{}):
    values=[int(v,16) for v in re.findall(r'\[trace\] t=\d+ tag='+field+r' loc=0x([0-9a-fA-F]+)',text)]
    assert len(values)>=2 and values[-1]==values[-2];report[field]=values[-1]
   matched=p.returncode==before['rc'] and '%Error' not in text and 'Assertion failed' not in text and cookies==before['cookie'] and retirement==before['retirement']
   if target=='g6lc64_smt2':matched=matched and trace_sha==before['traceSha256']
   else:matched=matched and report==before['report'] and not trace.exists()
   record={'target':target,'tag':tag,'matchedBaseline':matched,'rc':p.returncode,'cookie':cookies,'retirement':retirement,'traceSha256':trace_sha,'report':report,'modelSha256':model_sha,'elfSha256':digest(elf),'negativeControl':before.get('negativeControl',False),'strictQualification':False}
   results.append(record);(out/'results.json').write_text(json.dumps(results,indent=2));assert matched,record
   assert digest(exe)==model_sha
  if target=='g6lc64_smt2':shutil.copy2(previous/'analysis.json',result/'reference-analysis-bound-by-identical-traces.json')
  assert all(digest(repo/name)==value for name,value in closed.items())
 (out/'assessment.json').write_text(json.dumps({'allMatched':True,'records':len(results),'scope':'same checked execution/timing as immutable qualified depth-two models; no OoO/L3 release claim','sourceOverlays':overlays},indent=2))
 return 0


if __name__=='__main__':sys.exit(main())
