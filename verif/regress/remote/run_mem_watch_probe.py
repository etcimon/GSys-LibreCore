"""Run an ELF on an existing testharness model with the WT mem-watch probe and
keep only the probe lines.

Copyright (c) 2026 Etienne Cimon
SPDX-License-Identifier: MIT

Diagnostic helper: `+smt_mem_watch=<pa>` makes wt_dcache_mem print every
lookup / word write / invalidation that touches one physical word
(`[smt-flow] wt_lookup|wt_word|wt_inval`). The full simulator stdout is
filtered on the fly so a multi-million-cycle run leaves a small log.

Environment: PROBE_MODEL (exe path), PROBE_ELF, PROBE_WATCH (hex PA without
0x), PROBE_TOHOST (0x..), PROBE_CYCLES (default 2300000), PROBE_WALL seconds
(default 5400), PROBE_EXTRA (optional extra plusargs, space separated).
"""
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path


def sha(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as source:
        for chunk in iter(lambda: source.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    out = Path(os.environ['TH_OUT_DIR'])
    model, elf = os.environ['PROBE_MODEL'], os.environ['PROBE_ELF']
    watch, tohost = os.environ['PROBE_WATCH'], os.environ['PROBE_TOHOST']
    cycles = int(os.environ.get('PROBE_CYCLES', '2300000'))
    wall = int(os.environ.get('PROBE_WALL', '5400'))
    extra = os.environ.get('PROBE_EXTRA', '').split()
    if subprocess.run(['pgrep', '-af', '[/]Variane_testharness( |$)'], capture_output=True).returncode != 1:
        raise RuntimeError('another harness is active')
    args = ['timeout', '--signal=TERM', '--kill-after=15s', f'{wall}s', model, '--seed=1',
            '+debug_disable', '+quiet_axi', f'+time_out={cycles}', f'+tohost_addr={tohost}',
            *([f'+smt_mem_watch={watch}'] if watch else []), *extra, elf]
    keep = re.compile(os.environ.get('PROBE_KEEP',
                      r'\[smt-flow\] wt_|^VIS |\*\*\* |\[mc_verdict\]|\[mc_gap\]|\[smt-progress\]|%Error|Assertion'))
    record = {'model': model, 'modelSha256': sha(model), 'elf': elf, 'elfSha256': sha(elf),
              'watch': watch, 'tohost': tohost, 'cycles': cycles, 'command': args}
    (out / 'invocation.json').write_text(json.dumps(record, indent=2))
    kept = total = 0
    with (out / 'watch.log').open('w') as log:
        proc = subprocess.Popen(args, cwd=out, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                errors='replace', bufsize=1)
        for line in proc.stdout:
            total += 1
            if keep.search(line):
                log.write(line)
                kept += 1
        rc = proc.wait()
    record.update(rc=rc, linesTotal=total, linesKept=kept)
    (out / 'results.json').write_text(json.dumps(record, indent=2))
    print(json.dumps({'rc': rc, 'linesTotal': total, 'linesKept': kept}))
    return 0


if __name__ == '__main__':
    sys.exit(main())
