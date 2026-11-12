#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Write the opcode case labels of sh_opcodes.py into the RTL.

  gen_sh_opcodes.py           rewrite the marked regions
  gen_sh_opcodes.py --check   rc 1 if any region differs (prints which)

A region is the label list of one `unique case` arm:

    // GEN-BEGIN sh_opcodes:<set>
    1,12,...,16'd5381:
    // GEN-END

Sets: accept (every opcode), result (result-bearing), result_shmod
(result-bearing minus the opcodes shmod reserves from their own arm),
agg_result (result may be a struct or array),
nva0/1/3/4 (opcodes with that fixed operand count; 2 is the default).
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
APU = os.path.abspath(os.path.join(HERE, '..', '..'))
sys.path.insert(0, HERE)
import sh_opcodes as T  # noqa: E402

SETS = {
    'accept': sorted(T.ACCEPT),
    'result': sorted(T.RESULT),
    'result_shmod': sorted(T.RESULT - set(T.SHMOD_OWN)),
}
SETS['agg_result'] = sorted(T.AGG_RESULT)
# fixed operand counts; 2 is the RTL default arm
for _k in (0, 1, 3, 4):
    SETS['nva%d' % _k] = sorted(c for c, n in T.NVA.items() if n == _k)
FILES = ['g6lc_apu_shmod.sv', 'g6lc_apu_shwave.sv']
RX = re.compile(r'^([ \t]*)// GEN-BEGIN sh_opcodes:(\w+)\n(.*?)'
                r'^[ \t]*// GEN-END\n', re.S | re.M)


def labels(codes, indent, width=76):
    """comma-separated case labels, wrapped; wide literals sized."""
    out, line = [], indent
    toks = [("16'd%d" % c) if c > 255 else str(c) for c in codes]
    for i, t in enumerate(toks):
        t += ':' if i == len(toks) - 1 else ','
        if len(line) + len(t) > width and line.strip():
            out.append(line.rstrip())
            line = indent
        line += t
    out.append(line.rstrip())
    return '\n'.join(out) + '\n'


def render(src):
    n = [0]

    def sub(m):
        n[0] += 1
        ind, name = m.group(1), m.group(2)
        if name not in SETS:
            raise SystemExit('unknown set %s' % name)
        return ('%s// GEN-BEGIN sh_opcodes:%s\n%s%s// GEN-END\n' %
                (ind, name, labels(SETS[name], ind), ind))
    return RX.sub(sub, src), n[0]


def main():
    check = '--check' in sys.argv
    bad = total = 0
    for f in FILES:
        p = os.path.join(APU, f)
        old = open(p, encoding='utf-8', newline='').read()
        new, n = render(old.replace('\r\n', '\n'))
        total += n
        if '\r\n' in old:
            new = new.replace('\n', '\r\n')
        if new != old:
            bad += 1
            if check:
                print('DRIFT %s: opcode labels differ from sh_opcodes.py'
                      % f)
            else:
                open(p, 'w', encoding='utf-8', newline='').write(new)
                print('wrote %s' % f)
    if total != 8:
        print('expected 8 marked regions, found %d' % total)
        return 1
    if check:
        print('sh_opcodes: %d regions, %d drifted' % (total, bad))
        return 1 if bad else 0
    return 0


if __name__ == '__main__':
    sys.exit(main())
