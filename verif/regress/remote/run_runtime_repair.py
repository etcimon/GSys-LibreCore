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


CANARY = r'''// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
#include "verilated.h"
#include <vector>
#include <cstdio>
int check(int bits, int lsb, int n) {
    const unsigned sentinel = 0xa5a5a5a5U;
    std::vector<WData> values(1400, sentinel);
    WData* p = values.data();
    switch (n) {
      case 1: VL_CONSTHI_W_1X(bits, lsb, p, 1); break;
      case 2: VL_CONSTHI_W_2X(bits, lsb, p, 2, 1); break;
      case 3: VL_CONSTHI_W_3X(bits, lsb, p, 3, 2, 1); break;
      case 4: VL_CONSTHI_W_4X(bits, lsb, p, 4, 3, 2, 1); break;
      case 5: VL_CONSTHI_W_5X(bits, lsb, p, 5, 4, 3, 2, 1); break;
      case 6: VL_CONSTHI_W_6X(bits, lsb, p, 6, 5, 4, 3, 2, 1); break;
      case 7: VL_CONSTHI_W_7X(bits, lsb, p, 7, 6, 5, 4, 3, 2, 1); break;
      case 8: VL_CONSTHI_W_8X(bits, lsb, p, 8, 7, 6, 5, 4, 3, 2, 1); break;
    }
    const int start = (lsb + 31) / 32;
    const int words = (bits + 31) / 32;
    int failures = 0;
    for (int i = 0; i < int(values.size()); ++i) {
        unsigned expected = sentinel;
        if (i >= start && i < start + n) expected = i - start + 1;
        else if (i >= start + n && i < words) expected = 0;
        if (values[i] != expected) ++failures;
    }
    return failures;
}
int main() {
    int failures = check(18958, 18688, 8);
    for (int n = 1; n <= 8; ++n) {
        failures += check((24 + n + 1) * 32 - 3, 24 * 32, n);
        failures += check((24 + n) * 32 - 3, 24 * 32, n);
    }
    std::printf("wide-constant canary failures=%d\n", failures);
    return failures ? 1 : 0;
}
'''


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    root = Path(os.environ['TH_RUN_DIR'])
    out = Path(os.environ['TH_OUT_DIR'])
    source = Path(os.environ['REPAIR_RR_OUTPUT'])
    models = json.loads((source / 'models.json').read_text())
    runs = json.loads((source / 'results.json').read_text())
    assert len(models) == 4 and len(runs) == 6
    original_dir = Path(models[-1]['exe']).parent
    makefile = (original_dir / 'Variane_testharness.mk').read_text()
    original_runtime = Path(re.search(r'^VERILATOR_ROOT\s*=\s*(.+)$', makefile, re.M)[1].strip())
    reused_runtime = os.environ.get('REPAIR_RUNTIME_JSON')
    if reused_runtime:
        prior = Path(reused_runtime)
        runtime_identity = json.loads(prior.read_text())
        runtime = Path(runtime_identity['privateRoot'])
        assert sha(runtime / 'include/verilated_funcs.h') == runtime_identity['fixedHeaderSha256']
        assert sha(original_runtime / 'include/verilated_funcs.h') == runtime_identity['originalHeaderSha256']
        canaries = json.loads((prior.parent / 'canaries.json').read_text())
        assert [(c['tag'], c['rc']) for c in canaries] == [('original', 1), ('fixed', 0)]
    else:
        runtime = root / 'runtime'
        shutil.copytree(original_runtime, runtime)
        header = runtime / 'include/verilated_funcs.h'
        text = header.read_text()
        original_header_sha = sha(header)
        for n in range(1, 9):
            old = f'    VL_C_END_(obits, VL_WORDS_I(lsb) + {n});'
            new = f'    for (int i = VL_WORDS_I(lsb) + {n}; i < VL_WORDS_I(obits); ++i) obase[i] = 0;\n    return o;'
            assert text.count(old) == 1, n
            text = text.replace(old, new)
        header.write_text(text)
        runtime_identity = {'originalRoot': str(original_runtime), 'privateRoot': str(runtime), 'originalHeaderSha256': original_header_sha, 'fixedHeaderSha256': sha(header), 'change': 'CONSTHI zero-fill uses unshifted obase with absolute word indices; return pointer unchanged'}
        canary = out / 'constant_canary.cpp'
        canary.write_text(CANARY)
        canaries = []
        for tag, prefix, expected_rc in [('original', original_runtime, 1), ('fixed', runtime, 0)]:
            exe = out / ('canary-' + tag)
            command = ['g++', '-std=c++17', '-O2', '-I' + str(prefix / 'include'), str(canary), '-o', str(exe)]
            subprocess.run(command, check=True, capture_output=True)
            test = subprocess.run([str(exe)], capture_output=True, text=True)
            canaries.append({'tag': tag, 'rc': test.returncode, 'output': test.stdout, 'command': command})
            assert test.returncode == expected_rc, canaries[-1]
    (out / 'runtime.json').write_text(json.dumps(runtime_identity, indent=2))
    (out / 'canaries.json').write_text(json.dumps(canaries, indent=2))
    print(canaries, flush=True)
    repaired_models = []
    repaired_runs = []
    for model in models:
        original = Path(model['exe'])
        assert sha(original) == model['sha256']
        target = root / model['tag'] / 'model'
        target.mkdir(parents=True)
        source_hashes = {}
        for pattern in ['*.cpp', '*.h', '*.mk', '*.dat']:
            for path in original.parent.glob(pattern):
                shutil.copy2(path, target / path.name)
                source_hashes[path.name] = sha(path)
        work = out / model['tag']
        work.mkdir()
        (work / 'generated-inputs.json').write_text(json.dumps(source_hashes, indent=2))
        repo = Path(model['build'][4])
        assert repo.is_dir()
        build_cmd = ['make', '-C', str(target), '-f', 'Variane_testharness.mk', '-B', '-j4', 'VERILATOR_ROOT=' + str(runtime)]
        with (work / 'build.log').open('w') as log:
            build = subprocess.run(build_cmd, env=dict(os.environ, VPATH=str(repo)), stdout=log, stderr=subprocess.STDOUT, timeout=900)
        if build.returncode:
            raise RuntimeError('corrected-runtime rebuild failed: ' + model['tag'])
        exe = target / 'Variane_testharness'
        digest = sha(exe)
        repaired_models.append(dict(model, exe=str(exe), sha256=digest, derivedFrom=str(original), originalSha256=model['sha256'], runtime=runtime_identity, rebuild=build_cmd))
        (out / 'models.json').write_text(json.dumps(repaired_models, indent=2))
        print('MODEL', repaired_models[-1], flush=True)
        for record in [r for r in runs if r['tag'] == model['tag']]:
            elf = Path(record['command'][-1])
            assert sha(elf) == record['elfSha256']
            command = [str(exe), *record['command'][1:]]
            log_path = work / (record['payload'] + '.log')
            with log_path.open('w') as log:
                run = subprocess.run(command, cwd=work, env={'PATH': '/usr/bin:/bin', 'CVA6_TRACE_SPEC': '; '.join(record['traceRules'])}, stdout=log, stderr=subprocess.STDOUT, timeout=240)
            assert sha(exe) == digest and sha(elf) == record['elfSha256']
            text = log_path.read_text(errors='replace')
            cookies = re.findall(r'\[cookie-exit\] t=(\d+) \[1000\]=0x([0-9a-fA-F]+)', text)
            clean = run.returncode == 0 and '%Error' not in text and 'Assertion failed' not in text
            status = 'pass' if clean and len(cookies) == 1 and int(cookies[0][1], 16) == 1 else 'no-verdict' if clean and not cookies else 'fail'
            repaired_runs.append(dict(record, status=status, rc=run.returncode, cookies=cookies, command=command, modelSha256=digest, runtimeHeaderSha256=runtime_identity['fixedHeaderSha256']))
            (work / (record['payload'] + '.trace')).write_text('\n'.join(line for line in text.splitlines() if '[trace]' in line or '[cookie-exit]' in line))
            (out / 'results.json').write_text(json.dumps(repaired_runs, indent=2))
            print('RESULT', repaired_runs[-1], flush=True)
    if any(r['status'] != 'pass' for r in repaired_runs):
        raise RuntimeError('corrected-runtime control failed')


if __name__ == '__main__':
    main()
