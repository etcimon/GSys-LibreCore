#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""hyp8 Storamic native-checkpoint runner: compile the storamic_ckpt*
firmware variants and run them on an already-built hyp8 model that was
verilated with HYP8_STORAMIC_CKPT=1 (G6LC_STORAMIC_CKPT +
G6LC_STORAMIC_CKPT_TB), grading the same way run_native_ckpt.py does:
firmware tohost verdict AND the platform's final STORAMIC_CKPT_STATE line.

The hyp8 testbench (hyp8_tb.cpp) preloads the ELF image into the checkpoint
model RAM on the first storamic_ckpt_boot_ready edge (+ckpt_preload_max=1
default), so the program runs "from the checkpointed RAM" exactly like the
ariane_testharness native-ckpt stage. Only allowlisted plusargs are passed:
unknown '+' args are fatal in hyp8_tb.cpp, so the ariane-only
+storamic_sba_probe/+storamic_c2_report probes are intentionally absent
(the debug-command-refused case needs the ariane bench and is skipped here).

  HYP8_INT_TAG      integration run tag whose model to run (required)
  HYP8_CKPT_TESTS   space-separated case names; default = the full matrix
  HYP8_CKPT_SRC     source dir override (default TH_DATA_DIR/tests/custom)
  HYP8_MAX_CYCLES   per-test cycle budget (default 12000000, SAVE of a
                    256 KiB image is slow)
  HYP8_NEG_CYCLES   provider-negative budget (default 600000)
  HYP8_PLUSARGS     extra plusargs (space separated, must be allowlisted)

Case verdicts mirror verif/tb/storamic/run_native_ckpt.py:
  pass  = firmware SUCCESS (or the named negative fail code) AND the
          expected STORAMIC_CKPT_STATE final fields AND >=1 ckpt preload.
A missing model/source is reported as incomplete, never as a pass.
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
from pathlib import Path

RUNS = Path('/opt/testharness/runs')
RISCV = '/opt/testharness/toolchains/xpack-riscv-none-elf-gcc-14.2.0-3'
GCC_FLAGS = ['-static', '-mcmodel=medany', '-march=rv64imafdc', '-mabi=lp64d',
             '-fvisibility=hidden', '-nostdlib', '-nostartfiles', '-O2']

FW_CKPT = 'storamic/storamic_ckpt.c'
FW_MH = 'storamic/storamic_ckpt_mh.c'
CRT = 'common/crt.S'
SYSCALLS = 'common/syscalls.c'
LINK_LD = 'common/link_verilator.ld'

STATE_RE = re.compile(r"STORAMIC_CKPT_STATE final (.*)")

# Firmware fail codes (storamic_ckpt.c / storamic_ckpt_mh.c).
FAIL_DATA_RESTORED = 16
FAIL_PEER_DATA = 25
FAIL_TRIGGER_OK = 22

# Bench trigger offsets (g6lc_testharness.sv, CTRL-relative).
TRIG_PRESENCE_DROP = 0x3040
TRIG_PGOOD_DROP = 0x3050
TRIG_HOT_SWAP = 0x3070

# (name, source, standalone(no crt/syscalls), [defines], kind, want_fail,
#  expect_state dict or None)
# kind: 'pass' wants firmware success; 'fail' wants the named tohost code.
# expect_state uses run_native_ckpt.state_ok semantics: exact string or
# ('>=', n). None = state line still required, fields unchecked.
COMMON_STATE = {"initialized": "1", "locked": "0", "busy": "0",
                "providers": "1f", "policy_ready": "1", "errors": "000",
                "present": "1"}
COLD_STATE = dict(COMMON_STATE, valid="1", generation="1", reset_gen="1",
                  rec_active="0", rec_failed="0", done=(">=", 2), error="0")

CASES = [
    ('boot', FW_CKPT, False, ['-DCKPT_BOOT_ONLY'], 'pass', None,
     dict(COMMON_STATE, valid="0", pauses=(">=", 1), releases=(">=", 1),
          done="0", error="0")),
    ('flow', FW_CKPT, False, [], 'pass', None,
     dict(COMMON_STATE, valid="1", generation="1", pauses=(">=", 3),
          releases=(">=", 3), done=(">=", 2), error="0")),
    ('oracle-expect-b', FW_CKPT, False, ['-DCKPT_ORACLE_EXPECT_B'], 'fail',
     FAIL_DATA_RESTORED,
     dict(COMMON_STATE, valid="1", generation="1", done=(">=", 2))),
    # Provider negatives: the stick is withdrawn / loses power-good before
    # SAVE. No checkpoint may appear; the hart normally stalls on sealed RAM,
    # so only the state line + provider withdrawal are graded.
    ('presence-drop', FW_CKPT, False,
     [f'-DCKPT_TRIGGER=0x{TRIG_PRESENCE_DROP:x}UL'], 'provider_neg', None,
     {"valid": "0", "generation": "0", "issue": "0", "done": "0",
      "errors": "000"}),
    ('power-good-drop', FW_CKPT, False,
     [f'-DCKPT_TRIGGER=0x{TRIG_PGOOD_DROP:x}UL'], 'provider_neg', None,
     {"valid": "0", "generation": "0", "issue": "0", "done": "0",
      "errors": "000"}),
    # Hot swap: identity change must re-qualify (map_gen=2) yet the endpoint
    # stays locked on the captured identity: no result, no checkpoint.
    ('hot-swap', FW_CKPT, False,
     [f'-DCKPT_TRIGGER=0x{TRIG_HOT_SWAP:x}UL'], 'provider_neg', None,
     {"valid": "0", "generation": "0", "issue": "0", "done": "0",
      "locked": "1", "map_gen": "2", "providers": "1f", "present": "1"}),
    # Cold recovery: SAVE, mutate, bench power cycle (CTRL+0x3078). The boot
    # recovery agent restores the saved image before the hart is released.
    ('cold-recovery', FW_CKPT, False, ['-DCKPT_COLD'], 'pass', None,
     COLD_STATE),
    ('cold-oracle-expect-b', FW_CKPT, False,
     ['-DCKPT_COLD', '-DCKPT_ORACLE_EXPECT_B'], 'fail', FAIL_DATA_RESTORED,
     COLD_STATE),
    # Dual-active multi-hart (W2): hart0+hart1 live across SAVE/RESTORE.
    # On the 8-hart MC model these are core0's SMT siblings (mhartid 0/1);
    # harts>=2 park in the firmware's WFI loop.
    ('mh-dual-active', FW_MH, True, [], 'pass', None,
     dict(COMMON_STATE, valid="1", generation="1", done=(">=", 2))),
    ('mh-oracle-peer-b', FW_MH, True, ['-DCKPT_ORACLE_EXPECT_B'], 'fail',
     FAIL_PEER_DATA,
     dict(COMMON_STATE, valid="1", generation="1", done=(">=", 2))),
]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def parse_state(text):
    """Return the final STORAMIC_CKPT_STATE fields as a dict of strings."""
    m = None
    for m in STATE_RE.finditer(text):
        pass
    if m is None:
        return None
    out = {}
    for tok in m.group(1).split():
        if "=" in tok:
            k, v = tok.split("=", 1)
            out[k] = v
    return out


def state_ok(state, expect):
    """Check exact (str) and minimum (('>=', n)) expectations."""
    if state is None:
        return False, "no STORAMIC_CKPT_STATE final line"
    for key, want in expect.items():
        got = state.get(key)
        if got is None:
            return False, f"state field {key} missing"
        if isinstance(want, tuple):
            op, n = want
            if op == ">=" and not int(got) >= n:
                return False, f"{key}={got} < {n}"
        elif got != str(want):
            return False, f"{key}={got} != {want}"
    return True, ""


def main():
    out = Path(os.environ['TH_OUT_DIR'])
    tag = os.environ.get('HYP8_INT_TAG')
    assert tag, 'HYP8_INT_TAG required'
    budget = int(os.environ.get('HYP8_MAX_CYCLES', '12000000'))
    neg_budget = int(os.environ.get('HYP8_NEG_CYCLES', '600000'))
    extra = os.environ.get('HYP8_PLUSARGS', '').split()
    data = Path(os.environ.get('TH_DATA_DIR', out / 'data'))
    src_dir = Path(os.environ.get(
        'HYP8_CKPT_SRC', data / 'verif' / 'tests' / 'custom'))

    intdir = RUNS / tag / 'output'
    results = json.loads((intdir / 'results.json').read_text())
    model = intdir / 'model' / 'Variane_testharness'
    assert model.is_file(), f'model missing: {model}'
    assert results['status'] == 'build_complete' and results['build']['rc'] == 0
    model_sha = digest(model)
    assert model_sha == results['build']['modelSha256'], 'model identity changed'

    gcc = f'{RISCV}/bin/riscv-none-elf-gcc'
    nm = f'{RISCV}/bin/riscv-none-elf-nm'
    elf_dir = out / 'elf'
    elf_dir.mkdir(exist_ok=True)

    subset = os.environ.get('HYP8_CKPT_TESTS', '').split()
    names = {c[0] for c in CASES}
    selected = [c for c in CASES if not subset or c[0] in subset]
    missing = [n for n in subset if n not in names]
    assert not missing, f'unknown cases: {missing}'

    summary = {'intTag': tag, 'modelSha256': model_sha,
               'nativeTuning': results['build'].get('nativeTuning'),
               'srcDir': str(src_dir), 'cases': {}, 'incomplete': []}
    rc_all = 0

    def compile_fw(src_rel, standalone, defines, name):
        src = src_dir / src_rel
        if not src.is_file():
            summary['incomplete'].append(f'{name}: missing source {src}')
            return None
        elf = elf_dir / f'{name}.elf'
        argv = [gcc, *GCC_FLAGS]
        if not standalone:
            argv += [str(src_dir / CRT), str(src_dir / SYSCALLS)]
        argv += ['-T', str(src_dir / LINK_LD), str(src)]
        if not standalone:
            argv += ['-I', str(src_dir / 'common'), '-I', str(src_dir / 'env')]
        argv += ['-lgcc', *defines, '-o', str(elf)]
        bld = out / f'{name}.gcc.log'
        with bld.open('w') as fh:
            p = subprocess.run(argv, stdout=fh, stderr=subprocess.STDOUT,
                               cwd=src_dir, timeout=300)
        if p.returncode != 0 or not elf.is_file():
            summary['incomplete'].append(f'{name}: firmware build failed')
            return None
        # tohost cross-check (same hard gate as the directed runner).
        syms = subprocess.run([nm, '-n', str(elf)], capture_output=True,
                              text=True).stdout
        tohost = [l for l in syms.splitlines() if l.endswith(' tohost')]
        if not tohost:
            summary['incomplete'].append(f'{name}: no tohost symbol')
            return None
        entry = {'elfSha256': digest(elf),
                 'tohost': '0x' + format(int(tohost[0].split()[0], 16), 'x')}
        summary['cases'].setdefault('_elfs', {})[name] = entry
        return elf

    for name, src_rel, standalone, defines, kind, want_fail, expect_state \
            in selected:
        case_budget = neg_budget if kind == 'provider_neg' else budget
        elf = compile_fw(src_rel, standalone, defines, name)
        if elf is None:
            rc_all = 1
            continue
        tohost = summary['cases']['_elfs'][name]['tohost']
        log = out / f'{name}.log'
        run_cmd = (['stdbuf', '-oL'] if shutil.which('stdbuf') else []) + [
            str(model), f'+tohost_addr={tohost}', '+debug_disable',
            f'+max-cycles={case_budget}', '+storamic_ckpt_report',
            '+storamic_ckpt_trace', '+quiet_axi', *extra, str(elf)]
        timed_out = False
        try:
            with log.open('w') as fh:
                p = subprocess.run(run_cmd, stdout=fh, stderr=subprocess.STDOUT,
                                   cwd=out, timeout=14400)
        except subprocess.TimeoutExpired:
            timed_out = True
            p = subprocess.CompletedProcess(run_cmd, 124, '', '')
        text = log.read_text(errors='replace') if log.is_file() else ''
        sim = {'rc': p.returncode, 'timed_out': timed_out,
               'log': log.name}
        success = ('*** SUCCESS ***' in text and
                   'cycle budget reached' not in text)
        failed = re.findall(r'\*\*\* FAILED \*\*\*.*tohost = (\S+)', text)
        pe = re.search(r'program exit code (\d+)', text)
        prog_exit = int(pe.group(1)) if pe else None
        sim['success'] = success
        sim['fail_code'] = failed[0] if failed else None
        sim['prog_exit'] = prog_exit
        sim['state'] = parse_state(text)
        sim['preloads'] = len(re.findall(
            r'\[preload\] ckpt boot_ready load', text))
        sim['errors'] = text.count('%Error')
        sim['markers'] = ' '.join(sorted(set(re.findall(
            r'STORAMIC_[A-Z0-9_]+(?:REQUIRED|UNSUPPORTED|CONFIG|VIOLATION)',
            text))))
        budget_cap = 'cycle budget reached' in text

        # Firmware verdict.
        if kind == 'pass':
            v_ok = success and sim['errors'] == 0
        elif kind == 'fail':
            code = prog_exit if prog_exit is not None else (
                int(sim['fail_code']) if sim['fail_code'] else None)
            v_ok = (not success) and code == want_fail
        else:  # provider_neg: firmware verdict is not the grade
            v_ok = True
        # Provider negatives: state must show no fabricated checkpoint and
        # (for presence/pgood) the provider nibble must have withdrawn; the
        # hot-swap case additionally requires locked=1 + map_gen=2 (checked
        # by state_ok) and a non-CP_OK firmware outcome.
        s_ok, why = state_ok(sim['state'], expect_state or {})
        if sim['state'] is None:
            s_ok, why = False, 'no STORAMIC_CKPT_STATE final line'
        extra_ok = True
        if kind == 'provider_neg':
            st = sim['state'] or {}
            # No fabricated CP_OK under a withdrawn/swap provider (the
            # FAIL_TRIGGER_OK discrimination check from run_native_ckpt).
            extra_ok = sim['fail_code'] != str(FAIL_TRIGGER_OK)
            if name in ('presence-drop', 'power-good-drop'):
                extra_ok = extra_ok and st.get('providers') not in (None, '1f')
            if name == 'hot-swap':
                extra_ok = extra_ok and not success
        cold_cases = name.startswith('cold')
        preload_ok = (sim['preloads'] == 1) if cold_cases else \
            (sim['preloads'] >= 1)
        sim['pass'] = bool(v_ok and s_ok and extra_ok and preload_ok and
                           sim['errors'] == 0 and not timed_out)
        sim['why'] = why or ('' if v_ok else 'firmware verdict') or (
            '' if extra_ok else 'provider check') or (
            '' if preload_ok else 'preload count')
        summary['cases'][name] = sim
        print(f"{name}: {'PASS' if sim['pass'] else 'FAIL'} "
              f"success={success} fail_code={sim['fail_code']} "
              f"prog_exit={prog_exit} preloads={sim['preloads']} "
              f"state={sim['state']} why={sim['why']}")
        if not sim['pass']:
            rc_all = 1

    (out / 'storamic-ckpt-results.json').write_text(
        json.dumps(summary, indent=2))
    (out / 'summary.txt').write_text(
        f"hyp8-storamic-ckpt: intTag={tag} cases={len(summary['cases'])} "
        f"rc={rc_all}\n")
    print(f"hyp8-storamic-ckpt: intTag={tag} "
          f"cases={len(summary['cases'])} rc={rc_all}")
    return rc_all


if __name__ == '__main__':
    raise SystemExit(main())
