#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""cts_prefilter.py — T0 static pre-filter for sampled Vulkan CTS cases.

Predicts, WITHOUT running anything, which CTS cases the APU cannot pass
yet, by cross-checking each case name and its dEQP module source against
the device's own declared contract:

  * vn_device_profile.toml   formats, features, limits, extensions
  * g6lc_apu_vn_tables.md    the generated decode table (every Venus
                             command the device decodes, and its class)
  * keep-lists               struct fields the decoder stages (profile)
  * vn_golden.py             golden coverage: argument shapes some vector
                             actually exercises
  * spirv_model.py           shader decorations the reference model
                             consumes (the RTL mirrors it)

Verdicts, strongest first:
  certain-fail   a contract gap the case cannot get past
  untested       the case drives a device path no golden vector covers
  ns-expected    truthful NotSupported (feature/format absent)
  risk           the module calls commands the device does not decode
  predicted-pass nothing found (not a proof: T1-T4 decide)

Sub-commands
  scan   --caselist FILE [--out JSON]        verdict per case + summary
  check  --caselist FILE --results JSON...   score the rules against the
                                             ledger's run results
         (precision/recall of certain-fail+untested vs real defects)

A rule that misses only costs a remote run; a false certain-fail hides
work, so `check` keeps the rules honest.
"""
import argparse
import collections
import glob
import json
import os
import re
import sys
import tomllib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..', '..'))
CTS_MOD = os.path.join(ROOT, 'specs', 'VK-GL-CTS', 'external', 'vulkancts',
                       'modules', 'vulkan')
PROFILE = os.path.join(HERE, 'vn_device_profile.toml')
TABLES_MD = os.path.join(HERE, 'g6lc_apu_vn_tables.md')
GOLDEN = os.path.join(HERE, 'vn_golden.py')
SPV_MODEL = os.path.join(HERE, 'shader', 'spirv_model.py')

# shader-refused (T1 shader_feed): a module of the case does not commit on
# the APU — a truthful refusal when the case requires an unadvertised
# feature, else a fail; ranked between the two
RANK = ['certain-fail', 'untested', 'shader-refused', 'ns-expected', 'risk',
        'predicted-pass']

# dEQP-VK.<module> component -> modules/vulkan/<dir>
MODULE_DIR = {'fragment_operations': 'fragment_ops', 'renderpasses': 'renderpass',
              'renderpass2': 'renderpass', 'dgc': 'device_generated_commands',
              'binding_model': 'binding_model', 'pipeline': 'pipeline',
              'info': '.', 'drm_format_modifiers': 'modifiers'}


class Ctx:
    def __init__(self):
        with open(PROFILE, 'rb') as f:
            self.prof = tomllib.load(f)
        self.formats = {n for n, e in self.prof.get('formats', {}).items()
                        if isinstance(e, dict) and e.get('f')}
        self.features = {k for k, v in self.prof.get('features', {}).items()
                         if v is True}
        self.limits = self.prof.get('limits', {})
        dx = self.prof.get('device_extensions', {})
        self.exts = set(dx) if isinstance(dx, dict) else set(dx or [])
        self.keep = {k: set(v.get('fields', []))
                     for k, v in self.prof.get('keep', {}).items()}
        # decode table: command -> action class
        self.decoded, cls = {}, None
        for ln in open(TABLES_MD, encoding='utf-8'):
            m = re.match(r'^### ([A-Z_]+) \(\d+\)', ln)
            if m:
                cls = m.group(1)
                continue
            m = re.match(r'^- `(vk[A-Za-z0-9]+)`', ln)
            if m and cls:
                self.decoded[m.group(1)] = cls
        self.golden = open(GOLDEN, encoding='utf-8').read()
        self.spvm = open(SPV_MODEL, encoding='utf-8').read()
        self._modcmds = {}

    # golden coverage probes -------------------------------------------
    def golden_has(self, pattern):
        return re.search(pattern, self.golden) is not None

    # CTS module source: Vulkan entry points it calls ------------------
    def module_cmds(self, mod):
        if mod in self._modcmds:
            return self._modcmds[mod]
        d = MODULE_DIR.get(mod, mod)
        cmds = set()
        if d != '.':
            for p in glob.glob(os.path.join(CTS_MOD, d, '**', '*.cpp'),
                               recursive=True):
                src = open(p, encoding='utf-8', errors='replace').read()
                for m in re.finditer(r'\bvk[di]?\.([a-z][A-Za-z0-9]+)\(', src):
                    cmds.add('vk' + m.group(1)[0].upper() + m.group(1)[1:])
        self._modcmds[mod] = cmds
        return cmds


# --- name-token rules ------------------------------------------------------
# A rule: (id, case-name regex, predicate(ctx) -> verdict-or-None, reason).
# The predicate states the CONTRACT check, so a fix flips the rule off by
# itself (profile/table/model edits) — no rule is a hand-kept waiver.

def _texel_buffers(c):
    # only a limit the profile actually states counts (absent != 0)
    if c.limits.get('maxTexelBufferElements', 1) == 0:
        return 'certain-fail'
    if 'pDescriptorWrites.pTexelBufferView' not in c.keep.get(
            'vkUpdateDescriptorSets', set()):
        return 'certain-fail'
    return None


def _row_major(c):
    # spirv_scan sets member flag 1<<(RowMajor % 8) = 0x10; the reference
    # model must consume it (RTL mirrors the model)
    return None if re.search(r'RowMajor|row_major|0x10\b.*mflag', c.spvm) \
        else 'certain-fail'


def _descriptor_copy(c):
    return None if c.golden_has(r"'VkCopyDescriptorSet'") else 'untested'


def _gfx_descriptors(c):
    # descriptor sets bound at the GRAPHICS bind point (0) and read by a
    # VS/FS: no golden vector does that (every BindDescriptorSets uses 1)
    return None if c.golden_has(r"vkCmdBindDescriptorSets', dict\(\s*"
                                r"commandBuffer=\S+,\s*pipelineBindPoint=0") \
        else 'untested'


def _semaphore(c):
    return None if c.golden_has(r'waitSemaphoreCount=[1-9]') else 'untested'


def _immutable_sampler(c):
    # CTS supplies these at layout creation, not through descriptor writes.
    # Merely exercising a graphics bind does not cover this lifetime.
    fields = c.keep.get('vkCreateDescriptorSetLayout', set())
    return None if 'pBindings.pImmutableSamplers' in fields else 'certain-fail'


def _feature(name):
    return lambda c: None if name in c.features else 'ns-expected'


RULES = [
    ('immutable-sampler', r'\.binding_model\..*(sampler_immutable|'
     r'copy_immutable_sampler)', _immutable_sampler,
     'immutable sampler handles are dropped at descriptor-set layout '
     'creation; allocation cannot initialize their descriptor records'),
    # descriptor-binding contexts only: memory.pipeline_barrier's texel
    # variants pass (their texel path is not a descriptor write)
    ('texel-buffer', r'\.(binding_model|descriptor_indexing)\..*'
     r'(uniform|storage)_texel_buffer', _texel_buffers,
     'texel-buffer descriptors: pTexelBufferView not staged by '
     'vkUpdateDescriptorSets'),
    ('row-major', r'row_major', _row_major,
     'RowMajor member decoration parsed (flag 0x10) but not consumed by '
     'spirv_model/shwave: matrices read transposed'),
    ('descriptor-copy', r'\.descriptor_copy\.', _descriptor_copy,
     'vkUpdateDescriptorSets copies: no golden vector has '
     'descriptorCopyCount>0 (path never exercised)'),
    ('gfx-descriptors', r'\.(binding_model|ubo|ssbo)\..*(\.graphics\.|\.vert'
     r'|\.frag|\.vertex|\.fragment|_vertex\b|_fragment\b)', _gfx_descriptors,
     'descriptor sets consumed by VS/FS: no golden vector binds sets at '
     'the graphics bind point'),
    ('semaphore', r'\.(binary_)?semaphore|timeline_semaphore\.|\.timeline\.',
     _semaphore,
     'semaphore waits: no golden vector submits with waitSemaphoreCount>0'),
    ('fp64', r'float64|fp64|double|\bf64', _feature('shaderFloat64'),
     'shaderFloat64 not advertised'),
    ('int64', r'int64|\bi64|\bu64', _feature('shaderInt64'),
     'shaderInt64 not advertised'),
    ('geometry', r'\.geometry\.|geometry_shader', _feature('geometryShader'),
     'geometryShader not advertised'),
    ('tessellation', r'tessellation|\.tess', _feature('tessellationShader'),
     'tessellationShader not advertised'),
    ('wide-lines', r'wide_line|line_width', _feature('wideLines'),
     'wideLines not advertised'),
    ('msaa', r'samples_[248]|multisample|msaa', _feature('sampleRateShading'),
     'multisample support not advertised'),
]

_FMT = re.compile(r'(?<![a-z0-9])((?:[rgbad]\d+)+(?:x\d+)?_(?:unorm|snorm|'
                  r'uscaled|sscaled|uint|sint|ufloat|sfloat|srgb)'
                  r'(?:_pack\d+)?)(?![a-z0-9])')


# cases that probe feature REFUSAL / enumeration by name: a feature token
# in their name is the thing being refused, not exercised
_META = re.compile(r'unsupported_features|\.device_init\.|\.info\.'
                   r'|feature_bits|_features$')


def classify(name, c, feed=None):
    reasons = []
    f = (feed or {}).get(name)
    if f and f.get('verdict') == 'commit-fault':
        reasons.append(('shader-refused', 'shader-commit',
                        'T1: a module faults the APU commit scan (%s)'
                        % f.get('detail', '')))
    elif f and f.get('verdict') == 'ignored-decor':
        reasons.append(('certain-fail', 'shader-decor',
                        'T1: module uses %s, which no consumer reads'
                        % f.get('detail', '')))
    for rid, pat, pred, why in RULES if not _META.search(name) else ():
        if re.search(pat, name):
            v = pred(c)
            if v:
                reasons.append((v, rid, why))
    for tok in set(_FMT.findall(name)):
        vk = tok.upper()
        if vk not in c.formats:
            reasons.append(('ns-expected', 'format',
                            'VK_FORMAT_%s not advertised' % vk))
    mod = name.split('.')[1] if name.count('.') >= 1 else ''
    undec = sorted(x for x in c.module_cmds(mod)
                   if x not in c.decoded and (x.startswith('vkCmd') or
                                               x.startswith('vkCreate')))
    if undec:
        reasons.append(('risk', 'undecoded-cmd',
                        'module calls %d undecoded commands (e.g. %s)'
                        % (len(undec), ', '.join(undec[:4]))))
    if not reasons:
        return 'predicted-pass', []
    best = min(RANK.index(r[0]) for r in reasons)
    return RANK[best], reasons


def cmd_scan(a):
    c = Ctx()
    feed = {}
    for p in a.shader_feed or []:
        feed.update(json.load(open(p)))
    names = [l.strip() for l in open(a.caselist) if l.strip()]
    out, summ = {}, collections.Counter()
    per_rule = collections.Counter()
    per_grp = collections.defaultdict(collections.Counter)
    for n in names:
        v, rs = classify(n, c, feed)
        out[n] = {'verdict': v, 'reasons': [{'verdict': x, 'rule': r, 'why': w}
                                            for x, r, w in rs]}
        summ[v] += 1
        per_grp[n.split('.')[1]][v] += 1
        for x, r, _ in rs:
            per_rule[(r, x)] += 1
    if a.out:
        with open(a.out, 'w') as f:
            json.dump({'caselist': a.caselist, 'cases': out,
                       'summary': dict(summ)}, f, indent=1, sort_keys=True)
    print('cases=%d  ' % len(names) +
          '  '.join('%s=%d' % (k, summ[k]) for k in RANK))
    print('rules:', ', '.join('%s/%s=%d' % (r, x, k)
                              for (r, x), k in per_rule.most_common()))
    if a.groups:
        for g in sorted(per_grp):
            cnt = per_grp[g]
            print('  %-28s ' % g + ' '.join('%s=%d' % (k, cnt[k])
                                            for k in RANK if cnt[k]))
    return 0


def cmd_check(a):
    """Score the rules against run results (newest run per name)."""
    c = Ctx()
    latest = {}
    for p in a.results:
        r = json.load(open(p))
        gen = r.get('meta', {}).get('generated', '')
        for rec in r.get('results', []):
            nm = rec['name']
            if nm not in latest or latest[nm][0] < gen:
                latest[nm] = (gen, rec['status'])
    names = [l.strip() for l in open(a.caselist) if l.strip()] \
        if a.caselist else sorted(latest)
    tp = fp = fn = tn = 0
    ns_ok = ns_bad = flag_ns = 0
    misses = collections.Counter()
    fps = collections.Counter()
    for n in names:
        if n not in latest:
            continue
        st = latest[n][1]
        defect = st not in ('Pass', 'NotSupported')
        v, rs = classify(n, c)
        flagged = v in ('certain-fail', 'untested')
        if flagged and st == 'NotSupported':
            # the case bailed out before reaching the gap: neither a hit
            # nor a false alarm about the path
            flag_ns += 1
            continue
        if flagged and not defect:
            fps[rs[0][1] if rs else '?'] += 1
        if flagged and defect:
            tp += 1
        elif flagged:
            fp += 1
        elif defect:
            fn += 1
            misses['.'.join(n.split('.')[:4])] += 1
        else:
            tn += 1
        if v == 'ns-expected':
            ns_ok += st == 'NotSupported'
            ns_bad += st != 'NotSupported'
    run = tp + fp + fn + tn
    prec = tp / (tp + fp) if tp + fp else 0.0
    rec = tp / (tp + fn) if tp + fn else 0.0
    print('scored %d run cases: flagged-defect tp=%d fp=%d  missed fn=%d  '
          'clean tn=%d  precision=%.3f recall=%.3f'
          % (run, tp, fp, fn, tn, prec, rec))
    print('flagged but NotSupported (not scored): %d' % flag_ns)
    if fps:
        print('false alarms by rule (flagged, passed):',
              ', '.join('%s=%d' % kv for kv in fps.most_common()))
    print('ns-expected: %d NotSupported, %d other' % (ns_ok, ns_bad))
    if misses:
        print('unpredicted defect families (add rules / T1-T2 coverage):')
        for k, v in misses.most_common(12):
            print('  %4d  %s' % (v, k))
    return 0


def cmd_wave(a):
    """Choose a confirmation cohort and a separately labelled discovery
    cohort. A module-level risk or shader refusal is not a predicted pass;
    NS predictions also need execution to establish support-check behavior.
    Uncertain cases remain eligible for discovery rather than disappearing."""
    if a.max < 1 or not 0 <= a.control <= 1:
        raise ValueError('--max must be positive and --control within [0, 1]')
    import random
    with open(a.scan) as f:
        scan = json.load(f)['cases']
    done = set()
    for p in a.results or []:
        with open(p) as f:
            records = json.load(f).get('results', [])
        for rec in records:
            done.add(rec['name'])
    mods = [m for m in (a.modules.split(',') if a.modules else []) if m]
    good = collections.defaultdict(list)
    discovery = collections.defaultdict(list)
    for n, v in scan.items():
        if n in done or (mods and n.split('.')[1] not in mods):
            continue
        if v['verdict'] == 'predicted-pass':
            good[n.split('.')[1]].append(n)
        else:
            discovery[(v['verdict'], n.split('.')[1])].append(n)
    rng = random.Random(a.seed)

    def draw(buckets, count):
        keys = sorted(buckets)
        for key in keys:
            rng.shuffle(buckets[key])
        picked = []
        while len(picked) < count and any(buckets[key] for key in keys):
            for key in keys:
                if buckets[key] and len(picked) < count:
                    picked.append(buckets[key].pop())
        return picked

    pick = draw(good, a.max)
    nctl = max(1, int(round(a.control * (len(pick) or a.max)))) \
        if discovery and a.control else 0
    ctl = draw(discovery, nctl)
    order = {n: i for i, n in enumerate(scan)}
    sel = sorted(pick + ctl, key=lambda n: order[n])
    with open(a.out, 'w') as f:
        f.writelines(n + '\n' for n in sel)
    manifest = {
        'schema': 1, 'scan': a.scan, 'seed': a.seed,
        'results': a.results or [],
        'confirmation': pick, 'discovery': ctl,
        'discovery_verdicts': dict(collections.Counter(
            scan[n]['verdict'] for n in ctl)),
        'note': 'Cohorts are diagnostic, not a conformance or random-rate estimate.',
    }
    with open(a.out + '.json', 'w') as f:
        json.dump(manifest, f, indent=1, sort_keys=True)
    print('wave: %d confirmation + %d discovery -> %s'
          % (len(pick), len(ctl), a.out))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('scan')
    p.add_argument('--caselist', required=True)
    p.add_argument('--out', default='')
    p.add_argument('--groups', action='store_true',
                   help='also print the per-module verdict split')
    p.add_argument('--shader-feed', action='append', default=[],
                   help='T1 shader_feed.py JSON (repeatable)')
    p.set_defaults(fn=cmd_scan)
    p = sub.add_parser('check')
    p.add_argument('--caselist', default='',
                   help='restrict to these names (default: every run case)')
    p.add_argument('--results', action='append', required=True)
    p.set_defaults(fn=cmd_check)
    p = sub.add_parser('wave')
    p.add_argument('--scan', required=True, help='scan --out JSON')
    p.add_argument('--results', action='append', default=[])
    p.add_argument('--modules', default='',
                   help='comma list of dEQP-VK.<module> to draw from')
    p.add_argument('--max', type=int, default=120)
    p.add_argument('--control', type=float, default=0.05)
    p.add_argument('--seed', type=int, default=1)
    p.add_argument('--out', required=True)
    p.set_defaults(fn=cmd_wave)
    a = ap.parse_args(argv)
    return a.fn(a)


if __name__ == '__main__':
    sys.exit(main())
