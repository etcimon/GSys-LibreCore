"""Build an isolated natural OpenSBI profile and require a strict dual-hart payload.

Copyright (c) 2026 Etienne Cimon
SPDX-License-Identifier: MIT
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(command, log, cwd=None, env=None, timeout=300):
    with log.open('w') as output:
        result = subprocess.run(command, cwd=cwd, env=env, stdout=output,
                                stderr=subprocess.STDOUT, timeout=timeout)
    return result.returncode


def source_passed(rc, log, trace, progress, tohost, seen):
    stores = re.findall(r'^1 .*\bmem (0x[0-9a-fA-F]+) (0x[0-9a-fA-F]+)', trace, re.M)
    observed = {int(a, 16) for a, v in stores if int(v, 16) == 1}
    required = {tohost, seen, seen + 8}
    return (rc == 0 and '[rvfi_tracer] INFO: Simulation terminated' in log
            and progress.get(0, 0) > 0 and progress.get(1, 0) > 0
            and len(required) == 3 and required <= observed)


def main():
    out = Path(os.environ['TH_OUT_DIR'])
    data = Path(os.environ['TH_DATA_DIR'])
    shutil.copy2(Path(__file__), out / 'runner.py')
    for tool in ('riscv-none-elf-gcc', 'riscv-none-elf-objcopy', 'make', 'dtc'):
        if not shutil.which(tool):
            raise RuntimeError(f'missing provisioned tool: {tool}')
    model = Path(os.environ['SOURCE_REVIEW_MODEL'])
    manifest = json.loads((data / 'build-manifest.json').read_text())
    if manifest['executableSha256'] != sha(model) or manifest['target'] != 'g6lc64_smt2':
        raise RuntimeError('source-profile model identity mismatch')
    verfiles = (model.parent / 'Variane_testharness__verFiles.dat').read_text()
    control = os.environ.get('SOURCE_REVIEW_COMPILER_CONTROL')
    if control:
        control_path = Path(control)
        if str(control_path) not in verfiles:
            raise RuntimeError('compiler control absent from generated model inputs')
        shutil.copy2(control_path, out / control_path.name)
    if not re.search(r'--threads\s+1(?:\s|["\'])', verfiles) or '/core/fetch_B/frontend.sv' not in verfiles:
        raise RuntimeError('source-profile requires single-thread fetch_B')
    if re.search(r'/(?:fetch_A|smt_legacy)/|Flist\.smt_legacy', verfiles):
        raise RuntimeError('excluded source input')
    dependencies = '\n'.join(p.read_text(errors='replace') for p in model.parent.glob('*.d'))
    headers = set(re.findall(r'\S+/include/verilated_funcs\.h', dependencies))
    if not headers or any(sha(Path(p)) != 'dfbc2c4aa3c1065d4465027c893c9677de10da4cfe7fb152e485eb32b8125166' for p in headers):
        raise RuntimeError('unqualified model runtime')
    previous = os.environ.get('SOURCE_REVIEW_PROFILE')
    if previous:
        profile = Path(previous) / 'profile.json'
        record = json.loads(profile.read_text())
        if sha(Path(record['firmware'])) != record['firmwareSha256'] or sha(Path(record['payload'])) != record['payloadSha256']:
            raise RuntimeError('frozen source-profile artifact changed')
        record.update(parentProfile=str(profile), model=str(model), modelSha256=sha(model), runnerSha256=sha(Path(__file__)))
        if control:
            record['compilerControl'] = {'path': control, 'sha256': sha(control_path)}
        (out / 'profile.json').write_text(json.dumps(record, indent=2))
        return execute(model, record, out)
    source = out / 'opensbi'
    source.mkdir()
    archive = data / 'opensbi-v1.5-source-455de672.tar'
    with tarfile.open(archive) as tar:
        tar.getmembers()
        if tar.pax_headers.get('comment') != '455de672dd7c2aa1992df54dfb08dc11abbc1b1a':
            raise RuntimeError('source archive is not the pinned upstream commit')
        tar.extractall(source, filter='data')
    protected = ('firmware/fw_base.S', 'lib/sbi/sbi_init.c', 'lib/sbi/sbi_hsm.c',
                 'platform/generic/platform.c', 'lib/utils/libfdt/fdt_ro.c')
    original_hashes = {p: sha(source / p) for p in protected}
    patch_hashes = {}
    for script in ('patch_opensbi_nopie.py', 'wrap_pie_flags.py', 'patch_opensbi_g6lc_clint.py'):
        path = data / script
        target = source if script.endswith('g6lc_clint.py') else source / 'Makefile'
        patch_hashes[script] = sha(path)
        if run([sys.executable, str(path), str(target)], out / (script + '.log')):
            raise RuntimeError(f'platform recipe failed: {script}')
    if any(sha(source / p) != v for p, v in original_hashes.items()):
        raise RuntimeError('platform recipe changed protected firmware logic')
    helpers = out / 'profile/software/smt2-linux/scripts'
    helpers.mkdir(parents=True)
    configs = out / 'profile/core/include'
    configs.mkdir(parents=True)
    shutil.copy2(data / 'dts_to_dtb.py', helpers / 'dts_to_dtb.py')
    shutil.copy2(data / 'g6lc64_smt2_config_pkg.sv', configs / 'g6lc64_smt2_config_pkg.sv')
    dtb = out / 'ariane-smt2.dtb'
    if run([sys.executable, str(helpers / 'dts_to_dtb.py'),
            '-i', str(data / 'ariane-smt2.dts'), '-o', str(dtb)], out / 'dtb.log'):
        raise RuntimeError('DTB validation failed')
    payload = out / 'payload.elf'
    binary = out / 'payload.bin'
    compilation = ['riscv-none-elf-gcc', '-march=rv64imac_zicsr', '-mabi=lp64', '-mcmodel=medany',
                   '-nostdlib', '-nostartfiles', '-static', '-Wl,--no-relax', '-DG6LC_STRICT_DUAL',
                   '-T', str(data / 'link.ld'), '-o', str(payload), str(data / 'smt2_sbi_dual.S')]
    if run(compilation, out / 'payload-build.log') or run(
            ['riscv-none-elf-objcopy', '-O', 'binary', str(payload), str(binary)], out / 'objcopy.log'):
        raise RuntimeError('strict payload build failed')
    build = out / 'build'
    build.mkdir()
    command = ['make', '-C', str(source), f'O={build}', 'PLATFORM=generic',
               'FW_TEXT_START=0x80000000', 'FW_PAYLOAD_OFFSET=0x200000',
               f'FW_PAYLOAD_PATH={binary}', f'FW_FDT_PATH={dtb}', 'CROSS_COMPILE=riscv-none-elf-',
               'OPENSBI_ALLOW_NO_PIE=y', 'PLATFORM_RISCV_ISA=rv64imafdc_zicsr_zifencei', '-j8']
    (out / 'commands.json').write_text(json.dumps({'payload': compilation, 'firmware': command}, indent=2))
    if run(command, out / 'firmware-build.log'):
        raise RuntimeError('source OpenSBI build failed')
    elf = build / 'platform/generic/firmware/fw_payload.elf'
    record = {'upstreamCommit': '455de672dd7c2aa1992df54dfb08dc11abbc1b1a',
              'runnerSha256': sha(Path(__file__)),
              'archiveSha256': sha(archive), 'protectedSourceHashes': original_hashes,
              'platformPatchHashes': patch_hashes, 'dtsSha256': sha(data / 'ariane-smt2.dts'),
              'dtbSha256': sha(dtb), 'payloadSourceSha256': sha(data / 'smt2_sbi_dual.S'),
              'linkerSha256': sha(data / 'link.ld'), 'payloadSha256': sha(payload),
              'firmwareSha256': sha(elf), 'modelSha256': sha(model),
              'firmware': str(elf), 'payload': str(payload), 'model': str(model)}
    (out / 'profile.json').write_text(json.dumps(record, indent=2))
    return execute(model, record, out)


def execute(model, record, out):
    import resource

    elf, payload = Path(record['firmware']), Path(record['payload'])
    symbols = subprocess.check_output(['riscv-none-elf-nm', '-n', str(payload)], text=True)
    (out / 'payload-symbols.txt').write_text(symbols)
    addresses = re.findall(r'^([0-9a-fA-F]+)\s+\w\s+tohost$', symbols, re.M)
    if len(addresses) != 1:
        raise RuntimeError('strict payload must have one tohost')
    if os.environ.get('SOURCE_REVIEW_BUILD_ONLY') == '1':
        return 0
    if subprocess.run(['pgrep', '-af', '[/]Variane_testharness( |$)'], capture_output=True).returncode != 1:
        raise RuntimeError('another harness is active')
    resource.setrlimit(resource.RLIMIT_STACK, (resource.RLIM_INFINITY, resource.RLIM_INFINITY))
    trial = out / 'trial'
    trial.mkdir()
    cap = int(os.environ.get('SOURCE_REVIEW_CYCLES', '8000000'))
    env = {k: v for k, v in os.environ.items() if not k.startswith(('SOFT_', 'PEEL_', 'CVA6_', 'G6LC_'))}
    env.update(CVA6_COOKIE_EXIT='0', CVA6_SOAK_EXIT='0', CVA6_WFI_EXIT='0', CVA6_TRAP_DUMP='1')
    args = [str(model), '--seed=1', f'+max-cycles={cap}', f'+time_out={cap}',
            '+debug_disable', '+quiet_axi', '+smt_progress', '+tohost_addr=0x' + addresses[0], str(elf)]
    if os.environ.get('SOURCE_REVIEW_FLOW') == '1':
        args.insert(-1, '+smt_flow_trace')
    if os.environ.get('SOURCE_REVIEW_MEM_WATCH'):
        watch = int(os.environ['SOURCE_REVIEW_MEM_WATCH'], 0)
        if not 0 <= watch < 1 << 56:
            raise ValueError('invalid diagnostic physical address')
        args.insert(-1, f'+smt_mem_watch={watch:x}')
    wall = int(os.environ.get('SOURCE_REVIEW_WALL_SECONDS', '900'))
    if not 1 <= wall <= 3600:
        raise ValueError('wall budget must be between 1 and 3600 seconds')
    record.update(cycleBudget=cap, wallBudgetSeconds=wall, command=args)
    rc = run(['timeout', '--signal=TERM', '--kill-after=15s', f'{wall}s', *args], trial / 'run.log', trial, env, wall + 30)
    text = (trial / 'run.log').read_text(errors='replace')
    (trial / 'handoff.log').write_text('\n'.join(line for line in text.splitlines()
                                                if line.startswith(('[smt-flow] handoff', '[smt-flow] frontier', '[smt-flow] transport'))))
    (trial / 'memory.log').write_text('\n'.join(line for line in text.splitlines()
                                               if line.startswith(('[smt-flow] wt_', '[smt-flow] store_'))))
    progress = {int(h): int(n) for h, n in re.findall(r'\[smt-progress\].*hart=(\d+) retired=(\d+)', text)}
    trace = '\n'.join(p.read_text(errors='replace') for p in trial.glob('trace_rvfi_hart_*.dasm'))
    reference = os.environ.get('SOURCE_REVIEW_REFERENCE_TRACE')
    if reference:
        traces = list(trial.glob('trace_rvfi_hart_*.dasm'))
        if len(traces) != 1:
            raise RuntimeError('expected one physical-core trace')
        compared = 0
        reference_ended = False
        with Path(reference).open() as prior, traces[0].open() as current:
            for line in current:
                previous = prior.readline()
                if not previous and os.environ.get('SOURCE_REVIEW_EXTEND_REFERENCE') == '1':
                    reference_ended = True
                    break
                compared += 1
                if line != previous:
                    raise RuntimeError(f'retirement prefix changed at line {compared}')
        if os.environ.get('SOURCE_REVIEW_EXTEND_REFERENCE') == '1' and not reference_ended:
            raise RuntimeError('run did not extend the retained reference prefix')
        record['referencePrefix'] = {'path': reference, 'matchedLines': compared, 'extended': reference_ended}
    seen = re.findall(r'^([0-9a-fA-F]+)\s+\w\s+strict_seen$', symbols, re.M)
    passed = len(seen) == 1 and source_passed(rc, text, trace, progress,
                                            int(addresses[0], 16), int(seen[0], 16))
    record.update(rc=rc, strictDualPassed=passed, retiredByHart=progress,
                  pins=[line for line in text.splitlines() if line.startswith(('[hangpc]', '[smt-progress]'))],
                  elapsedVerdicts=re.findall(r'\*\*\* (?:SUCCESS|FAILED).*', text), logSha256=sha(trial / 'run.log'))
    (out / 'results.json').write_text(json.dumps(record, indent=2))
    if sha(model) != record['modelSha256'] or sha(elf) != record['firmwareSha256']:
        raise RuntimeError('profile changed during execution')
    print(json.dumps(record, indent=2))
    return 0 if passed else 1


if __name__ == '__main__':
    sys.exit(main())
