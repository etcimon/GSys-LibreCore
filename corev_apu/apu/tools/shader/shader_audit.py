#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Mechanical checks on the shader front (plan invariants I1 and I4).

  lists    the result-bearing opcode sets kept by hand in four places
           (spirv_scan, spirv_model, g6lc_apu_shmod, g6lc_apu_shwave) and
           the two accept sets (spirv_scan, g6lc_apu_shmod) must agree.
           Known, explained differences are listed in ALLOW; anything else
           is a finding.
  vectors  regenerate every shader vector into a scratch directory and
           compare .exp/.tab/.hex with the tree (CR ignored).  A stored
           expectation that the current generator no longer produces is a
           finding.

Exit status 0 = no finding.  Neither check runs RTL.
"""
import argparse
import os
import re
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
APU = os.path.abspath(os.path.join(HERE, '..', '..'))
sys.path.insert(0, HERE)

# opcode -> reason it is legitimately absent from one list
ALLOW = {
    # shmod reserves these result rows on dedicated paths (S_RES is
    # entered from the ExtInst / call / helper-query handlers), so they
    # are not in its generic has_result() case
    ('shmod.has_result', 12): 'OpExtInst: own commit handler',
    ('shmod.has_result', 57): 'OpFunctionCall: own commit handler',
    ('shmod.has_result', 5381): 'IsHelperInvocation: own commit handler',
    # the scanner registers these in their own handlers, not h_result
    ('scan.h_result', 12): 'OpExtInst: h_12',
    ('scan.h_result', 57): 'OpFunctionCall: h_57',
    ('scan.h_result', 245): 'OpPhi: h_245',
}


def sv_case_set(path, func):
    """opcode literals of the first `unique case` arm in SV function."""
    src = open(path, encoding='utf-8').read()
    m = re.search(r'function automatic logic\s+(?:\[[^\]]*\]\s*)?' +
                  re.escape(func) + r'\b.*?unique case \(o\)(.*?):\s*\n'
                  r'(?:\s*//[^\n]*\n)*\s*' +
                  re.escape(func) + r"\s*=\s*1'b1", src, re.S)
    if not m:
        raise SystemExit('cannot find %s in %s' % (func, path))
    body = re.sub(r'//[^\n]*', '', m.group(1))
    return {int(x) for x in re.findall(r"(?:16'd)?(\d+)\s*(?:,|$)", body)}


def scan_h_result():
    import spirv_scan
    return {int(n[2:]) for n, v in vars(spirv_scan.Scanner).items()
            if n.startswith('h_') and n[2:].isdigit() and
            v is spirv_scan.Scanner.h_result}


def check_lists():
    import spirv_scan
    import spirv_model
    sets = {
        'scan.h_result': scan_h_result(),
        'model.HAS_RTY': set(spirv_model.Model.HAS_RTY),
        'shmod.has_result': sv_case_set(
            os.path.join(APU, 'g6lc_apu_shmod.sv'), 'has_result'),
        'shwave.f_has_rty': sv_case_set(
            os.path.join(APU, 'g6lc_apu_shwave.sv'), 'f_has_rty'),
    }
    union = set().union(*sets.values())
    bad = 0
    for name, s in sorted(sets.items()):
        for o in sorted(union - s):
            if (name, o) in ALLOW:
                continue
            bad += 1
            print('FINDING result-bearing opcode %d missing from %s '
                  '(present in %s)' % (
                      o, name, ', '.join(k for k, v in sorted(sets.items())
                                         if o in v)))
    acc = {
        'scan.ACCEPT': set(spirv_scan.ACCEPT),
        'shmod.is_accepted': sv_case_set(
            os.path.join(APU, 'g6lc_apu_shmod.sv'), 'is_accepted'),
    }
    for o in sorted(acc['scan.ACCEPT'] ^ acc['shmod.is_accepted']):
        bad += 1
        print('FINDING opcode %d accepted by %s only' % (
            o, 'scan.ACCEPT' if o in acc['scan.ACCEPT']
            else 'shmod.is_accepted'))
    # accepted and result-bearing somewhere, but never executed as one
    for o in sorted(union - acc['scan.ACCEPT']):
        bad += 1
        print('FINDING opcode %d is result-bearing but not accepted' % o)
    # fragment-only opcodes: shmod faults them outside a Fragment module
    # in its commit arms; those labels must equal the set in the table
    import sh_opcodes
    src = open(os.path.join(APU, 'g6lc_apu_shmod.sv'),
               encoding='utf-8').read()
    fr = set()
    for m in re.finditer(r'\n\s*([\d,\s]+): begin\n\s*if \(em_q != '
                         r'APU_SH_EM_FRAGMENT\)', src):
        fr |= {int(v) for v in re.findall(r'\d+', m.group(1))}
    for o in sorted(fr ^ set(sh_opcodes.FRAG_ONLY)):
        bad += 1
        print('FINDING opcode %d fragment-only in %s only' % (
            o, 'sh_opcodes' if o in sh_opcodes.FRAG_ONLY else 'shmod'))
    print('lists: %d result-bearing opcodes, %d accepted, %d findings' % (
        len(union), len(acc['scan.ACCEPT']), bad))
    return bad


def check_vectors():
    import shader_vectors as sv
    tree = sv.OUT
    bad = 0
    with tempfile.TemporaryDirectory(prefix='shv-') as td:
        sv.OUT = td
        so = sys.stdout
        sys.stdout = open(os.devnull, 'w')
        try:
            rc = sv.main()
        finally:
            sys.stdout.close()
            sys.stdout = so
        if rc:
            print('FINDING generator failed (rc=%s)' % rc)
            return 1
        n = 0
        for f in sorted(os.listdir(td)):
            if not f.endswith(('.exp', '.tab', '.hex')):
                continue
            n += 1
            ref = os.path.join(tree, f)
            if not os.path.exists(ref):
                bad += 1
                print('FINDING %s is generated but not in the tree' % f)
                continue
            a = open(ref, 'rb').read().replace(b'\r', b'')
            b = open(os.path.join(td, f), 'rb').read().replace(b'\r', b'')
            if a != b:
                bad += 1
                print('FINDING %s is stale' % f)
    print('vectors: %d files compared, %d findings' % (n, bad))
    return bad


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('what', nargs='*', help='lists, vectors (default: both)')
    a = ap.parse_args()
    a.what = a.what or ['lists', 'vectors']
    if set(a.what) - {'lists', 'vectors'}:
        ap.error('choose from lists, vectors')
    bad = 0
    if 'lists' in a.what:
        bad += check_lists()
    if 'vectors' in a.what:
        bad += check_vectors()
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
