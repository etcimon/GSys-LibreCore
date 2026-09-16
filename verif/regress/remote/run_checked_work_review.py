#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Rebuild checked-work payloads and classify cookies, not the harness banner."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    data = Path(os.environ['TH_DATA_DIR'])
    out = Path(os.environ['TH_OUT_DIR'])
    model = Path(os.environ['REVIEW_MODEL'])
    expected = os.environ['REVIEW_MODEL_SHA256']
    if digest(model) != expected:
        raise RuntimeError('model provenance mismatch')
    tool = os.environ['REVIEW_TOOL_PREFIX']
    source_name = os.environ.get('REVIEW_SOURCE', 'mini_checked_work.S')
    if Path(source_name).name != source_name:
        raise RuntimeError('source must be an uploaded filename')
    source = (data / source_name).read_text()
    keep_encoding = os.environ.get('REVIEW_KEEP_ENCODING', '0') == '1'
    cap = int(os.environ.get('REVIEW_CYCLE_LIMIT', '500000'))
    if cap < 10240 or cap > 1000000:
        raise ValueError('cycle cap outside 10240..1000000')
    nbytes = int(os.environ.get('REVIEW_NBYTES', '49152'))
    if nbytes < 4096 or nbytes > 49152 or nbytes % 8:
        raise ValueError('checked-work size must be an 8-byte multiple in 4096..49152')
    linker = out / 'checked.ld'
    linker.write_text('ENTRY(_start)\nSECTIONS { . = 0x80000000; .text : { *(.text.init) *(.text*) } . = 0x80001000; .tohost : { *(.tohost) } . = 0x80001080; .data : { *(.data*) } .bss : { *(.bss*) } }\n')
    if os.environ.get('REVIEW_CASE', '') not in {'', 'norvc-n1', 'rvc-n1', 'norvc-n2', 'rvc-n2'}:
        raise RuntimeError('unknown checked-work case')
    results = []
    for compressed, workers in [(False, 1), (True, 1), (False, 2), (True, 2)]:
        tag = f'{"rvc" if compressed else "norvc"}-n{workers}'
        if os.environ.get('REVIEW_CASE') and os.environ['REVIEW_CASE'] != tag:
            continue
        work = out / tag
        work.mkdir()
        asm = work / 'checked.S'
        asm.write_text(source.replace('.option norvc', '.option rvc') if compressed and not keep_encoding else source)
        elf = work / 'checked.elf'
        cmd = [tool+'gcc', '-march=rv64imac_zicsr', '-mabi=lp64', '-nostdlib', '-static',
               '-Wl,--no-relax', '-T', str(linker), f'-DNWORKERS={workers}', f'-DNBYTES={nbytes}',
               str(asm), '-o', str(elf)]
        subprocess.run(cmd, check=True, capture_output=True)
        disassembly = subprocess.check_output([tool+'objdump', '-d', str(elf)], text=True)
        (work / 'disassembly.txt').write_text(disassembly)
        widths = [len(x) for x in re.findall(r'^\s*[0-9a-f]+:\s+([0-9a-f]+)\s', disassembly, re.M)]
        if not widths or (not compressed and any(w != 8 for w in widths)):
            raise RuntimeError('uncompressed encoding check failed')
        run_cmd = [str(model), '-m', str(cap), '-s', '1', '+debug_disable', str(elf)]
        env = {'PATH':'/usr/bin:/bin', 'CVA6_TRACE_SPEC':
               'exit cookie off=0x1000 val=1; exit cookie off=0x1000 val=3; log gpr after=110000 max=80 gpr=a0,a1,s0,s1,s3,s4,t5,t6; log mem after=110000 off=0x100000 max=2'}
        if os.environ.get('REVIEW_TRACE_AFTER'):
            after = int(os.environ['REVIEW_TRACE_AFTER'])
            env['CVA6_TRACE_SPEC'] = (
                'exit cookie off=0x1000 val=1; exit cookie off=0x1000 val=3; '
                f'log gpr after={after} max=3000 gpr=a0,a1,s0,s1,s3,s4,t5,t6')
        with (work / 'sim.log').open('w') as log:
            run = subprocess.run(run_cmd, cwd=work, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=150)
        text = (work / 'sim.log').read_text(errors='replace')
        cookies = re.findall(r'\[cookie-exit\] t=(\d+) \[1000\]=0x([0-9a-fA-F]+)', text)
        clean = run.returncode == 0 and '%Error' not in text and 'Assertion failed' not in text
        status = ('pass' if clean and len(cookies) == 1 and int(cookies[0][1],16) == 1
                  else 'fail' if cookies or not clean else 'no-verdict')
        record = {'tag':tag,'status':status,'rc':run.returncode,'cookie':cookies,
                  'elfSha256':digest(elf),'sourceSha256':digest(asm),'compile':cmd,'run':run_cmd,
                  'compressedInstructions':sum(w == 4 for w in widths)}
        results.append(record)
        excerpt = '\n'.join(line for line in text.splitlines() if '[trace]' in line or '[cookie-exit]' in line)
        (work / 'trace.txt').write_text(excerpt)
        print(record, flush=True)
        print(excerpt[-4000:], flush=True)
    if digest(model) != expected:
        raise RuntimeError('model changed during runs')
    (out / 'result.json').write_text(json.dumps({'executableSha256':expected,
        'strictQualification':False,'runs':results},indent=2))
    return 0 if results and all(r['status'] == 'pass' for r in results) else 1


if __name__ == '__main__':
    sys.exit(main())
