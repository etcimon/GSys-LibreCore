#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Bounded simulator-PGO workloads. Training is not validation evidence."""
from pathlib import Path
import re


def option(arguments, *names, default=None):
    result = default
    for index, argument in enumerate(arguments):
        if argument in names:
            if index + 1 == len(arguments):
                raise ValueError(f'missing value for {argument}')
            result = arguments[index + 1]
        else:
            for name in names:
                if argument.startswith(name + '='):
                    result = argument[len(name) + 1:]
    return result


def training_plan(root, top, arguments, mdir):
    root = Path(root)
    tb = root / 'verif/tb/apu'
    plan = {'cwd': str(tb), 'cases': [[]], 'files': [],
            'expect': r'^PASS ' + re.escape(top) + r'\b',
            'coverage': 'bounded directed self-test'}
    if top in ('tb_g6lc_apu_vgtop', 'tb_g6lc_apu_vgsys', 'tb_g6lc_apu_sys_venus'):
        sessions = ('ue_cpos_imm_copy_1', 'ue_gpos_fsubocopy_1')
        plan['cases'] = [['+vec=' + name, '+xf_ok'] for name in sessions]
        plan['files'] = [str(tb / 'vn_vectors' / (name + suffix))
                         for name in sessions for suffix in ('.hex', '.exp', '.json')]
        plan['coverage'] = 'two fixed compute/graphics descriptor-copy mechanisms'
    elif top == 'tb_g6lc_apu_shwave':
        vectors = tb / 'sh_vectors'
        plan['cases'] = [['+shv=' + str(vectors), '+only=ssbo_rowmajor_1']]
        plan['files'] = [str(p) for p in sorted(vectors.glob('ssbo_rowmajor*')) if p.is_file()]
        plan['coverage'] = 'one row-major shader mechanism'
        if not plan['files']:
            raise FileNotFoundError('missing row-major training vectors')
    elif top in ('tb_g6lc_apu_shcore', 'tb_g6lc_apu_shmod'):
        vectors = tb / 'sh_vectors'
        plan['cases'] = [['+shv=' + str(vectors)]]
        plan['files'] = [str(vectors / ('bufcopy_1' + suffix)) for suffix in ('.hex', '.exp')]
        plan['coverage'] = 'bounded existing shader-core/module directed self-test'
    elif top == 'tb_g6lc_apu_vnfront':
        session = 'ue_sm5_payfull' if '-GObjPayWords=512' in arguments else 'ue_sm5_session'
        plan['cases'] = [['+ses=' + session]]
        plan['files'] = [str(tb / 'vn_vectors' / (session + suffix))
                         for suffix in ('.hex', '.exp')]
    elif top == 'tb_g6lc_apu_bridge':
        plan.update(cases=[['--bench', '2000']], expect=r'^\[bridge\] [0-9.]+ kHz',
                    files=[str(Path(mdir).parent / name)
                           for name in ('bridge_map.h', 'vn_map.svh')],
                    coverage='idle bridge only; no guest/shader performance claim')
    elif top == 'tb_g6lc_apu_cva6_venus':
        plan.update(cwd=str(mdir), cases=[[], ['+venusoff']],
                    files=[str(Path(mdir) / name) for name in ('venus_probe.hex', 'vn_map.svh')],
                    coverage='bare-metal probe, both Venus enable arms')
    elif top == 'tb_g6lc_sim_pgo_probe':
        plan['cwd'] = str(root)
        plan['coverage'] = 'compiler infrastructure probe, not APU RTL qualification'
    elif not top.startswith('tb_g6lc_apu_'):
        raise ValueError(f'no bounded simulator PGO workload for {top}')
    for name in plan['files']:
        if not Path(name).is_file():
            raise FileNotFoundError(name)
    return plan


def training_passed(text, expect):
    if re.search(r'^(FAIL\b|FATAL\b|%Error|%Fatal|BLOCKED\b|INCOMPLETE\b)', text, re.M):
        return False
    if not re.search(expect, text, re.M):
        return False
    for line in text.splitlines():
        if line.startswith('PASS '):
            checks = re.search(r'\bchecks=(\d+)', line)
            if checks and int(checks[1]) == 0:
                return False
    return True
