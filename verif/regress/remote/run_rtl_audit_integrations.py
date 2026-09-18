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


def arch_digest(p):
 # Retirement trace with the leading retirement-cycle column removed, so an
 # architecturally identical run whose instructions retire a cycle earlier is
 # still recognised as identical. PC, encoding and privilege are all retained.
 h=hashlib.sha256();count=0
 for line in p.read_text(errors='strict').splitlines():
  if not line.strip():continue
  match=re.fullmatch(r'\s*\d+\s+(0x[0-9a-fA-F]+\s+\S+\s+\(0x[0-9a-fA-F]+\).*)',line)
  if not match:raise ValueError('malformed retirement row')
  h.update((match[1]+'\n').encode());count+=1
 if not count:raise ValueError('empty retirement trace')
 return h.hexdigest()


def pc_digest(p):
 # Instruction-identity stream: PC + encoding only, with consecutive identical
 # PCs collapsed. A predictor-timing change may legitimately shift rdcycle/
 # rdinstret read *values* (and the instructions that propagate them) plus the
 # terminal spin-loop iteration count; none of those alter which instructions
 # retire. This digest still catches a wrong-path retire, a dropped
 # instruction, or an opcode substitution.
 h=hashlib.sha256()
 prev=None
 for line in p.read_text(errors='replace').splitlines():
  # trace_hart_*.dasm lines look like "  265 0x10000 M (0x00100413) DASM(...)".
  m=re.search(r'0x([0-9a-fA-F]+)\s+\S+\s*\(0x([0-9a-fA-F]+)\)',line)
  if not m:continue
  key=(m.group(1),m.group(2))
  if key==prev:continue
  prev=key
  h.update((key[0]+' '+key[1]+'\n').encode())
 return h.hexdigest()


def ms_digest(p):
 # Multiset identity for merged-hart streams: on a multi-hart model a single
 # trace_hart_*.dasm carries every hart's commits interleaved, so the linear
 # order has no architectural meaning — a fetch-latency change legitimately
 # reshuffles the merge and re-counts peer-flag poll iterations while each
 # hart still retires its own program in order (an in-order commit stream
 # cannot reorder within a hart). The binding invariant is therefore the
 # count of each (pc, privilege, encoding) triple; 'jal x0,0' (0x0000006f) is
 # an unbounded terminal self-loop whose count is pure timing and is excluded.
 # Multiset equality still fails on any dropped, added, or wrong-path retire.
 h=hashlib.sha256();counts={}
 for line in p.read_text(errors='replace').splitlines():
  m=re.search(r'0x([0-9a-fA-F]+)\s+(\S+)\s*\(0x([0-9a-fA-F]+)\)',line)
  if not m or m.group(3)=='0000006f':continue
  key=(m.group(1),m.group(2),m.group(3))
  counts[key]=counts.get(key,0)+1
 for key in sorted(counts):h.update((key[0]+' '+key[1]+' '+key[2]+' x'+str(counts[key])+'\n').encode())
 return h.hexdigest()


# Report fields that legitimately track microarchitectural timing under a
# predictor change. The rest (load/store/data_req retired-op counts) are
# architectural and must match exactly.
TIMING_LEGIBLE_REPORT_FIELDS = {'roi_cycles', 'l2_miss', 'l1d_miss', 'l1i_miss'}


def trace_digest(p):
 # Operand-trace identity: the retired-instruction outcome stream.
 # `ot-retire` drop=0 records carry pc plus the architectural result
 # (rd/value/ack/ex/cause/we/waddr/wdata); `t`/`gen`/`tid`/`p` are timing and
 # allocation stamps that legitimately shift under a fetch-latency change.
 # Consecutive identical records collapse so a timing-bounded loop (rdcycle
 # poll, flag spin) that simply iterates longer in the same window still
 # compares identical — the same class pc_digest absorbs in the dasm stream.
 # ot-fetch/ot-issue/ot-ex/ot-alu/ot-wb records are microarchitectural event
 # and interleave timing: their architectural content already surfaces in
 # the retired stream, and a fetch-latency change legitimately re-times and
 # re-counts them (deeper speculation, shifted issue slots). The log is a
 # merged multi-hart stream and the cross-hart interleave has no
 # architectural order, so `h` (the committing hart_id) splits the records
 # and each hart's own retired sequence is bound independently — per-hart
 # program order, not file order. A wrong-path retire, dropped instruction,
 # or corrupted result still fails this digest.
 h=hashlib.sha256()
 per_hart={};prev={}
 for line in p.read_text(errors='replace').splitlines():
  if not line.startswith('[ot-retire]'):continue
  fields={f.split('=',1)[0]:f.split('=',1)[1] for f in line.split()[1:] if '=' in f}
  if fields.get('drop')!='0':continue
  hart=fields.get('h','-')
  key=' '.join(fields[k] for k in ('h','pc','op','rd','value','ack','macro_ack','ex','cause','we','whart','waddr','wdata') if k in fields)
  if prev.get(hart)==key:continue
  prev[hart]=key
  per_hart.setdefault(hart,[]).append(key)
 for hart in sorted(per_hart):
  h.update(('#'+hart+'\n').encode())
  for key in per_hart[hart]:h.update((key+'\n').encode())
 return h.hexdigest()


def preservation_matches(arch,expected_arch,trace_sha,expected_trace_sha):
 return (bool(arch) and bool(expected_arch) and arch==expected_arch
         and trace_sha==expected_trace_sha)


def comparator_self_test():
 from types import SimpleNamespace
 def source(text):return SimpleNamespace(read_text=lambda **kwargs:text)
 a='1 0x1000 M (0x00108093) DASM(00108093)\n'
 b='2 0x1004 M (0x00210113) DASM(00210113)\n'
 def check(left,right):
  return preservation_matches({'trace':arch_digest(source(left))},
                              {'trace':arch_digest(source(right))},None,None)
 assert check(a+b,a.replace('1 0x','9 0x')+b)
 for altered in (b+a,a,a+a+b,a.replace(' M ',' S ')+b,
                 a.replace('00108093','00308093')+b):
  assert not check(a+b,altered)
 assert not check(a+a,a)
 for text in ('','garbage\n',a+'broken\n'):
  try:arch_digest(source(text))
  except ValueError:pass
  else:raise AssertionError('invalid trace accepted')
 assert not preservation_matches({}, {}, None, None)
 assert not preservation_matches({'trace':'same'}, {'trace':'same'}, None, 'expected')
 assert not preservation_matches({'trace':'same'}, {'trace':'same'}, 'changed', 'expected')
 print('INTEGRATION_COMPARATOR_SELF_TEST_PASS',flush=True)


def reassess(record_path,out):
 captured=json.loads(record_path.read_text())
 frozen=Path('/opt/testharness/runs/review-l2-size-integrations-20260916')
 results=[];positions={}
 for record in captured:
  target=record['target'];n=positions.get(target,0);positions[target]=n+1
  previous=frozen/(target+'-depth2')/'output'
  record_root=previous if target=='g6lc64_smt2' else previous/'workloads'
  before=json.loads((record_root/'results.json').read_text())[n]
  if target=='g6lc64_smt2':assert 'traceSha256' in before,'missing SMT2 trace contract'
  else:assert before.get('traceSha256') is None,'unexpected stream8 trace contract'
  assert record['elfSha256']==before['elfSha256']
  work=record_path.parent/target/record['tag']
  retirement={p.name:digest(p) for p in work.glob('trace_hart_*.dasm')}
  assert retirement==record['retirement'] and retirement,'captured trace identity'
  trace=work/'operand-trace-0.log';trace_sha=digest(trace) if trace.exists() else None
  assert trace_sha==record['traceSha256'],'captured operand identity'
  arch={p.name:arch_digest(p) for p in work.glob('trace_hart_*.dasm')}
  expected={k:v[0] for k,v in golden_arch(record_root,before['retirement']).items()}
  bound=preservation_matches(arch,expected,trace_sha,before.get('traceSha256'))
  results.append({'target':target,'tag':record['tag'],
                  'recordedMatchedBaseline':record['matchedBaseline'],
                  'architecturalPreservationBound':bound,
                  'orderedRetirementEqual':arch==expected,
                  'exactOperandTraceEqual':trace_sha==before.get('traceSha256'),
                  'status':'preservation-bound' if bound else 'requires-independent-validation',
                  'strictQualification':False})
 assert positions=={'g6lc64_smt2':13,'g6lc64_stream8':11},positions
 (out/'reassessment.json').write_text(json.dumps({
  'sourceResults':str(record_path),'sourceResultsSha256':digest(record_path),
  'scope':'Reclassification of captured traces only; no new RTL execution, no inferred corruption from a timing divergence.',
  'records':results},indent=2))
 return 0


def golden_arch(record_root,exact_hashes):
 # Bind to the frozen trace files by their recorded exact hash, never by name.
 out={}
 for name,value in exact_hashes.items():
  for candidate in record_root.rglob(name):
   if digest(candidate)==value:
    out[name]=(arch_digest(candidate),pc_digest(candidate),ms_digest(candidate));break
  assert name in out,(name,value)
 return out


def main():
 comparator_self_test()
 root=Path(os.environ['TH_RUN_DIR']);out=Path(os.environ['TH_OUT_DIR']);data=Path(os.environ['TH_DATA_DIR'])
 if os.environ.get('REVIEW_INTEGRATION_REASSESS'):
  return reassess(Path(os.environ['REVIEW_INTEGRATION_REASSESS']),out)
 if os.environ.get('REVIEW_SUPPLY_RECOVER')=='1':
  capture=Path('/opt/testharness/runs/supply-cap-v3')
  hashes={};missing=[]
  for name in ('run.log','model.json','inputs.json'):
   original=capture/name
   if not original.is_file():missing.append(name);continue
   value=digest(original);shutil.copy2(original,out/name)
   assert digest(original)==digest(out/name)==value,'capture changed during retrieval'
   hashes[name]=value
  assert 'run.log' in hashes,'missing supply capture'
  (out/'capture-identity.json').write_text(json.dumps({
   'sourceRoot':str(capture),'files':hashes,'missing':missing,
   'scope':'Recovered artifacts only; absent model/input provenance is not inferred.'},indent=2))
  return 0
 frozen=Path('/opt/testharness/runs/review-l2-size-integrations-20260916')
 # The OoO files form a self-consistent set: the frozen flist link-checks every
 # module in the compile list even under OoOEn=0, so overlaying g6lc_iq alone
 # PINMISSING-fails the old dispatch's instantiation. dispatch drives the new
 # iq/lsq/memdep/rename ports, and issue_stage feeds commit_ptr_i.
 # The predictor fabric adds g6lc_bp_ckpt (new push/pop port split) and
 # frontend.sv, which drives the prediction-time push_cf_i/cf_resolve_i ports
 # so the frozen models exercise the new checkpoint association end to end.
 overlays=['core/ooo/g6lc_iq.sv','core/ooo/g6lc_ooo_dispatch.sv','core/ooo/g6lc_lsq.sv','core/ooo/g6lc_memdep.sv','core/ooo/g6lc_rename.sv','core/issue_stage.sv','core/scoreboard.sv','core/include/config_pkg.sv','core/frontend/g6lc_bp_tage.sv','core/frontend/g6lc_bp_tage_table.sv','core/frontend/g6lc_bp_ghist.sv','core/frontend/g6lc_bp_ckpt.sv','core/frontend/g6lc_bp_top.sv','core/frontend/g6lc_bp_ittage.sv','core/fetch_B/frontend.sv','core/fetch_B/g6lc_fetch_dbg.sv','core/cache_subsystem/g6lc_icache.sv','corev_apu/l2_cache/g6lc_l2_mshr.sv','corev_apu/l2_cache/g6lc_l2_top.sv','corev_apu/l3_cache/g6lc_l3_top.sv','corev_apu/l3_cache/g6lc_l3_inclusive_inv.sv','corev_apu/coherence/g6lc_coherence_hub.sv','corev_apu/tb/g6lc_tb.cpp','corev_apu/src/g6lc_cluster.sv']
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
   if target=='g6lc64_smt2':assert 'traceSha256' in before,'missing SMT2 trace contract'
   else:assert before.get('traceSha256') is None,'unexpected stream8 trace contract'
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
   # Architectural identity (instruction stream) is required. Exact identity
   # additionally pins retirement cycles; it is recorded separately because a
   # cache-timing change can retire the same instructions a cycle earlier.
   # The stream8 gate compares the PC+encoding stream (archpc): rdcycle/
   # rdinstret read values and terminal spin counts legitimately track timing
   # and may differ under a predictor change — archpc still fails on any
   # wrong-path retire or dropped instruction. The value-bearing digest is
   # kept for reporting and flagged as timingLegibleDivergence when it alone
   # differs.
   arch={q.name:arch_digest(q) for q in work.glob('trace_hart_*.dasm')}
   archpc={q.name:pc_digest(q) for q in work.glob('trace_hart_*.dasm')}
   archms={q.name:ms_digest(q) for q in work.glob('trace_hart_*.dasm')}
   expected=golden_arch(record_root,before['retirement'])
   expected_arch={k:v[0] for k,v in expected.items()}
   expected_archpc={k:v[1] for k,v in expected.items()}
   expected_archms={k:v[2] for k,v in expected.items()}
   # Both targets bind on the retired instruction identity. The strong form
   # is the PC+encoding sequence (archpc): a fetch-latency change (e.g. the
   # W1 I$ overlap) legitimately shifts retirement cycles, timing-visible
   # read values and bounded-loop counts while the sequence stays identical.
   # On a multi-hart model the single trace_hart_*.dasm is a *merged* stream —
   # cross-hart interleave has no architectural order, so the merged-hart
   # binding is the (pc, priv, encoding) multiset (archms) instead. Both still
   # fail on a wrong-path retire, dropped instruction or opcode substitution;
   # value identity remains bound by arch/cookies/report/operand-trace.
   arch_ok=preservation_matches(arch,expected_arch,trace_sha,before.get('traceSha256'))
   timing_identical=retirement==before['retirement']
   timing_legible=arch_ok and not timing_identical
   # Cookie *values* (the tohost pass/fail sequence) are architectural; the
   # cookie *timestamps* record the cycle the write retired at and shift
   # legitimately under a fetch-latency change, exactly like retirement
   # cycles do.
   cookie_ok=bool(cookies) and bool(before['cookie']) and [c[1] for c in cookies]==[c[1] for c in before['cookie']]
   matched=p.returncode==before['rc'] and '%Error' not in text and 'Assertion failed' not in text and cookie_ok and arch_ok
   legible_report={}
   if target=='g6lc64_smt2':
    # The operand trace binds the retired outcome stream (trace_digest), not
    # the raw file: fetch/issue event records legitimately re-time and
    # re-count under a fetch-latency change, and a timing-bounded loop may
    # retire extra identical iterations — exact sha only when timing-identical.
    golden_trace=None
    if before.get('traceSha256'):
     golden_trace=next((c for c in record_root.rglob('operand-trace-*.log') if digest(c)==before.get('traceSha256')),None)
     assert golden_trace,'golden operand trace missing'
    trace_ok=trace_sha==before.get('traceSha256')
    matched=matched and trace_ok and (timing_identical or timing_legible or arch==expected_arch)
   else:
    # Report identity on architectural fields; timing-legible microarch
    # counters (roi_cycles, miss counts) are recorded but not compared.
    strict_report={k:v for k,v in report.items() if k not in TIMING_LEGIBLE_REPORT_FIELDS}
    expected_report={k:v for k,v in before['report'].items() if k not in TIMING_LEGIBLE_REPORT_FIELDS}
    legible_report={k:(v,before['report'].get(k)) for k,v in report.items() if k in TIMING_LEGIBLE_REPORT_FIELDS and before['report'].get(k)!=v}
    matched=matched and strict_report==expected_report and not trace.exists()
   record={'target':target,'tag':tag,'matchedBaseline':matched,'rc':p.returncode,'cookie':cookies,'retirement':retirement,'retirementArch':arch,'retirementArchPC':archpc,'retirementArchMS':archms,'timingIdentical':timing_identical,'timingLegibleDivergence':timing_legible,'traceSha256':trace_sha,'report':report,'legibleReportDeltas':legible_report,'modelSha256':model_sha,'elfSha256':digest(elf),'negativeControl':before.get('negativeControl',False),'strictQualification':False}
   results.append(record);(out/'results.json').write_text(json.dumps(results,indent=2));assert matched,record
   assert digest(exe)==model_sha
  if target=='g6lc64_smt2' and all(r['timingIdentical'] for r in results if r['target']==target):
   shutil.copy2(previous/'analysis.json',result/'reference-analysis-bound-by-identical-traces.json')
  assert all(digest(repo/name)==value for name,value in closed.items())
 (out/'assessment.json').write_text(json.dumps({'allMatched':True,'records':len(results),'cycleIdenticalRecords':sum(1 for r in results if r['timingIdentical']),'timingLegibleDivergences':sum(1 for r in results if r.get('timingLegibleDivergence')),'scope':'Ordered retirement rows identical after removing only the cycle column; operand traces identical when captured; nonempty cookie values and checked-work reports bound. PC/multiset digests are diagnostic only. Changed values, repeated-work counts or merged-hart order require independent architectural validation, not automatic acceptance. No OoO/L3 or physical release claim','sourceOverlays':overlays},indent=2))
 return 0


if __name__=='__main__':sys.exit(main())
