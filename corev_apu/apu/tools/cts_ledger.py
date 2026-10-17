#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""cts_ledger.py — Vulkan CTS must-pass bookkeeping for the LibreCore APU.

The Khronos VK-GL-CTS checkout pinned under specs/VK-GL-CTS is the
acceptance oracle (architecture/uncore/apu-vulkan-engine.md §13).  This
tool never runs the CTS; it turns the pinned must-pass lists and the
`TestResults.qpa` logs a run produced into a per-group ledger.

Sub-commands

  groups   stream every must-pass caselist under
           external/vulkancts/mustpass/main/vk-default/ once and record,
           per group file, its test-case count and the set of
           `dEQP-VK.<a>.<b>` prefixes it contains -> groups JSON
           (keyed by the CTS commit so a pin bump invalidates it)

  select   write an exact-name caselist (a true subset of the pinned
           must-pass) for the given prefixes, in must-pass order

  parse    parse one or more .qpa logs into a results JSON: one record
           per test case {name, status, group, duration_ms?} plus the run
           metadata the caller supplies (run tag, CTS commit, deqp-vk
           sha256, device profile hash, Mesa/kernel versions)

  render   merge results JSONs (newest run wins per test name) and write
           the markdown ledger: per group pass / not-supported /
           quality-warning / fail / crash / timeout / other / not-run,
           owner, last evidence tag

Status semantics are fixed here, not in the renderer's caller: Pass and
NotSupported are the only acceptable outcomes (NotSupported is honest
only when the feature is truthfully absent from the generated profile —
that check is a review step, not something this tool can decide),
QualityWarning/CompatibilityWarning are tracked, everything else is a
defect.  A test case whose log section was never closed counts as
Crash.  Nothing here waives a test.
"""
import argparse
import hashlib
import json
import os
import re
import sys
import time

MUSTPASS_REL = os.path.join('external', 'vulkancts', 'mustpass', 'main')
INDEX = 'vk-default.txt'

# owner column of the ledger: must-pass group file (without .txt) ->
# workstream of architecture/uncore/apu-vulkan-engine.md §13.2 / the plan
OWNER = {
    'api': 'W0/W2 lifetime+memory (G3b residency)',
    'info': 'W0', 'memory': 'W2', 'binding-model': 'W2 (G3b)',
    'ubo': 'W2/W3', 'ssbo': 'W2/W3', 'robustness': 'W2/W3',
    'descriptor-indexing': 'W2/W5', 'postmortem': 'W2',
    'compute': 'W3 shader (G3a)', 'glsl': 'W3 shader (G3a)',
    'spirv-assembly': 'W3', 'subgroups': 'W3', 'reconvergence': 'W3',
    'memory-model': 'W3/W5', 'graphicsfuzz': 'W3', 'shader-abort': 'W3',
    'pipeline': 'W4 raster (G3c/G3d)', 'draw': 'W4 (G3c)',
    'rasterization': 'W4 (G3c)', 'clipping': 'W4', 'depth': 'W4 (G3c)',
    'fragment-operations': 'W4 (G3c)', 'renderpasses': 'W4 (G3c)',
    'dynamic-state': 'W4', 'imageless-framebuffer': 'W4',
    'query-pool': 'W4 (G3c)', 'texture': 'W4 (G3d)', 'image': 'W4 (G3d)',
    'ycbcr': 'W4', 'conditional-rendering': 'W4', 'transform-feedback': 'W8',
    'synchronization': 'W2', 'synchronization2': 'W2',
    'device-group': 'W2', 'protected-memory': 'W5',
    'sparse-resources': 'W5', 'drm-format-modifiers': 'W9',
    'geometry': 'W8', 'tessellation': 'W8', 'multiview': 'W8',
    'mesh-shader': 'W8', 'fragment-shading-rate': 'W8',
    'fragment-shader-interlock': 'W8', 'fragment-shading-barycentric': 'W8',
    'dgc': 'W8', 'ray-query': 'W7', 'ray-tracing-pipeline': 'W7',
    'cooperative-vector': 'W6', 'wsi': 'W9',
    'video': 'optional (NotSupported by absence)',
    'tensor': 'optional (NotSupported by absence)',
    'data-graph': 'optional (NotSupported by absence)',
    'image-processing': 'optional (NotSupported by absence)',
    'shader-object': 'W3/W4', 'amber': 'W3',
}

ACCEPT = ('Pass', 'NotSupported')
TRACK = ('QualityWarning', 'CompatibilityWarning', 'Waiver')
COLUMNS = ['pass', 'not_supported', 'quality_warning', 'fail', 'crash',
           'timeout', 'other', 'pass_with_fault']


def status_column(status):
    if status == 'Pass':
        return 'pass'
    if status == 'NotSupported':
        return 'not_supported'
    if status in TRACK:
        return 'quality_warning'
    if status == 'Fail':
        return 'fail'
    if status in ('Crash', 'DeviceLost'):
        return 'crash'
    if status == 'Timeout':
        return 'timeout'
    return 'other'            # ResourceError, InternalError, Pending, ...


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def cts_commit(cts):
    """HEAD of the pinned checkout without invoking git (the gitlink is
    the pin; a dirty or re-pointed checkout is a review finding)."""
    head = os.path.join(cts, '.git')
    if os.path.isfile(head):            # submodule: gitdir pointer
        with open(head) as f:
            gitdir = f.read().split(':', 1)[1].strip()
        head = os.path.join(cts, gitdir) if not os.path.isabs(gitdir) \
            else gitdir
    with open(os.path.join(head, 'HEAD')) as f:
        ref = f.read().strip()
    if ref.startswith('ref:'):
        with open(os.path.join(head, ref.split(None, 1)[1])) as f:
            return f.read().strip()
    return ref


def group_of_file(rel):
    """`vk-default/image/load-store.txt` -> `image/load-store`; the
    ledger keys on the must-pass file, which is finer than the dEQP
    module."""
    rel = rel.replace('\\', '/')
    if rel.startswith('vk-default/'):
        rel = rel[len('vk-default/'):]
    return rel[:-4] if rel.endswith('.txt') else rel


def read_index(cts):
    base = os.path.join(cts, MUSTPASS_REL)
    with open(os.path.join(base, INDEX)) as f:
        files = [ln.strip() for ln in f if ln.strip()]
    return base, files


def cmd_groups(a):
    base, files = read_index(a.cts)
    commit = cts_commit(a.cts)
    groups = {}
    for rel in files:
        path = os.path.join(base, rel)
        prefixes = {}
        n = 0
        with open(path) as f:
            for ln in f:
                name = ln.strip()
                if not name or name.startswith('#'):
                    continue
                n += 1
                parts = name.split('.')
                # dEQP-VK.<a>.<b> is specific enough to separate the nested
                # groups (image/*, pipeline/monolithic/*, shader-object/*)
                p = '.'.join(parts[:3]) if len(parts) >= 3 else name
                prefixes[p] = prefixes.get(p, 0) + 1
        groups[group_of_file(rel)] = {
            'file': rel, 'count': n, 'sha256': sha256_file(path),
            'prefixes': prefixes,
            'owner': OWNER.get(group_of_file(rel).split('/')[0], 'unassigned'),
        }
    out = {'cts_commit': commit, 'index_sha256':
           sha256_file(os.path.join(base, INDEX)), 'groups': groups,
           'generated': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}
    with open(a.out, 'w') as f:
        json.dump(out, f, indent=1, sort_keys=True)
    total = sum(g['count'] for g in groups.values())
    print('groups=%d tests=%d commit=%s -> %s'
          % (len(groups), total, commit[:12], a.out))
    return 0


def cmd_select(a):
    base, files = read_index(a.cts)
    prefixes = tuple(a.prefix)
    n = 0
    with open(a.out, 'w') as out:
        for rel in files:
            with open(os.path.join(base, rel)) as f:
                for ln in f:
                    name = ln.strip()
                    if name and name.startswith(prefixes):
                        out.write(name + '\n')
                        n += 1
    if n == 0:
        print('no must-pass case matches %r' % (prefixes,), file=sys.stderr)
        return 1
    print('selected %d cases -> %s (sha256 %s)'
          % (n, a.out, sha256_file(a.out)[:16]))
    return 0


def cmd_tree(a):
    """Prefix tree of one must-pass group to --depth levels below
    dEQP-VK, with case counts — the inventory section of a
    specs/architecture/cts-<group>.md file is rendered from this, never
    typed by hand."""
    base, files = read_index(a.cts)
    want = a.group
    rel = None
    for f in files:
        if group_of_file(f) == want:
            rel = f
            break
    if rel is None:
        print('unknown group %r (see vk-default.txt)' % want, file=sys.stderr)
        return 1
    counts = {}
    total = 0
    with open(os.path.join(base, rel)) as f:
        for ln in f:
            name = ln.strip()
            if not name:
                continue
            total += 1
            parts = name.split('.')[1:]          # drop dEQP-VK
            for d in range(1, min(a.depth, len(parts)) + 1):
                key = '.'.join(parts[:d])
                counts[key] = counts.get(key, 0) + 1
    lines = ['| prefix (`dEQP-VK.`…) | cases |', '|---|---:|']
    for key in sorted(counts):
        depth = key.count('.')
        if depth >= a.depth:
            continue
        if a.min_cases and counts[key] < a.min_cases and depth > 0:
            continue
        indent = '&nbsp;&nbsp;' * depth
        lines.append('| %s`%s` | %d |' % (indent, key, counts[key]))
    lines.append('| **total** | %d |' % total)
    text = '\n'.join(lines) + '\n'
    if a.out:
        with open(a.out, 'w') as f:
            f.write(text)
        print('%s: %d cases, %d prefixes -> %s'
              % (want, total, len(counts), a.out))
    else:
        sys.stdout.write(text)
    return 0


_BEGIN = re.compile(r'^#beginTestCaseResult (\S+)')
_RESULT = re.compile(r'<Result StatusCode="([A-Za-z]+)"')
_TERMINATE = re.compile(r'^#terminateTestCaseResult (\S+)')
_DURATION = re.compile(r'<Number Name="TestDuration"[^>]*>(\d+)</Number>')


def parse_qpa(path):
    """One .qpa -> list of {name, status, duration_us}.  A section that
    ends without a <Result> (process crash) is Crash; a
    #terminateTestCaseResult line carries the terminating status."""
    results = []
    cur = None
    status = None
    duration = None
    with open(path, errors='replace') as f:
        for ln in f:
            m = _BEGIN.match(ln)
            if m:
                if cur is not None:
                    results.append({'name': cur, 'status': status or 'Crash',
                                    'duration_us': duration})
                cur, status, duration = m.group(1), None, None
                continue
            if cur is None:
                continue
            m = _RESULT.search(ln)
            if m:
                status = m.group(1)
                continue
            m = _DURATION.search(ln)
            if m:
                duration = int(m.group(1))
                continue
            m = _TERMINATE.match(ln)
            if m:
                status = m.group(1)
                results.append({'name': cur, 'status': status,
                                'duration_us': duration})
                cur, status, duration = None, None, None
                continue
            if ln.startswith('#endTestCaseResult'):
                results.append({'name': cur, 'status': status or 'Crash',
                                'duration_us': duration})
                cur, status, duration = None, None, None
    if cur is not None:
        results.append({'name': cur, 'status': status or 'Crash',
                        'duration_us': duration})
    return results


def load_groups(path):
    with open(path) as f:
        g = json.load(f)
    lookup = {}
    for gname, info in g['groups'].items():
        for p in info['prefixes']:
            lookup[p] = gname
    return g, lookup


def group_for(name, lookup):
    parts = name.split('.')
    for k in (3, 2):
        p = '.'.join(parts[:k])
        if p in lookup:
            return lookup[p]
    return None


def cmd_parse(a):
    g, lookup = load_groups(a.groups)
    recs = []
    logs = []
    for q in a.qpa:
        rs = parse_qpa(q)
        logs.append({'path': q, 'sha256': sha256_file(q), 'cases': len(rs)})
        for r in rs:
            r['group'] = group_for(r['name'], lookup)
            r['log'] = os.path.basename(q)
            recs.append(r)
    meta = {k: getattr(a, k) for k in
            ('run_tag', 'deqp_sha256', 'profile_hash', 'mesa', 'kernel',
             'device_name')}
    # §7b exception contract: the bridge's sticky device-fault count
    # for this run (-1 = not measured / pre-contract run)
    meta['device_faults'] = a.device_faults
    meta['cts_commit'] = g['cts_commit']
    meta['generated'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
    if a.caselist:
        meta['caselist'] = {'path': a.caselist,
                            'sha256': sha256_file(a.caselist)}
    out = {'meta': meta, 'logs': logs, 'results': recs}
    with open(a.out, 'w') as f:
        json.dump(out, f, indent=1)
    by = {}
    for r in recs:
        by[r['status']] = by.get(r['status'], 0) + 1
    unknown = sum(1 for r in recs if r['group'] is None)
    print('cases=%d %s unknown-group=%d -> %s'
          % (len(recs), ' '.join('%s=%d' % kv for kv in sorted(by.items())),
             unknown, a.out))
    return 0


def cmd_render(a):
    g, _ = load_groups(a.groups)
    latest = {}            # test name -> (meta.generated, record, run_tag)
    runs = []
    # §7b exception contract: a run's device_faults budget taints that
    # many of its passing results — a pass with faults in the run
    # record is a pass-with-fault, never a plain pass.  The per-test
    # attribution inside the run is unknowable, so the budget is
    # consumed in ledger (sorted-name) order.
    flrem = {}
    for rp in a.results:
        with open(rp) as f:
            res = json.load(f)
        if res['meta']['cts_commit'] != g['cts_commit']:
            print('refusing %s: results are for CTS %s, groups for %s'
                  % (rp, res['meta']['cts_commit'][:12],
                     g['cts_commit'][:12]), file=sys.stderr)
            return 2
        runs.append(res['meta'])
        tag = res['meta'].get('run_tag')
        flrem[tag] = max(0, int(res['meta'].get('device_faults', -1)))
        stamp = res['meta']['generated']
        for r in res['results']:
            prev = latest.get(r['name'])
            if prev is None or stamp >= prev[0]:
                latest[r['name']] = (stamp, r, res['meta']['run_tag'])
    rows = {}
    for gname, info in g['groups'].items():
        rows[gname] = {c: 0 for c in COLUMNS}
        rows[gname].update({'selected': info['count'], 'run': 0,
                            'owner': info['owner'], 'last': ''})
    stray = 0
    for name, (stamp, r, tag) in sorted(latest.items()):
        gname = r.get('group')
        if gname is None or gname not in rows:
            stray += 1
            continue
        row = rows[gname]
        col = status_column(r['status'])
        if col == 'pass' and flrem.get(tag, 0) > 0:
            col = 'pass_with_fault'
            flrem[tag] -= 1
        row[col] += 1
        row['run'] += 1
        if tag and (not row['last'] or stamp >= row['last_stamp']):
            row['last'] = tag
        row['last_stamp'] = max(row.get('last_stamp', ''), stamp)
    tot = {c: 0 for c in COLUMNS}
    tot['selected'] = tot['run'] = 0
    lines = []
    lines.append('# APU Vulkan CTS ledger (generated)\n')
    lines.append('GENERATED by `corev_apu/apu/tools/cts_ledger.py render` — '
                 'do not edit. CTS commit `%s` (`%s`, must-pass index sha256 '
                 '`%s`). Semantics: `pass` and `not-supported` are the only '
                 'acceptable outcomes and `not-supported` is honest only when '
                 'the capability is truthfully unadvertised; '
                 '`quality-warning` is tracked; `fail`/`crash`/`timeout`/'
                 '`other` are defects; `pass-w-fault` counts a Pass whose '
                 'run recorded execution-time device faults (the §7b '
                 'contract lets a faulted work item complete with undefined '
                 'results, so the result is not a plain pass); '
                 '`not-run` = selected − run. '
                 'Newest run wins per test name. No waivers.\n'
                 % (g['cts_commit'], g.get('generated', ''),
                    g['index_sha256'][:16]))
    lines.append('Runs merged: %s\n' % (', '.join(
        '`%s` (%s, deqp-vk `%s`, profile `%s`%s)' % (
            m.get('run_tag'), m.get('generated'),
            (m.get('deqp_sha256') or '')[:12],
            (m.get('profile_hash') or '')[:12],
            '' if int(m.get('device_faults', -1)) < 0
            else ', faults=%d' % int(m['device_faults']))
        for m in runs) or 'none'))
    lines.append('| group | owner | selected | run | not-run | pass | '
                 'pass-w-fault | not-supported | quality-warning | fail | '
                 'crash | timeout | other | last evidence |')
    lines.append('|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|'
                 '---:|---|')
    for gname in sorted(rows):
        r = rows[gname]
        notrun = r['selected'] - r['run']
        lines.append('| `%s` | %s | %d | %d | %d | %d | %d | %d | %d | %d | %d '
                     '| %d | %d | %s |' % (
                         gname, r['owner'], r['selected'], r['run'], notrun,
                         r['pass'], r['pass_with_fault'],
                         r['not_supported'], r['quality_warning'],
                         r['fail'], r['crash'], r['timeout'], r['other'],
                         ('`%s`' % r['last']) if r['last'] else ''))
        for c in COLUMNS + ['selected', 'run']:
            tot[c] += r[c]
    lines.append('| **total** | | %d | %d | %d | %d | %d | %d | %d | %d | %d | '
                 '%d | %d | |' % (tot['selected'], tot['run'],
                             tot['selected'] - tot['run'], tot['pass'],
                             tot['pass_with_fault'], tot['not_supported'],
                             tot['quality_warning'], tot['fail'],
                             tot['crash'], tot['timeout'], tot['other']))
    if stray:
        lines.append('\n%d result(s) named a test outside the pinned '
                     'must-pass (not counted).' % stray)
    defects = [(name, r['status'], tag) for name, (s, r, tag) in
               sorted(latest.items())
               if status_column(r['status']) in ('fail', 'crash', 'timeout',
                                                 'other')]
    lines.append('\n## Open defects (%d)\n' % len(defects))
    for name, st, tag in defects[:a.max_defects]:
        lines.append('- `%s` — %s (`%s`)' % (name, st, tag))
    if len(defects) > a.max_defects:
        lines.append('- … %d more' % (len(defects) - a.max_defects))
    with open(a.out, 'w') as f:
        f.write('\n'.join(lines) + '\n')
    print('groups=%d run=%d pass=%d not-supported=%d defects=%d -> %s'
          % (len(rows), tot['run'], tot['pass'], tot['not_supported'],
             len(defects), a.out))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('groups')
    p.add_argument('--cts', required=True)
    p.add_argument('--out', required=True)
    p.set_defaults(fn=cmd_groups)
    p = sub.add_parser('select')
    p.add_argument('--cts', required=True)
    p.add_argument('--prefix', action='append', required=True,
                   help='dEQP-VK.… prefix (repeatable); exact must-pass '
                        'names matching any prefix are written in '
                        'must-pass order')
    p.add_argument('--out', required=True)
    p.set_defaults(fn=cmd_select)
    p = sub.add_parser('tree')
    p.add_argument('--cts', required=True)
    p.add_argument('--group', required=True,
                   help='must-pass group as in vk-default.txt without '
                        'the vk-default/ prefix and .txt, e.g. api or '
                        'pipeline/monolithic/monolithic')
    p.add_argument('--depth', type=int, default=3)
    p.add_argument('--min-cases', type=int, default=0)
    p.add_argument('--out', default='')
    p.set_defaults(fn=cmd_tree)
    p = sub.add_parser('parse')
    p.add_argument('--groups', required=True)
    p.add_argument('--qpa', action='append', required=True)
    p.add_argument('--out', required=True)
    p.add_argument('--run-tag', required=True)
    p.add_argument('--deqp-sha256', default='')
    p.add_argument('--profile-hash', default='')
    p.add_argument('--mesa', default='')
    p.add_argument('--kernel', default='')
    p.add_argument('--device-name', default='')
    p.add_argument('--device-faults', type=int, default=-1,
                   help='bridge sticky device-fault count for the run '
                        '(-1 = unmeasured); >0 taints that many Pass '
                        'results as pass-with-fault (§7b contract)')
    p.add_argument('--caselist', default='')
    p.set_defaults(fn=cmd_parse)
    p = sub.add_parser('render')
    p.add_argument('--groups', required=True)
    p.add_argument('--results', action='append', required=True)
    p.add_argument('--out', required=True)
    p.add_argument('--max-defects', type=int, default=200)
    p.set_defaults(fn=cmd_render)
    a = ap.parse_args(argv)
    return a.fn(a)


if __name__ == '__main__':
    sys.exit(main())
