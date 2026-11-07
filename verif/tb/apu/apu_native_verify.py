#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Offline frozen-source native cohort; --check only checks presence."""
import argparse
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[3]
TOOLS = Path('corev_apu/apu/tools')
MODULES = ('test_vn_dma', 'test_vn_dma_resources', 'test_vn_resource_lifetime',
           'test_vn_control', 'test_vn_control_queue', 'test_vn_native',
           'test_vn_native_bridge', 'test_vn_execution', 'test_vn_rings',
           'test_vn_continuations', 'test_vn_dependencies', 'test_vn_transfers',
           'test_vn_replay', 'test_vn_submit', 'test_vn_semaphores', 'test_vn_timelines',
           'test_vn_timeline_jobs', 'test_vn_verify_status', 'test_vn_images',
           'test_vn_image_barriers', 'test_vn_image_clear', 'test_vn_compute',
           'test_vn_descriptor_operands', 'test_vn_native_layouts', 'test_vn_native_pipelines',
           'test_vn_compute_replay', 'test_vn_compute_submit', 'test_vn_specialization',
           'test_vn_compute_barriers', 'test_vn_idle', 'test_vn_indirect',
           'test_vn_buffer_arrays', 'test_vn_image_operands', 'test_vn_compute_images',
           'test_vn_shader_image_barriers', 'test_vn_native_rendering', 'test_vn_graphics_pipelines',
           'test_vn_graphics_state', 'test_vn_graphics_interfaces', 'test_vn_vertex_operands',
           'test_vn_graphics_dynamic', 'test_vn_render_pass_commands', 'test_vn_graphics_resources',
           'test_vn_graphics_bindings', 'test_vn_graphics_draws',
           'test_vn_render_pass_clear', 'test_vn_graphics_fetch',
           'test_vn_graphics_shade', 'test_vn_graphics_pshade',
           'test_vn_graphics_raster', 'test_vn_graphics_writeback',
           'test_vn_graphics_drawexec', 'test_vn_graphics_draw_replay',
           'test_vn_graphics_barriers', 'test_vn_events', 'test_vn_queries',
           'test_vn_semaphore_resource')
NATIVE = ('vn_native_execution.py', 'vn_borrowed_memory.py', 'vn_memory_blobs.py',
          'vn_native_device.py', 'vn_native_bridge.py', 'native_test_wire.py',
          'vn_rings.py', 'vn_ring_scheduler.py', 'vn_stream_task.py', 'vn_deferred.py',
          'vn_stream_group.py', 'vn_transfer_executor.py', 'vn_transfer_replay.py',
          'vn_native_submit.py', 'vn_binary_semaphores.py', 'vn_timeline_semaphores.py',
          'vn_timeline_jobs.py', 'vn_image_replay.py', 'vn_image_barriers.py',
          'vn_compute.py', 'vn_descriptor_operands.py', 'vn_image_operands.py', 'vn_native_layouts.py',
          'vn_native_pipelines.py', 'vn_compute_replay.py', 'vn_specialization.py',
          'vn_native_rendering.py', 'vn_graphics_pipelines.py', 'vn_graphics_state.py',
          'vn_graphics_interfaces.py', 'vn_vertex_operands.py', 'vn_graphics_dynamic.py',
          'vn_render_pass_commands.py', 'vn_graphics_resources.py', 'vn_graphics_bindings.py',
          'vn_graphics_draws.py', 'vn_render_pass_replay.py',
          'vn_graphics_fetch.py', 'vn_graphics_shade.py',
          'vn_graphics_pshade.py', 'vn_graphics_raster.py',
          'vn_graphics_writeback.py', 'vn_graphics_drawexec.py',
          'vn_graphics_draw_replay.py', 'vn_event_replay.py',
          'vn_query_replay.py')
CLIENT = Path('verif/tb/apu/bridge/bridge_selftest.py')
MAP = Path('software/apu-venus-probe/venus_map.h')


def inputs(root):
    required = [TOOLS / name for name in NATIVE]
    required += [TOOLS / (name + '.py') for name in MODULES]
    required += [CLIENT, MAP, Path('verif/tb/apu/apu_native_verify.py')]
    patterns = {TOOLS: ('*.py', '*.toml', '*.txt'),
                TOOLS / 'shader': ('*.py',),
                Path('specs/venus-protocol'): ('*.py',),
                Path('specs/venus-protocol/xmls'):
                    ('vk.xml', 'VK_EXT_command_serialization.xml', 'VK_MESA_venus_protocol.xml')}
    for directory, globs in patterns.items():
        if not (root / directory).is_dir():
            raise FileNotFoundError(str(root / directory))
        for pattern in globs:
            matches = sorted((root / directory).glob(pattern))
            if not matches:
                raise FileNotFoundError(str(root / directory / pattern))
            required.extend(path.relative_to(root) for path in matches if path.is_file())
    for relative in required:
        if not (root / relative).is_file():
            raise FileNotFoundError(str(root / relative))
    if sys.version_info < (3, 11) or importlib.util.find_spec('mako') is None:
        raise RuntimeError('native execution requires Python3.11+ and existing Mako; no downloads')
    return sorted(set(required))


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def result_status(returncode, tests, text):
    if (returncode or not tests or 'ResourceWarning:' in text or
            'Exception ignored in:' in text):
        return 'FAIL'
    return 'PASS'


def run(root, parent, timeout):
    sources = inputs(root)
    parent.mkdir(parents=True, exist_ok=True)
    destination = Path(tempfile.mkdtemp(prefix='native-execution.', dir=parent))
    hashes = {}
    for relative in sources:
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        data = (root / relative).read_bytes()
        target.write_bytes(data)
        hashes[str(relative)] = hashlib.sha256(data).hexdigest()
    tools = destination / TOOLS
    shutil.copy2(destination / CLIENT, tools / 'bridge_client_fixture.py')
    shutil.copy2(destination / MAP, tools / 'venus_map.h')
    for name in ('bridge_client_fixture.py', 'venus_map.h'):
        hashes[str(TOOLS / name)] = digest(tools / name)
    summary = {'kind': 'host-native-model', 'status': 'INCOMPLETE',
               'source_sha256': hashes, 'timeout': timeout,
               'python': sys.version, 'python_sha256': digest(Path(sys.executable)),
               'runner_sha256': digest(Path(__file__)), 'test_modules': MODULES}
    (destination / 'manifest.json').write_text(json.dumps(summary, indent=2))
    print('FROZEN NATIVE COHORT ' + str(destination), flush=True)
    start = time.monotonic()
    with tempfile.TemporaryDirectory(prefix='g6lc-nv-') as scratch:
        process = subprocess.Popen(
            [sys.executable, '-B', '-W', 'error::ResourceWarning', '-m', 'unittest', *MODULES],
            cwd=tools, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            env={**os.environ, 'TMPDIR': scratch}, start_new_session=os.name == 'posix')
        try:
            stdout, stderr = process.communicate(timeout=timeout)
            text = stdout + stderr
            summary['returncode'] = process.returncode
            match = re.search(r'Ran (\d+) tests? in ', text)
            summary['tests'] = int(match.group(1)) if match else 0
            summary['status'] = result_status(process.returncode, summary['tests'], text)
        except subprocess.TimeoutExpired:
            # The cohort owns this process group, including native CLI children.
            if os.name == 'posix':
                os.killpg(process.pid, signal.SIGKILL)
            else:
                process.kill()
            stdout, stderr = process.communicate()
            text = stdout + stderr + '\nNATIVE COHORT TIMEOUT\n'
    summary['elapsed_seconds'] = time.monotonic() - start
    summary['sources_unchanged'] = all(digest(destination / name) == value
                                       for name, value in hashes.items())
    if not summary['sources_unchanged']:
        summary['status'] = 'INCOMPLETE'
    (destination / 'test.log').write_text(text)
    (destination / 'summary.json').write_text(json.dumps(summary, indent=2))
    print(text, end='')
    print(summary['status'] + ': host-native-model; no RTL/CTS qualification')
    return 0 if summary['status'] == 'PASS' else 4 if summary['status'] == 'INCOMPLETE' else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--output-parent', type=Path,
                        default=Path.home() / '.cache/librecore/apu')
    parser.add_argument('--timeout', type=float, default=60)
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error('timeout must be finite and positive')
    if args.check:
        print('NATIVE INPUTS OK files=%d (no snapshot/build/training/tests)' % len(inputs(ROOT)))
        return 0
    return run(ROOT, args.output_parent, args.timeout)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, RuntimeError) as error:
        print('NATIVE COHORT INCOMPLETE: ' + str(error), file=sys.stderr)
        sys.exit(4)
