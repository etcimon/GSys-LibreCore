# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Compile and run the directed FP test on a built harness model.

Purpose: give the U6 Phase-5 split FP register class BEHAVIOURAL evidence.
Elaboration and synthesis say the structure holds together; only executing FP
code says an FMA produces the right number.

Designed to be run twice against the same test binary:

  1. on an in-order FP model (``OoOEn=0``) -- this validates the TEST. A
     self-checking program with a wrong expected constant, or one that traps
     before its first check, produces a confident and meaningless result, so
     the oracle is qualified on known-good hardware first.
  2. on an FP-enabled OoO model -- this is the actual measurement.

The test ELF is built here rather than taken from the repo so the exact binary
is hashed into the record and both runs provably execute the same bytes.

Environment:
  FP_REVIEW_MODEL     path to the Variane_testharness executable
  FP_REVIEW_CYCLES    cycle cap (default 2_000_000)
  FP_REVIEW_LABEL     free-form label recorded in results.json (e.g. 'inorder')
"""
import hashlib
import json
import os
import re
import subprocess
from pathlib import Path

REPO = Path('/opt/testharness/repo')


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run_outcome(returncode: int, text: str, cycle_cap: int) -> str:
    if cycle_cap <= 0:
        raise ValueError('cycle cap must be positive')
    verdicts = re.findall(
        r'\*\*\* (SUCCESS|FAILED) \*\*\* \(tohost = (0x[0-9a-fA-F]+|[0-9]+)\) after ([0-9]+) cycles', text)
    if returncode < 0 or re.search(r'%Error|Assertion failed|Aborting', text) or len(verdicts) != 1:
        return 'error'
    if any(status == 'FAILED' or int(value, 16 if value.startswith('0x') else 10) != 0
           for status, value, _ in verdicts):
        return 'fail'
    if returncode != 0:
        return 'error'
    return 'timeout' if int(verdicts[0][2]) >= cycle_cap else 'pass'


def retirement_roi(text: str, start: int, stop: int) -> list:
    rows = []
    active = False
    for line in text.splitlines():
        match = re.match(r'^(?:core\s+0:\s+)?([0-3])\s+(0x[0-9a-fA-F]+)\s+\((0x[0-9a-fA-F]+)\)(.*)$', line)
        if not match:
            continue
        mode, address, instruction, effects = match.groups()
        pc, insn = int(address, 16), int(instruction, 16)
        if pc == start:
            active = True
        if not active:
            continue
        if pc == stop:
            if not rows:
                raise ValueError('empty retirement ROI')
            return rows
        writes = [(kind, int(reg), int(value, 16)) for kind, reg, value in
                  re.findall(r'\b([xf])\s*(\d+)\s+(0x[0-9a-fA-F]+)', effects)
                  if kind == 'f' or int(reg) != 0]
        stores = [(int(a, 16), int(v, 16)) for a, v in
                  re.findall(r'\bmem (0x[0-9a-fA-F]+) (0x[0-9a-fA-F]+)', effects)]
        if stores:
            width = (1 << ((insn >> 12) & 7)) if insn & 3 == 3 else (4 if insn >> 13 == 6 else 8)
            if width not in (1, 2, 4, 8):
                raise ValueError('unsupported store footprint in retirement ROI')
            stores = [(a, v & ((1 << (8 * width)) - 1)) for a, v in stores]
        rows.append((int(mode), pc, insn, writes, stores))
    raise ValueError('retirement ROI did not reach its stop boundary')


def build_fp_review(out: Path, data: Path) -> int:
    harts = int(os.environ.get('FP_REVIEW_BUILD_HARTS', '1'))
    if harts not in (1, 2):
        raise ValueError('review supports NH1 FP or NH2 integer only')
    target = 'g6lc64_ooo' if harts == 1 else 'g6lc64_smt2'
    source = out / 'source'
    source.mkdir()
    flist = (REPO / 'core/Flist.cva6').read_text()
    substitutions = {
        'config_pkg.sv': ('    assert (!(Cfg.OoOEn && Cfg.FpPresent));',
                          '    assert (!(Cfg.OoOEn && Cfg.FpPresent && Cfg.NrHarts > 1));'),
        'g6lc_ooo_dispatch.sv': ('  if (CVA6Cfg.FpPresent) begin : gen_err_ooo_fp',
                               '  if (CVA6Cfg.FpPresent && CVA6Cfg.NrHarts > 1) begin : gen_err_ooo_fp'),
    }
    paths = {'config_pkg.sv': 'core/include/config_pkg.sv',
             'g6lc_ooo_dispatch.sv': 'core/ooo/g6lc_ooo_dispatch.sv',
             'g6lc_rename.sv': 'core/ooo/g6lc_rename.sv',
             'g6lc_prf.sv': 'core/ooo/g6lc_prf.sv',
             'g6lc_iq.sv': 'core/ooo/g6lc_iq.sv',
             'commit_stage.sv': 'core/commit_stage.sv',
             'controller.sv': 'core/controller.sv',
             'store_buffer.sv': 'core/store_buffer.sv',
             target + '_config_pkg.sv': 'core/include/${TARGET_CFG}_config_pkg.sv'}
    for name in ('load_unit.sv', 'lsu_bypass.sv', 'load_store_unit.sv'):
        if (data / name).is_file():
            paths[name] = 'core/' + name
    report = {'target': target, 'harts': harts, 'qualificationOnly': True, 'sources': {}}
    for name, path in paths.items():
        original = data / name
        text = original.read_text()
        if name in substitutions:
            old, new = substitutions[name]
            if text.count(old) != 1:
                raise RuntimeError('review guard site changed: ' + name)
            text = text.replace(old, new)
        if harts == 2:
            extra = []
            if name == 'config_pkg.sv':
                extra = [('Cfg.OoOEn && Cfg.NrHarts > 1', 'Cfg.OoOEn && Cfg.NrHarts > 2')]
            elif name == 'g6lc_ooo_dispatch.sv':
                extra = [('CVA6Cfg.NrHarts > 1) begin : gen_err_ooo_smt',
                          'CVA6Cfg.NrHarts > 2) begin : gen_err_ooo_smt')]
            elif name == target + '_config_pkg.sv':
                extra = [("      OoOEn: bit'(0)", "      OoOEn: bit'(1)"),
                         ("RVF: bit'(CVA6ConfigRVF)", "RVF: bit'(0)"),
                         ("RVD: bit'(CVA6ConfigRVD)", "RVD: bit'(0)"),
                         ("PrfEntries: unsigned'(0)", "PrfEntries: unsigned'(104)")]
            for old, new in extra:
                if text.count(old) != 1:
                    raise RuntimeError('NH2 review site changed: ' + old)
                text = text.replace(old, new)
        copied = source / name
        copied.write_text(text)
        old_path = '${CVA6_REPO_DIR}/' + path
        if flist.count(old_path) != 1:
            raise RuntimeError('review flist site changed: ' + path)
        flist = flist.replace(old_path, str(copied))
        report['sources'][name] = {'originalSha256': sha(original), 'reviewSha256': sha(copied)}
    flist_path = source / 'Flist.cva6'
    flist_path.write_text(flist)
    runtime = Path('/opt/testharness/runs/review-private-runtime-20260915/runtime')
    if sha(runtime / 'include/verilated_funcs.h') != 'dfbc2c4aa3c1065d4465027c893c9677de10da4cfe7fb152e485eb32b8125166':
        raise RuntimeError('unqualified build runtime')
    env = os.environ.copy()
    env.update(CVA6_REPO_DIR=str(REPO), TARGET_CFG=target, VPATH=str(REPO),
               VERILATOR_ROOT=str(runtime),
               VERILATOR_INSTALL_DIR='/opt/testharness/toolchains/verilator-v5.008',
               RISCV='/opt/testharness/toolchains/xpack-riscv-none-elf-gcc-14.2.0-3',
               SPIKE_INSTALL_DIR='/opt/testharness/toolchains/spike')
    harness = source / 'g6lc_tb.cpp'
    harness.write_bytes((data / 'g6lc_tb.cpp').read_bytes())
    report['harnessSha256'] = sha(harness)
    model_dir = out / 'model'
    command = ['make', '-s', 'verilate', 'target=' + target, 'ver-library=' + str(model_dir),
               'flist=' + str(flist_path),
               'verilator=/opt/testharness/toolchains/verilator-v5.008/bin/verilator',
               'verilator_threads=1', 'NUM_JOBS=8', 'TB_CPP=' + str(harness),
               'CXXFLAGS=-DG6LC_FETCH_B -DG6LC_TB_OOO -I/opt/testharness/repo/corev_apu/tb', 'OBJCACHE=ccache']
    report['command'] = command
    with (out / 'build.log').open('w') as log:
        result = subprocess.run(command, cwd=REPO, env=env, stdout=log,
                                stderr=subprocess.STDOUT, timeout=1800)
    model = model_dir / 'Variane_testharness'
    report.update(rc=result.returncode, model=str(model))
    if model.exists():
        report['modelSha256'] = sha(model)
    (out / 'build-review.json').write_text(json.dumps(report, indent=2))
    return result.returncode


def main() -> int:
    out = Path(os.environ['TH_OUT_DIR'])
    data = Path(os.environ['TH_DATA_DIR'])
    if os.environ.get('FP_REVIEW_BUILD') == '1':
        return build_fp_review(out, data)
    model = Path(os.environ['FP_REVIEW_MODEL'])
    label = os.environ.get('FP_REVIEW_LABEL', 'unlabelled')
    cycles = int(os.environ.get('FP_REVIEW_CYCLES', '2000000'))
    if not model.exists():
        raise RuntimeError(f'model not found: {model}')

    # Test name is a parameter so the same harness can run an INTEGER program
    # on the integer OoO model. That is the discriminator for an FP failure:
    # if integer code also fails to retire, the fault is the OoO path, not FP.
    test = os.environ.get('FP_REVIEW_TEST', 'ooo_fp_rename.S')
    src = data / test
    # Negative control. A self-checking program that never reaches its checks
    # exits 0 just as convincingly as one that passes them, so perturb a single
    # expected constant and require the run to FAIL. The mutated value is the
    # FMA result, i.e. a check that only executes if the FP path really ran.
    if os.environ.get('FP_REVIEW_NEGATIVE') == '1':
        text = src.read_text()
        old = '  fmadd.d f7, f4, f5, f6   # 3*5 + 7 = 22.0\n  fcvt.w.d t1, f7, rtz\n  li   a0, 22'
        if text.count(old) != 1:
            raise RuntimeError('negative-control mutation site changed')
        mutated = old.replace('li   a0, 22', 'li   a0, 23')
        src = out / (Path(test).stem + '_negative.S')
        src.write_text(text.replace(old, mutated))
    # Discriminator for block 3: rewrite its f0 uses to f20. f20 is an ordinary
    # FP register with no special physical-0 relationship, so if the block then
    # passes, the fault is specific to FP physical 0 / f0 handling; if it still
    # fails, f0 is innocent and the cause is elsewhere in the block. Isolating
    # this in SOFTWARE avoids guessing at RTL.
    if os.environ.get('FP_REVIEW_F0_AS_F20') == '1':
        text = src.read_text()
        old = ('  fcvt.d.w f0, t0          # f0 = 9.0   (legal: f0 is writable)\n'
               '  fadd.d f8, f0, f2        # 9.0 + 1.0 = 10.0')
        if text.count(old) != 1:
            raise RuntimeError('f0 discriminator site changed')
        new = ('  fcvt.d.w f20, t0         # f20 = 9.0  (ordinary register)\n'
               '  fadd.d f8, f20, f2       # 9.0 + 1.0 = 10.0')
        text = text.replace(old, new).replace(
            '  fmadd.d f9, f2, f2, f0   # 1*1 + 9 = 10.0',
            '  fmadd.d f9, f2, f2, f20  # 1*1 + 9 = 10.0')
        src = out / 'f0_as_f20.S'
        src.write_text(text)
    # Bisect: stop cleanly after block N. A hang gives no exit code at all, so
    # the failing block cannot be read off the verdict the way a wrong result
    # can -- truncating the program is what turns a hang into a bisectable
    # signal (passes => the stall is later; times out => it is at or before N).
    stop = os.environ.get('FP_REVIEW_STOP_AFTER')
    if stop:
        text = src.read_text()
        marker = '  # ---- %d)' % (int(stop) + 1)
        if marker not in text:
            raise RuntimeError('no block %s boundary to stop at' % stop)
        head = text.split(marker)[0]
        tail = text[text.index('# One exit per block.'):]
        src = out / ('stop%s.S' % stop)
        src.write_text(head + '  li   a0, 0\n  jal  exit\n\n' + tail)
    common = REPO / 'verif/tests/custom/common'
    env_dir = REPO / 'verif/tests/custom/env'
    link = common / 'link_verilator.ld'
    if not link.exists():
        raise RuntimeError(f'linker script not found: {link}')
    elf = out / (Path(test).stem + '.elf')
    # Staged probes select their construct at assembly time.
    stage = os.environ.get('FP_REVIEW_STAGE')
    compile_cmd = [
        'riscv-none-elf-gcc', '-march=rv64imafdc_zicsr_zifencei', '-mabi=lp64d',
        *(['-DSTAGE=%s' % stage] if stage else []),
        *os.environ.get('FP_REVIEW_GCC_FLAGS', '').split(),
        *['-D' + name for name in os.environ.get('FP_REVIEW_DEFINES', '').split(',') if name],
        '-static', '-mcmodel=medany', '-fvisibility=hidden',
        '-nostdlib', '-nostartfiles',
        f'-I{env_dir}', f'-I{common}',
        '-T', str(link),
        str(src), *([] if os.environ.get('FP_REVIEW_STANDALONE') == '1' else
                    [str(common / 'syscalls.c'), str(common / 'crt.S')]),
        '-o', str(elf),
    ]
    model_inputs = model.parent / 'Variane_testharness__verFiles.dat'
    input_text = model_inputs.read_text()
    if not re.search(r'--threads\s+1(?:\s|["\'])', input_text):
        raise RuntimeError('review requires a single-thread model')
    if '/core/fetch_B/frontend.sv' not in input_text or re.search(
            r'/(?:fetch_A|smt_legacy)/|Flist\.smt_legacy', input_text):
        raise RuntimeError('review requires fetch_B without retired source inputs')
    dependencies = '\n'.join(p.read_text() for p in model.parent.glob('*.d'))
    runtime_headers = set(re.findall(r'\S+/include/verilated_funcs\.h', dependencies))
    runtime_hashes = {p: sha(Path(p)) for p in sorted(runtime_headers)}
    if not runtime_hashes or set(runtime_hashes.values()) != {
            'dfbc2c4aa3c1065d4465027c893c9677de10da4cfe7fb152e485eb32b8125166'}:
        raise RuntimeError('review model does not use the qualified private runtime')
    record = {'label': label, 'test': test, 'stage': stage,
              'modelSha256': sha(model), 'model': str(model),
              'modelInputsSha256': sha(model_inputs), 'runtimeHeaders': runtime_hashes}
    reuse = os.environ.get('FP_REVIEW_ELF')
    if reuse:
        if any(os.environ.get(key) for key in
               ('FP_REVIEW_NEGATIVE', 'FP_REVIEW_F0_AS_F20', 'FP_REVIEW_STOP_AFTER', 'FP_REVIEW_GCC_FLAGS', 'FP_REVIEW_DEFINES')):
            raise ValueError('frozen ELF replay cannot apply source mutations')
        elf.write_bytes(Path(reuse).read_bytes())
        record.update(reusedElf=reuse, compileRc=None, compileCommand=None)
    else:
        c = subprocess.run(compile_cmd, capture_output=True, text=True, timeout=180)
        (out / 'compile.log').write_text(c.stdout + c.stderr)
        record.update(compileRc=c.returncode, compileCommand=compile_cmd)
        if c.returncode:
            (out / 'results.json').write_text(json.dumps(record, indent=2))
            raise RuntimeError('FP test did not compile; see compile.log')
    record['elfSha256'] = sha(elf)
    disassembly = subprocess.run(['riscv-none-elf-objdump', '-d', str(elf)],
                                capture_output=True, text=True, timeout=60, check=True)
    (out / 'disassembly.txt').write_text(disassembly.stdout)

    # tohost address from the linked binary, so the driver watches the real
    # symbol rather than a hard-coded guess that would silently never fire.
    nm = subprocess.run(['riscv-none-elf-nm', str(elf)],
                        capture_output=True, text=True, timeout=60)
    (out / 'symbols.txt').write_text(nm.stdout)
    m = re.search(r'^([0-9a-fA-F]+)\s+\w\s+tohost$', nm.stdout, re.M)
    if not m:
        raise RuntimeError('no tohost symbol in the linked test')
    tohost = int(m.group(1), 16)
    record['tohost'] = hex(tohost)

    extra = os.environ.get('FP_REVIEW_PLUSARGS', '').split()
    required_harts = int(os.environ.get('FP_REVIEW_REQUIRED_HARTS', '1'))
    if required_harts == 2:
        extra.append('+smt_progress')
    elif required_harts != 1:
        raise ValueError('review hart count must be 1 or 2')
    run_cmd = [str(model), '--seed=1', *extra, f'+max-cycles={cycles}',
               f'+time_out={cycles}', '+debug_disable', '+quiet_axi',
               f'+tohost_addr=0x{tohost:016x}', str(elf)]
    r = subprocess.run(run_cmd, cwd=out, capture_output=True, text=True, timeout=1800)
    text = r.stdout + r.stderr
    (out / 'run.log').write_text(text)
    verdicts = re.findall(r'\*\*\* (?:SUCCESS|FAILED).*', text)
    # The program writes 0 on pass and 1 on fail through exit(); the harness
    # reports that as SUCCESS/FAILED.
    #
    # A TIMEOUT ALSO PRINTS "SUCCESS". When the run hits +max-cycles the driver
    # ends with "*** SUCCESS *** (tohost = 0) after <cap> cycles" even though
    # the program never reached tohost, so accepting the word SUCCESS makes a
    # hang indistinguishable from a pass -- and makes the negative control pass
    # too, which is how this was caught. Require the retired cycle count to be
    # strictly below the cap.
    cyc = [int(m) for m in re.findall(r'\*\*\* SUCCESS \*\*\*.*?after (\d+) cycles', text)]
    # A FAILED verdict is a completed run, not a timeout -- only treat the
    # absence of any verdict, or a SUCCESS at the cap, as a hang. Without this
    # distinction a genuine wrong-result failure is misreported as a stall.
    outcome = run_outcome(r.returncode, text, cycles)
    timed_out = outcome == 'timeout'
    passed = outcome == 'pass'
    record.update(runCommand=run_cmd, rc=r.returncode, verdicts=verdicts, outcome=outcome,
                  cycleCap=cycles, completedCycles=cyc, timedOut=timed_out,
                  fpTestPassed=passed,
                  logSha256=hashlib.sha256(text.encode()).hexdigest())
    if os.environ.get('FP_REVIEW_SPIKE') == '1':
        spike = Path('/opt/testharness/toolchains/spike/bin/spike')
        trace = out / 'spike.trace'
        command = [str(spike), '--isa=RV64IMAFDC_ZICSR_ZIFENCEI', '-m256',
                   '--steps=200000', '-l', '--log-commits', '--log=' + str(trace), str(elf)]
        reference = subprocess.run(command, cwd=out, capture_output=True, text=True, timeout=120)
        (out / 'spike.log').write_text(reference.stdout + reference.stderr)
        stores = [(int(a, 16), int(v, 16)) for a, v in
                  re.findall(r'\bmem (0x[0-9a-fA-F]+) (0x[0-9a-fA-F]+)', trace.read_text())]
        exits = [v >> 1 for a, v in stores if a == tohost and v & 1]
        record['reference'] = {'command': command, 'rc': reference.returncode,
                               'executableSha256': sha(spike), 'exitCodes': exits,
                               'traceSha256': sha(trace)}
        rtl_exits = [int(value, 16 if value.startswith('0x') else 10) for value in
                     re.findall(r'\*\*\* (?:SUCCESS|FAILED) \*\*\* \(tohost = (0x[0-9a-fA-F]+|[0-9]+)\)', text)]
        matched = len(exits) == 1 and reference.returncode == 0 and exits == rtl_exits and outcome in ('pass', 'fail')
        boundaries = {name: int(address, 16) for address, name in
                      re.findall(r'^([0-9a-fA-F]+)\s+\w\s+(main|exit)$', nm.stdout, re.M)}
        try:
            rtl_traces = list(out.glob('trace_rvfi_hart_*.dasm'))
            if len(rtl_traces) != 1:
                raise ValueError('single-hart reference requires exactly one RTL trace')
            rtl_rows = retirement_roi(rtl_traces[0].read_text(), boundaries['main'], boundaries['exit'])
            ref_rows = retirement_roi(trace.read_text(), boundaries['main'], boundaries['exit'])
            same = rtl_rows == ref_rows
            record['reference'].update(retirementsMatch=same, rtlRetirements=len(rtl_rows),
                                       referenceRetirements=len(ref_rows),
                                       rtlTraceSha256=sha(rtl_traces[0]))
            if not same:
                index = next((i for i, pair in enumerate(zip(rtl_rows, ref_rows)) if pair[0] != pair[1]),
                             min(len(rtl_rows), len(ref_rows)))
                record['reference']['firstMismatch'] = {'index': index, 'rtl': rtl_rows[index:index+1],
                                                        'reference': ref_rows[index:index+1]}
            matched = matched and same
        except (ValueError, KeyError) as error:
            record['reference']['comparisonError'] = str(error)
            matched = False
        record['reference']['qualified'] = matched
        passed = passed and matched
    if required_harts == 2:
        progress = {int(h): int(n) for h, n in re.findall(r'\[smt-progress\].*hart=(\d+) retired=(\d+)', text)}
        record['retiredByHart'] = progress
        passed = passed and all(progress.get(h, 0) > 0 for h in range(required_harts))
    record['reviewPassed'] = passed
    (out / 'results.json').write_text(json.dumps(record, indent=2))
    print(json.dumps(record, indent=2))
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
