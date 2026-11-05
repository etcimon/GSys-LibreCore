#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""shader_feed.py — T1 shader pre-filter for sampled Vulkan CTS cases.

Runs the native (x86) deqp-vk build once on a host software driver
(Mesa lavapipe) with shader-source logging, then feeds every SPIR-V module
each case builds through the APU's own commit scanner
(corev_apu/apu/tools/shader/spirv_scan.py, the bit-exact mirror of
shmod's commit rules).  Per case it reports:

  commit-fault   the APU would refuse a module of this case at create
                 (fault name + opcode), i.e. a certain fail or a truthful
                 refusal depending on what the case advertises
  ignored-decor  the module relies on a decoration the scanner accepts but
                 the shader model does not consume (RowMajor today)
  ok             every module commits

plus lavapipe's own status (a reference outcome only: lavapipe's limits
and features differ from the APU's, so it is never conformance evidence).

  shader_feed.py --caselist FILE --out JSON
                 [--deqp /root/cts/build-native/.../deqp-vk]
                 [--icd /usr/share/vulkan/icd.d/lvp_icd.json]
                 [--chunk 200] [--qpa-dir DIR]
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..', '..', '..', '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'corev_apu', 'apu', 'tools', 'shader'))
import spirv_scan  # noqa: E402

DEQP = '/root/cts/build-native/external/vulkancts/modules/vulkan/deqp-vk'
ICD = '/usr/share/vulkan/icd.d/lvp_icd.json'
_CASE = re.compile(r'#beginTestCaseResult (\S+)(.*?)(?=#beginTestCaseResult|\Z)',
                   re.S)
_ASM = re.compile(r'<SpirVAssemblySource>(.*?)</SpirVAssemblySource>', re.S)
_RES = re.compile(r'<Result StatusCode="(\w+)"')
# decorations the scanner accepts at member level that no consumer reads
# yet.  (RowMajor left this list 2026-11-04: spirv_model + shwave consume
# member flag bit 4 — sh corpus ssbo_rowmajor.)
IGNORED_DECOR = {}


def _unescape(s):
    return (s.replace('&lt;', '<').replace('&gt;', '>')
            .replace('&quot;', '"').replace('&apos;', "'")
            .replace('&amp;', '&'))


def scan_module(asm_text, tmpdir):
    """assemble + commit-scan one module -> (verdict, detail)."""
    src = os.path.join(tmpdir, 'm.spvasm')
    spv = os.path.join(tmpdir, 'm.spv')
    with open(src, 'w') as f:
        f.write(asm_text)
    r = subprocess.run(['spirv-as', '--target-env', 'vulkan1.3', src, '-o', spv],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return 'asm-error', r.stderr.strip()[:200]
    import struct
    data = open(spv, 'rb').read()
    words = [w[0] for w in struct.iter_unpack('<I', data)]
    try:
        spirv_scan.Scanner(words).scan()
    except spirv_scan.Fault as f:
        return 'commit-fault', '%s opcode=%d' % (
            spirv_scan.FAULT_NAME.get(f.code, f.code), f.opcode)
    except Exception as e:                      # scanner bug: report, not hide
        return 'scan-error', repr(e)[:200]
    for name, pat in IGNORED_DECOR.items():
        if pat.search(asm_text):
            return 'ignored-decor', name
    return 'ok', ''


def run_chunk(names, a, qpa):
    with tempfile.NamedTemporaryFile('w', suffix='.txt', delete=False) as cl:
        cl.write('\n'.join(names) + '\n')
    env = dict(os.environ, VK_ICD_FILENAMES=a.icd)
    subprocess.run([a.deqp, '--deqp-caselist-file=' + cl.name,
                    '--deqp-log-shader-sources=enable',
                    '--deqp-log-images=disable',
                    '--deqp-log-filename=' + qpa],
                   cwd=os.path.dirname(a.deqp), env=env,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                   timeout=a.timeout)
    os.unlink(cl.name)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--caselist', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--deqp', default=DEQP)
    ap.add_argument('--icd', default=ICD)
    ap.add_argument('--chunk', type=int, default=200)
    ap.add_argument('--timeout', type=int, default=3600)
    ap.add_argument('--qpa-dir', default='')
    a = ap.parse_args(argv)
    names = [l.strip() for l in open(a.caselist) if l.strip()]
    qdir = a.qpa_dir or tempfile.mkdtemp(prefix='shfeed-')
    os.makedirs(qdir, exist_ok=True)
    out = {}
    tmp = tempfile.mkdtemp(prefix='shfeed-m-')
    for i in range(0, len(names), a.chunk):
        qpa = os.path.join(qdir, 'chunk-%05d.qpa' % (i // a.chunk))
        if not os.path.isfile(qpa):
            try:
                run_chunk(names[i:i + a.chunk], a, qpa)
            except subprocess.TimeoutExpired:
                pass                      # keep whatever the log flushed
        if not os.path.isfile(qpa):
            continue
        text = open(qpa, errors='replace').read()
        for m in _CASE.finditer(text):
            case, body = m.group(1), m.group(2)
            st = _RES.search(body)
            mods = [_unescape(x) for x in _ASM.findall(body)]
            verdict, detail = 'no-shader', ''
            for asm in mods:
                v, d = scan_module(asm, tmp)
                if v != 'ok':
                    verdict, detail = v, d
                    break
                verdict = 'ok'
            out[case] = {'lavapipe': st.group(1) if st else 'Crash',
                         'modules': len(mods), 'verdict': verdict,
                         'detail': detail}
        print('chunk %d: %d cases scanned' % (i // a.chunk, len(out)),
              flush=True)
    with open(a.out, 'w') as f:
        json.dump(out, f, indent=1, sort_keys=True)
    from collections import Counter
    c = Counter(v['verdict'] for v in out.values())
    print('shader feed: %d cases  %s -> %s'
          % (len(out), ' '.join('%s=%d' % kv for kv in sorted(c.items())),
             a.out))
    return 0


if __name__ == '__main__':
    sys.exit(main())
