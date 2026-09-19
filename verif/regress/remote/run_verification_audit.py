"""Collect failed verification engine logs without rerunning the tasks.

Copyright (c) 2026 Etienne Cimon
SPDX-License-Identifier: MIT
"""
import hashlib
import json
import os
from pathlib import Path
import shutil


def main():
    root = Path.home() / '.cache/g6lc-formal-run'
    out = Path(os.environ['TH_OUT_DIR'])
    records = []
    for task in ('g6lc_ooo_rename', 'g6lc_fetch_iq'):
        paths = list(root.glob(task + '*.log'))
        for folder in root.glob(task + '*'):
            if folder.is_dir():
                paths.extend(folder.rglob('logfile.txt'))
                paths.extend(folder.rglob('logfile_basecase.txt'))
                paths.extend(folder.rglob('logfile_induction.txt'))
                paths.extend(folder.rglob('status'))
                paths.extend(folder.rglob('design.log'))
                paths.extend(folder.rglob('trace.aiw'))
                paths.extend(folder.rglob('trace_aiw.yw'))
                paths.extend(folder.rglob('design_aiger.ywa'))
        for path in sorted(set(paths)):
            relative = path.relative_to(root)
            target = out / 'logs' / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)
            text = path.read_text(errors='replace')
            records.append({'path': str(relative), 'mtimeNs': path.stat().st_mtime_ns,
                            'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                            'tail': text.splitlines()[-30:]})
    if not records:
        raise RuntimeError('no formal logs found')
    (out / 'results.json').write_text(json.dumps(records, indent=2))
    print(json.dumps(records, indent=2))


if __name__ == '__main__':
    main()
