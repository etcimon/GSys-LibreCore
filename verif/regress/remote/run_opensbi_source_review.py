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
import shlex
import subprocess
import sys
import tarfile


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def run(command, log, cwd=None, env=None, timeout=300):
    with log.open('w') as output:
        result = subprocess.run(command, cwd=cwd, env=env, stdout=output,
                                stderr=subprocess.STDOUT, timeout=timeout)
    return result.returncode


def source_passed(rc, log, trace, progress, tohost, seen):
    pattern = re.compile(r'^1 .*\bmem (0x[0-9a-fA-F]+) (0x[0-9a-fA-F]+)')
    lines = trace.splitlines() if isinstance(trace, str) else trace
    required = {tohost, seen, seen + 8}
    observed = set()
    for line in lines:
        match = pattern.match(line)
        if match and int(match[2], 16) == 1 and int(match[1], 16) in required:
            observed.add(int(match[1], 16))
    return (rc == 0 and '[rvfi_tracer] INFO: Simulation terminated' in log
            and progress.get(0, 0) > 0 and progress.get(1, 0) > 0
            and len(required) == 3 and required <= observed)


def validate_model_manifest(manifest, observed_hash, experimental):
    hashes = [manifest[key] for key in ('executableSha256', 'modelSha256') if key in manifest]
    target = manifest.get('target')
    # A sibling target (same SoC profile, different backend) is admitted only
    # as an experimental model; its manifest is a plain unsubstituted one.
    sibling = target in EXPERIMENTAL_TARGETS
    if not hashes or any(value != observed_hash for value in hashes) or (target != 'g6lc64_smt2' and not sibling):
        raise ValueError('model identity mismatch or conflicting executable hashes')
    sources = manifest.get('sources')
    if not isinstance(sources, dict) or not sources:
        raise ValueError('model source evidence is missing')
    qualification = manifest.get('qualificationOnly', False)
    if not isinstance(qualification, bool):
        raise ValueError('qualificationOnly must be boolean')
    reviewed = 'modelSha256' in manifest or qualification or any(isinstance(v, dict) for v in sources.values())
    if experimental != (reviewed or sibling):
        raise ValueError('experimental mode and model provenance disagree')
    if reviewed:
        if not qualification or manifest.get('harts') != 2 or manifest.get('rc') != 0:
            raise ValueError('experimental model must be a successful two-hart qualification build')
        for entry in sources.values():
            if not isinstance(entry, dict) or any(
                not isinstance(entry.get(key), str) or not re.fullmatch(r'[0-9a-f]{64}', entry[key])
                for key in ('originalSha256', 'reviewSha256')):
                raise ValueError('incomplete experimental source hashes')
    elif any(not isinstance(v, str) or not re.fullmatch(r'[0-9a-f]{64}', v) for v in sources.values()):
        raise ValueError('invalid default source hashes')
    return {'experimentalModel': experimental, 'protectedAnchor': not experimental,
            'modelQualificationOnly': qualification, 'modelHarts': manifest.get('harts'),
            'modelTarget': target, 'modelSourceHashes': sources}


def source_outcome(rc, text, passed, cap):
    if cap <= 0:
        raise ValueError('cycle budget must be positive')
    verdicts = re.findall(r'\*\*\* (SUCCESS|FAILED) \*\*\* \(tohost = (0x[0-9a-fA-F]+|[0-9]+)\) after ([0-9]+) cycles', text)
    if rc < 0 or re.search(r'%Error|Assertion failed|Aborting', text):
        return 'error'
    if rc == 124:
        return 'timeout'
    if len(verdicts) != 1:
        return 'error'
    status, value, cycles = verdicts[0]
    if status == 'FAILED' or int(value, 16 if value.startswith('0x') else 10):
        return 'fail'
    if rc != 0:
        return 'error'
    if int(cycles) >= cap:
        return 'timeout'
    return 'pass' if passed else 'incomplete'


EXPECTED_COMPILER_CONTROL_SHA256 = 'be176b279ada076a3459d8bd6509e0946ccf0994d5c35a092bede308bba8c8ff'
EXPECTED_COMPILER_CONTROL_NAME = 'split-counter.vlt'
# Sibling targets of the protected g6lc64_smt2 profile that may run the same
# firmware as EXPERIMENTAL models only (SOURCE_REVIEW_EXPERIMENTAL=1).
EXPERIMENTAL_TARGETS = frozenset({'g6lc64_smt2_ooo_int'})


def compiler_control_failures(control, verfiles, exists, digest, waive):
    """Failed mandatory compiler-control checks for a protected-anchor run.

    All three must hold: the control is supplied and present on disk, its
    sha256 is the pinned qualified value, and its basename appears in the
    model's generated ``Variane_testharness__verFiles.dat``.
    """
    if waive:
        return []
    failures = []
    if not control or not exists:
        failures.append('control-supplied-and-present')
    if not (isinstance(digest, str) and digest == EXPECTED_COMPILER_CONTROL_SHA256):
        failures.append('control-sha256-mismatch')
    commands = re.findall(r'^C "(.*)"$', verfiles, re.M)
    inputs = set(re.findall(r'^S\s+[^\n]*"([^"\n]+)"$', verfiles, re.M))
    try:
        tokens = shlex.split(commands[0]) if len(commands) == 1 else []
    except ValueError:
        tokens = []
    if not control or control not in tokens or control not in inputs:
        failures.append('control-absent-from-verfiles')
    return failures


def apply_control_waiver(provenance, waived):
    """A caller-supplied waiver suppresses the refusal but forfeits the anchor."""
    if provenance.get('protectedAnchor') and waived:
        provenance['protectedAnchor'] = False
        provenance['controlWaived'] = True


def refuse(model, out, provenance, failures, control, digest):
    record = {'model': str(model), 'modelSha256': sha(model),
              'runnerSha256': sha(Path(__file__)),
              'outcome': 'refused', 'timedOut': False, 'strictDualPassed': False,
              'simulationStarted': False,
              'refusedChecks': failures,
              'expectedCompilerControl': {'name': EXPECTED_COMPILER_CONTROL_NAME,
                                          'sha256': EXPECTED_COMPILER_CONTROL_SHA256}}
    record.update(provenance)
    if control:
        record['compilerControl'] = {'path': control, 'sha256': digest}
    (out / 'results.json').write_text(json.dumps(record, indent=2))
    print(json.dumps(record, indent=2))
    return 2


def termination_path(rc, text, cap):
    """Name the mechanism that ended the simulation, for outlier triage."""
    if re.search(r'Assertion failed|\$stop', text):
        return 'assertion-$stop'
    if rc == 124:
        return 'wall-budget'
    if '[rvfi_tracer] INFO: Simulation terminated' in text:
        return 'tracer'
    cycles = re.search(r'after ([0-9]+) cycles', text)
    if cycles and int(cycles.group(1)) >= cap:
        return 'cycle-budget'
    return 'unknown'


def main():
    out = Path(os.environ['TH_OUT_DIR'])
    data = Path(os.environ['TH_DATA_DIR'])
    shutil.copy2(Path(__file__), out / 'runner.py')
    for tool in ('riscv-none-elf-gcc', 'riscv-none-elf-objcopy', 'make', 'dtc'):
        if not shutil.which(tool):
            raise RuntimeError(f'missing provisioned tool: {tool}')
    model = Path(os.environ['SOURCE_REVIEW_MODEL'])
    manifests = [data / name for name in ('build-manifest.json', 'build-review.json') if (data / name).is_file()]
    if len(manifests) != 1:
        raise RuntimeError('exactly one model provenance record is required')
    manifest = json.loads(manifests[0].read_text())
    # The identity binding is mandatory in every mode: the measured executable must
    # be the one the manifest attests. Isolated qualification builds record that
    # hash as 'modelSha256' rather than 'executableSha256', so both names are
    # accepted -- but only the hash comparison decides, never the field name.
    attested = manifest.get('executableSha256') or manifest.get('modelSha256')
    # The protected anchor is the g6lc64_smt2 build. A sibling target that
    # keeps the same SoC profile but changes the backend (the integer OoO
    # variant of T6a) may run the same firmware, but only as an EXPERIMENTAL
    # model: it never carries the anchor claim and its target is recorded.
    target = manifest.get('target')
    experimental_target = target in EXPERIMENTAL_TARGETS
    if attested != sha(model) or (target != 'g6lc64_smt2' and not experimental_target):
        raise RuntimeError('source-profile model identity mismatch')
    # A qualification build may substitute sources (for example to relax a config
    # legality guard). Such a model is NOT the protected source-profile anchor, and
    # a boot measured on it must never be presented as one. Rather than rejecting
    # it outright, admit it only when the caller asks for it explicitly, and carry
    # the substitution evidence into the result so the distinction survives.
    substitutions = sorted(
        name for name, entry in (manifest.get('sources') or {}).items()
        if isinstance(entry, dict) and entry.get('reviewSha256')
        and entry.get('reviewSha256') != entry.get('originalSha256'))
    qualification_only = bool(manifest.get('qualificationOnly'))
    experimental = os.environ.get('SOURCE_REVIEW_EXPERIMENTAL') == '1'
    if (substitutions or qualification_only or experimental_target) and not experimental:
        raise RuntimeError('substituted qualification model requires '
                           'SOURCE_REVIEW_EXPERIMENTAL=1')
    if experimental and not (substitutions or qualification_only or experimental_target):
        raise RuntimeError('experimental mode demanded but the manifest attests an '
                           'unsubstituted model')
    provenance = {'experimentalModel': experimental,
                  'protectedAnchor': not experimental,
                  'modelQualificationOnly': qualification_only,
                  'modelTarget': target,
                  'modelHarts': manifest.get('harts'),
                  'modelSubstitutions': substitutions}
    provenance.update(validate_model_manifest(manifest, sha(model), experimental))
    provenance['modelManifestSha256'] = sha(manifests[0])
    verfiles_path = model.parent / 'Variane_testharness__verFiles.dat'
    verfiles = verfiles_path.read_text() if verfiles_path.is_file() else ''
    provenance['generatedInputs'] = {
        'path': str(verfiles_path), 'sha256': sha(verfiles_path) if verfiles_path.is_file() else None,
        'commands': re.findall(r'^C "(.*)"$', verfiles, re.M),
        'sourceEntries': len(re.findall(r'^S\s+', verfiles, re.M))}
    provenance['buildRecipeAttested'] = isinstance(manifest.get('recipe'), dict)
    control = os.environ.get('SOURCE_REVIEW_COMPILER_CONTROL')
    waive = os.environ.get('SOURCE_REVIEW_ALLOW_MISSING_CONTROL') == '1'
    provenance['controlWaived'] = False
    # A protected-anchor measurement must be recipe-bound before the simulator
    # launches: the qualified compiler control has to be supplied, hash-pinned
    # and present in the model's generated input list. A caller may waive the
    # check only by forfeiting the anchor claim for that run.
    apply_control_waiver(provenance, waive)
    if provenance['protectedAnchor']:
        control_file = Path(control) if control else None
        exists = bool(control_file and control_file.is_file())
        digest = sha(control_file) if exists else None
        failures = compiler_control_failures(control, verfiles, exists, digest, False)
        if failures:
            return refuse(model, out, provenance, failures, control, digest)
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
        record.update(provenance)
        record['buildRecipe'] = manifest.get('recipe')
        if control:
            record['compilerControl'] = {'path': control, 'sha256': sha(control_path)}
        (out / 'profile.json').write_text(json.dumps(record, indent=2))
        return execute(model, record, out)
    if experimental:
        raise RuntimeError('experimental models must reuse a frozen source profile')
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
    record.update(provenance)
    record['buildRecipe'] = manifest.get('recipe')
    (out / 'profile.json').write_text(json.dumps(record, indent=2))
    return execute(model, record, out)


def compare_reference(reference, current, extend=False):
    result = {'path': str(reference), 'sha256': sha(reference), 'matchedLines': 0,
              'extended': False, 'status': 'fail', 'independentArchitecturalOracle': False}
    with reference.open() as prior, current.open() as trial:
        while True:
            expected, actual = prior.readline(), trial.readline()
            if not expected and not actual:
                if result['matchedLines'] and not extend:
                    result['status'] = 'pass'
                break
            if not expected and actual and extend and result['matchedLines']:
                result.update(status='pass', extended=True)
                break
            if expected != actual:
                result.update(expected=expected.rstrip('\n')[:512], actual=actual.rstrip('\n')[:512])
                break
            result['matchedLines'] += 1
    if result['status'] != 'pass':
        result['mismatchLine'] = result['matchedLines'] + 1
    return result


def trial_verdict(rc, text, traces, symbols, cap, reference=None, extend=False):
    progress = {int(h): int(n) for h, n in re.findall(r'\[smt-progress\].*hart=(\d+) retired=(\d+)', text)}
    addresses = re.findall(r'^([0-9a-fA-F]+)\s+\w\s+tohost$', symbols, re.M)
    seen = re.findall(r'^([0-9a-fA-F]+)\s+\w\s+strict_seen$', symbols, re.M)

    def lines():
        for trace in traces:
            with trace.open(errors='replace') as source:
                yield from source

    passed = len(addresses) == len(seen) == len(traces) == 1 and source_passed(
        rc, text, lines(), progress, int(addresses[0], 16), int(seen[0], 16))
    outcome = source_outcome(rc, text, passed, cap)
    result = {'rc': rc, 'outcome': outcome, 'timedOut': outcome == 'timeout',
              'strictDualPassed': outcome == 'pass', 'retiredByHart': progress,
              'tracerTerminated': '[rvfi_tracer] INFO: Simulation terminated' in text,
              'terminationPath': termination_path(rc, text, cap),
              'pins': [line for line in text.splitlines() if line.startswith(('[hangpc]', '[smt-progress]'))],
              'elapsedVerdicts': re.findall(r'\*\*\* (?:SUCCESS|FAILED).*', text)}
    if reference:
        try:
            if len(traces) != 1:
                raise ValueError('expected one physical-core trace')
            comparison = compare_reference(Path(reference), traces[0], extend)
        except (OSError, ValueError) as error:
            comparison = {'path': str(reference), 'status': 'error', 'error': str(error),
                          'independentArchitecturalOracle': False}
        result['referencePrefix'] = comparison
        if comparison['status'] != 'pass':
            result['strictDualPassed'] = False
            if outcome == 'pass':
                result['outcome'] = comparison['status']
    return result


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
    if cap <= 0:
        raise ValueError('cycle budget must be positive')
    record.update(cycleBudget=cap, wallBudgetSeconds=wall, command=args,
                  simulationStarted=False, outcome='incomplete', strictDualPassed=False,
                  simulationEnvironment={key: env[key] for key in sorted(env)
                                         if key.startswith(('CVA6_', 'G6LC_', 'SOFT_', 'PEEL_'))})
    (out / 'invocation.json').write_text(json.dumps(record, indent=2))
    record['simulationStarted'] = True
    (out / 'results.json').write_text(json.dumps(record, indent=2))
    try:
        rc = run(['timeout', '--signal=TERM', '--kill-after=15s', f'{wall}s', *args], trial / 'run.log', trial, env, wall + 30)
    except subprocess.TimeoutExpired:
        rc = 124
    except OSError as error:
        record.update(outcome='error', strictDualPassed=False, executionError=str(error))
        (out / 'results.json').write_text(json.dumps(record, indent=2))
        return 1
    text = (trial / 'run.log').read_text(errors='replace')
    (trial / 'handoff.log').write_text('\n'.join(line for line in text.splitlines()
                                                if line.startswith(('[smt-flow] handoff', '[smt-flow] frontier', '[smt-flow] transport'))))
    (trial / 'memory.log').write_text('\n'.join(line for line in text.splitlines()
                                               if line.startswith(('[smt-flow] wt_', '[smt-flow] store_'))))
    traces = sorted(trial.glob('trace_rvfi_hart_*.dasm'))
    record.update(trial_verdict(rc, text, traces, symbols, cap,
                               os.environ.get('SOURCE_REVIEW_REFERENCE_TRACE'),
                               os.environ.get('SOURCE_REVIEW_EXTEND_REFERENCE') == '1'))
    record['logSha256'] = sha(trial / 'run.log')
    if sha(model) != record['modelSha256'] or sha(elf) != record['firmwareSha256']:
        record.update(outcome='error', strictDualPassed=False,
                      identityError='profile changed during execution')
    (out / 'results.json').write_text(json.dumps(record, indent=2))
    print(json.dumps(record, indent=2))
    return 0 if record['outcome'] == 'pass' else 1


if __name__ == '__main__':
    sys.exit(main())
