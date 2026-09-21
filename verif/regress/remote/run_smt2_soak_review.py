"""Source-bound, sequential SMT2 soak evidence; no implicit build or firmware edits.

Copyright (c) 2026 Etienne Cimon
SPDX-License-Identifier: MIT
"""

from collections import deque
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def capture(command):
    result = subprocess.run(command, capture_output=True, text=True, timeout=30)
    return {'rc': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr}


def check_fetch_b_sources(verfiles):
    if re.search(r'[/\\](?:fetch_A|smt_legacy)[/\\]|Flist\.smt_legacy', verfiles):
        raise RuntimeError('generated model includes an excluded legacy source path')
    if '/core/fetch_B/frontend.sv' not in verfiles.replace('\\', '/'):
        raise RuntimeError('generated model does not record the fetch_B frontend')


def balance_metrics(flow, symbols, active_harts=(0, 1), iterations=512):
    active = set(active_harts)
    if not active or not active <= {0, 1} or iterations <= 0:
        raise ValueError('invalid balance configuration')
    begin = {symbols[f'balance_begin{h}']: h for h in (0, 1)}
    end = {symbols[f'balance_end{h}']: h for h in (0, 1)}
    events = {h: [] for h in active}
    starts, ends, seen = {}, {}, set()
    last_cycle = -1
    pattern = re.compile(r'^\[smt-flow\] retire cycle=(\d+) port=(\d+) id=\d+ gen=\d+ '
                         r'hart=(\d+) pc=([0-9a-fA-F]+) valid=([01]) drop=([01]) ex=([01])$')
    for line in flow.splitlines():
        if not line.startswith('[smt-flow] retire '):
            continue
        match = pattern.fullmatch(line)
        if not match:
            raise ValueError('malformed retirement event')
        cycle, port, hart = map(int, match.group(1, 2, 3))
        pc = int(match[4], 16)
        if cycle < last_cycle or (cycle, port) in seen or hart not in (0, 1):
            raise ValueError('invalid retirement order, duplicate or hart')
        seen.add((cycle, port))
        last_cycle = cycle
        if match.group(5, 6, 7) != ('1', '0', '0'):
            continue
        if pc in begin or pc in end:
            owner = begin[pc] if pc in begin else end[pc]
            target = starts if pc in begin else ends
            if owner != hart or hart not in active or hart in target:
                raise ValueError('ROI marker ownership or multiplicity')
            target[hart] = cycle
        if symbols['balance_loop'] <= pc < symbols['balance_loop_end']:
            if hart not in active or hart not in starts or hart in ends:
                raise ValueError('work retired outside its owned ROI')
            events[hart].append((cycle, pc))
    if set(starts) != active or set(ends) != active:
        raise ValueError('missing ROI markers')
    expected_pcs = [symbols[name] for name in ('balance_loop', 'balance_xor', 'balance_dec', 'balance_branch')] * iterations
    for h in active:
        if ends[h] <= starts[h] or [pc for _, pc in events[h]] != expected_pcs:
            raise ValueError('incomplete, duplicated or reordered fixed work')
    left, right = max(starts.values()), min(ends.values())
    if right <= left:
        raise ValueError('no simultaneous-work interval')
    common = {h: [c for c, _ in events[h] if left <= c <= right] for h in active}
    if any(not cycles for cycles in common.values()):
        raise ValueError('no useful service for an active worker')
    total = sum(map(len, common.values()))
    durations = {h: ends[h] - starts[h] + 1 for h in active}
    return {'activeHarts': sorted(active), 'iterations': iterations,
            'roiCycles': durations, 'bodyRetirements': {h: len(events[h]) for h in active},
            'commonWindow': [left, right], 'commonCycles': right - left + 1,
            'commonBodyRetirements': {h: len(c) for h, c in common.items()},
            'commonRetirementShare': {h: len(c) / total for h, c in common.items()},
            'maxCommonRetirementGap': {h: max(b - a for a, b in zip(
                [left, *cycles], [*cycles, right])) for h, cycles in common.items()},
            'bodyIPC': {h: len(events[h]) / durations[h] for h in active},
            'saturationQualified': False, 'boundedFairnessProven': False,
            'scope': 'checked fixed-work retirement service, not cycle-by-cycle readiness or Linux'}


ASYM_BODIES = {'compute': ('asym_cmp_add', 'asym_cmp_xor', 'asym_cmp_dec', 'asym_cmp_branch'),
               'memory': ('asym_mem_load', 'asym_mem_add', 'asym_mem_step',
                          'asym_mem_dec', 'asym_mem_branch'),
               # dep chains three multiplies through one register; ind does the same
               # instruction count with independent destinations.
               'dep': ('asym_dep_a', 'asym_dep_b', 'asym_dep_c',
                       'asym_dep_d', 'asym_dep_br'),
               'ind': ('asym_ind_a', 'asym_ind_b', 'asym_ind_c',
                       'asym_ind_d', 'asym_ind_br')}
ASYM_ITERATIONS = {'compute': 512, 'memory': 64, 'dep': 512, 'ind': 512}
ASYM_RESULTS = {'compute': 512, 'memory': 2016, 'dep': 1, 'ind': 512}


def set_memory_depth(iterations):
    """Retarget the memory role for a miss-depth sweep point."""
    if not 1 <= iterations <= 256:
        raise ValueError('memory depth outside the seeded buffer')
    ASYM_ITERATIONS['memory'] = iterations
    ASYM_RESULTS['memory'] = iterations * (iterations - 1) // 2
    return ASYM_RESULTS['memory']


def asym_metrics(flow, symbols, roles):
    """Asymmetric-role service: each hart has its own expected body sequence."""
    if not roles or set(roles) - {0, 1} or set(roles.values()) - set(ASYM_BODIES):
        raise ValueError('invalid asymmetric role assignment')
    begin = {symbols[f'asym_begin{h}']: h for h in (0, 1)}
    end = {symbols[f'asym_end{h}']: h for h in (0, 1)}
    expected = {h: [symbols[n] for n in ASYM_BODIES[role]] * ASYM_ITERATIONS[role]
                for h, role in roles.items()}
    # Key on the roles this binary actually contains, not on the assigned ones:
    # the other pairing's symbols are absent, but an unassigned role compiled into
    # THIS binary must still be recognised so executing it cannot pass unnoticed.
    body_role = {pc: role for role, names in ASYM_BODIES.items()
                 if names[0] in symbols and names[-1] in symbols
                 for pc in range(symbols[names[0]], symbols[names[-1]] + 1)}
    events = {h: [] for h in roles}
    starts, ends, seen = {}, {}, set()
    last_cycle = -1
    pattern = re.compile(r'^\[smt-flow\] retire cycle=(\d+) port=(\d+) id=\d+ gen=\d+ '
                         r'hart=(\d+) pc=([0-9a-fA-F]+) valid=([01]) drop=([01]) ex=([01])$')
    for line in flow.splitlines():
        if not line.startswith('[smt-flow] retire '):
            continue
        match = pattern.fullmatch(line)
        if not match:
            raise ValueError('malformed retirement event')
        cycle, port, hart = map(int, match.group(1, 2, 3))
        pc = int(match[4], 16)
        if cycle < last_cycle or (cycle, port) in seen or hart not in (0, 1):
            raise ValueError('invalid retirement order, duplicate or hart')
        seen.add((cycle, port))
        last_cycle = cycle
        if match.group(5, 6, 7) != ('1', '0', '0'):
            continue
        if pc in begin or pc in end:
            marker = begin[pc] if pc in begin else end[pc]
            target = starts if pc in begin else ends
            if marker != hart or hart not in roles or hart in target:
                raise ValueError('ROI marker ownership or multiplicity')
            target[hart] = cycle
        if pc in body_role:
            if roles.get(hart) != body_role[pc] or hart not in starts or hart in ends:
                raise ValueError('role body retired by the wrong hart or outside its ROI')
            events[hart].append(pc)
    if set(starts) != set(roles) or set(ends) != set(roles):
        raise ValueError('missing ROI markers')
    for hart in roles:
        if ends[hart] <= starts[hart] or events[hart] != expected[hart]:
            raise ValueError('incomplete, duplicated or reordered role work')
    duration = {h: ends[h] - starts[h] + 1 for h in roles}
    left, right = max(starts.values()), min(ends.values())
    core_left, core_right = min(starts.values()), max(ends.values())
    return {'roles': {h: roles[h] for h in sorted(roles)},
            'roiWindows': {h: [starts[h], ends[h]] for h in roles},
            'coreWindow': [core_left, core_right], 'coreWindowCycles': core_right - core_left + 1,
            'coreBodyRetirements': sum(map(len, events.values())),
            'roiCycles': duration, 'bodyRetirements': {h: len(events[h]) for h in roles},
            'cyclesPerIteration': {h: duration[h] / ASYM_ITERATIONS[roles[h]] for h in roles},
            'commonWindow': [left, right] if right > left else None,
            'overlapCycles': max(0, right - left + 1),
            'saturationQualified': False,
            'scope': 'checked per-role work and its own completion time; overlap is '
                     'observed, and independent strided loads permit concurrency'}


LOCK_BODY = ('lock_loop', 'lock_dec', 'lock_branch')
LOCK_ITERATIONS = 512
IPI_BODY = ('ipi_loop', 'ipi_dec', 'ipi_branch')
IPI_ITERATIONS = 512


def ipi_metrics(flow, symbols, peer_halted):
    """Hart0's measured body while the peer is halted in WFI awaiting an IPI."""
    begin, end = symbols['ipi_begin0'], symbols['ipi_end0']
    expected = [symbols[n] for n in IPI_BODY] * IPI_ITERATIONS
    body = range(symbols[IPI_BODY[0]], symbols[IPI_BODY[-1]] + 1)
    events, start, stop, seen = [], None, None, set()
    peer_body = 0
    last_cycle = -1
    pattern = re.compile(r'^\[smt-flow\] retire cycle=(\d+) port=(\d+) id=\d+ gen=\d+ '
                         r'hart=(\d+) pc=([0-9a-fA-F]+) valid=([01]) drop=([01]) ex=([01])$')
    for line in flow.splitlines():
        if not line.startswith('[smt-flow] retire '):
            continue
        match = pattern.fullmatch(line)
        if not match:
            raise ValueError('malformed retirement event')
        cycle, port, hart = map(int, match.group(1, 2, 3))
        pc = int(match[4], 16)
        if cycle < last_cycle or (cycle, port) in seen or hart not in (0, 1):
            raise ValueError('invalid retirement order, duplicate or hart')
        seen.add((cycle, port))
        last_cycle = cycle
        if match.group(5, 6, 7) != ('1', '0', '0'):
            continue
        if pc in body and hart == 1:
            peer_body += 1
        if hart != 0:
            continue
        if pc == begin:
            if start is not None:
                raise ValueError('duplicate region marker')
            start = cycle
        if pc == end:
            if start is None or stop is not None:
                raise ValueError('region end without a single matching start')
            stop = cycle
        if pc in body:
            if start is None or stop is not None:
                raise ValueError('measured work outside its own region')
            events.append(pc)
    if start is None or stop is None or stop <= start or events != expected:
        raise ValueError('incomplete, duplicated or reordered measured region')
    # A halted sibling must retire nothing; the whole point is that it is parked.
    if peer_halted and peer_body:
        raise ValueError('halted peer retired measured work')
    return {'roiCycles': stop - start + 1, 'peerHalted': peer_halted,
            'peerBodyRetirements': peer_body,
            'scope': 'hart0 fixed work beside a WFI sibling; measures whether an '
                     'idle sibling costs the running hart anything'}


def lock_metrics(flow, symbols, active_harts=(0, 1)):
    """Critical-section timing plus the mutual-exclusion property itself."""
    active = set(active_harts)
    if not active or not active <= {0, 1}:
        raise ValueError('invalid lock worker set')
    begin = {symbols[f'lock_begin{h}']: h for h in (0, 1)}
    end = {symbols[f'lock_end{h}']: h for h in (0, 1)}
    expected = [symbols[n] for n in LOCK_BODY] * LOCK_ITERATIONS
    body = range(symbols[LOCK_BODY[0]], symbols[LOCK_BODY[-1]] + 1)
    events = {h: [] for h in active}
    starts, ends, seen = {}, {}, set()
    last_cycle = -1
    pattern = re.compile(r'^\[smt-flow\] retire cycle=(\d+) port=(\d+) id=\d+ gen=\d+ '
                         r'hart=(\d+) pc=([0-9a-fA-F]+) valid=([01]) drop=([01]) ex=([01])$')
    for line in flow.splitlines():
        if not line.startswith('[smt-flow] retire '):
            continue
        match = pattern.fullmatch(line)
        if not match:
            raise ValueError('malformed retirement event')
        cycle, port, hart = map(int, match.group(1, 2, 3))
        pc = int(match[4], 16)
        if cycle < last_cycle or (cycle, port) in seen or hart not in (0, 1):
            raise ValueError('invalid retirement order, duplicate or hart')
        seen.add((cycle, port))
        last_cycle = cycle
        if match.group(5, 6, 7) != ('1', '0', '0'):
            continue
        if pc in begin or pc in end:
            marker = begin[pc] if pc in begin else end[pc]
            target = starts if pc in begin else ends
            if marker != hart or hart not in active or hart in target:
                raise ValueError('critical-section marker ownership or multiplicity')
            target[hart] = cycle
        if pc in body:
            if hart not in starts or hart in ends:
                raise ValueError('critical-section work outside its own section')
            events[hart].append(pc)
    if set(starts) != active or set(ends) != active:
        raise ValueError('missing critical-section markers')
    for hart in active:
        if ends[hart] <= starts[hart] or events[hart] != expected:
            raise ValueError('incomplete, duplicated or reordered critical-section work')
    spans = {h: (starts[h], ends[h]) for h in active}
    ordered = sorted(spans.values())
    disjoint = all(a[1] < b[0] for a, b in zip(ordered, ordered[1:]))
    if not disjoint:
        raise ValueError('critical sections overlapped: mutual exclusion did not hold')
    return {'workers': sorted(active),
            'criticalSectionCycles': {h: ends[h] - starts[h] + 1 for h in active},
            'sections': {h: list(spans[h]) for h in active},
            'mutualExclusionHeld': True,
            'scope': 'holder cost with a spinning sibling; the waiter retires spin '
                     'instructions that are not useful work'}


def asym_capacity(records):
    summary = {'memoryRoleIterations': ASYM_ITERATIONS['memory'],
               'pairedSoloComparisonAvailable': False, 'adaptivePolicyImplemented': False,
               'softwareHintAbiImplemented': False, 'linuxQualified': False,
               'saturationQualified': False, 'cacheLevelAttributed': False,
               'scope': 'finite checked batch on one shared core, not equal sibling thread counts'}
    pairs = ({'shared-di': ('solo-d0', 'solo-i1'), 'shared-id': ('solo-i0', 'solo-d1')}
             if 'shared-di' in records else
             {'shared-cm': ('solo-c0', 'solo-m1'), 'shared-mc': ('solo-m0', 'solo-c1')})
    needed = set(pairs) | {name for controls in pairs.values() for name in controls}
    if not all(name in records and records[name]['matched'] for name in needed):
        return summary
    if len({records[name]['textSha256'] for name in needed}) != 1:
        raise ValueError('shared and solo instruction images differ')
    batches = {}
    for name, controls in pairs.items():
        report = records[name]['asymMetrics']
        alone = {h: records[control]['asymMetrics']['roiCycles'][h]
                 for h, control in enumerate(controls)}
        span = report['coreWindowCycles']
        batches[name] = {'roles': report['roles'], 'sharedCoreCycles': span,
                         'serialSoloRoiCycles': sum(alone.values()),
                         'batchSpeedupVsSerialSolo': sum(alone.values()) / span,
                         'slowdownByHart': {h: report['roiCycles'][h] / alone[h] for h in alone},
                         'bothWorkerOverlapCycles': report['overlapCycles'],
                         'nonOverlapCycles': span - report['overlapCycles']}
    summary.update(pairedSoloComparisonAvailable=True, identicalInstructionImage=True, batches=batches)
    return summary


def observed_bit(vector, index):
    if not vector or set(vector) - {'0', '1'} or index >= len(vector):
        raise ValueError('invalid observed bit vector')
    return vector[len(vector) - 1 - index] == '1'


def sched_metrics(trace, window, harts=(0, 1)):
    """Per-hart service attribution from edge-compressed scheduler observations."""
    left, right = window
    active_set = set(harts)
    if right <= left or not active_set <= {0, 1}:
        raise ValueError('invalid attribution window or hart set')
    state_re = re.compile(r'^\[smt-sched\] state cycle=(\d+) active=(\d+) ready=([01]+) dmiss=([01]+) '
                          r'imiss=([01]+) block=([01]+) quiesce=([01]) hold=([01]) trap=([01]) flush=([01])$')
    edge_re = re.compile(r'^\[smt-sched\] (decide|switch|abort) cycle=(\d+) from=(\d+) to=(\d+) '
                         r'reason=([01]{4})(?: waited=(\d+))?$')
    states, edges = [], []
    for line in trace.splitlines():
        if not line.startswith('[smt-sched] '):
            continue
        state = state_re.fullmatch(line)
        if state:
            cycle, active = int(state[1]), int(state[2])
            if states and cycle <= states[-1]['cycle']:
                raise ValueError('scheduler state samples are not strictly increasing')
            if active not in active_set:
                raise ValueError('active hart outside the declared set')
            fields = {name: state[group] for group, name in
                      ((3, 'ready'), (4, 'dmiss'), (5, 'imiss'), (6, 'block'))}
            states.append({'cycle': cycle, 'active': active, 'quiesce': state[7] == '1',
                           **{name: [observed_bit(value, h) for h in sorted(active_set)]
                              for name, value in fields.items()}})
            continue
        edge = edge_re.fullmatch(line)
        if not edge:
            raise ValueError('malformed scheduler event')
        if int(edge[3]) not in active_set or int(edge[4]) not in active_set:
            raise ValueError('handoff endpoint outside the declared set')
        edges.append({'kind': edge[1], 'cycle': int(edge[2]), 'from': int(edge[3]),
                      'to': int(edge[4]), 'reason': edge[5],
                      'waited': None if edge[6] is None else int(edge[6])})
    if not states:
        raise ValueError('no scheduler state observation')
    pending, completed, waits = None, [], []
    counts = {'decide': 0, 'switch': 0, 'abort': 0}
    # Bit order matches drain_reason in g6lc_thread_select: yield, miss, quantum, starve
    reasons = {name: 0 for name in ('yield', 'miss', 'quantum', 'starve')}
    for edge in edges:
        if edge['kind'] == 'decide':
            if pending or edge['waited'] is not None:
                raise ValueError('overlapping or mis-tagged handoff decision')
            pending = edge
        else:
            keys = ('from', 'to', 'reason')
            if not pending or [pending[k] for k in keys] != [edge[k] for k in keys]:
                raise ValueError('handoff completion without its matching decision')
            if edge['waited'] != edge['cycle'] - pending['cycle']:
                raise ValueError('reported handoff wait does not match observed cycles')
            completed.append(edge)
            pending = None
        if not left <= edge['cycle'] <= right:
            continue
        counts[edge['kind']] += 1
        if edge['kind'] == 'switch':
            waits.append(edge['waited'])
            for index, name in enumerate(('yield', 'miss', 'quantum', 'starve')):
                reasons[name] += edge['reason'][index] == '1'
    if counts['switch'] and sum(reasons.values()) == 0:
        raise ValueError('a switch was observed without any decision reason')
    order = sorted(active_set)
    served = {h: 0 for h in order}
    denied = {h: 0 for h in order}
    blocked = {h: 0 for h in order}
    longest = {h: 0 for h in order}
    run = {h: 0 for h in order}
    quiesce = 0
    for index, sample in enumerate(states):
        stop = states[index + 1]['cycle'] - 1 if index + 1 < len(states) else right
        start, stop = max(sample['cycle'], left), min(stop, right)
        if stop < start:
            continue
        span = stop - start + 1
        quiesce += span if sample['quiesce'] else 0
        for position, h in enumerate(order):
            if sample['active'] == h:
                served[h] += span
                run[h] = 0
            elif sample['ready'][position]:
                denied[h] += span
                run[h] += span
                longest[h] = max(longest[h], run[h])
            else:
                blocked[h] += span
                run[h] = 0
    cycles = right - left + 1
    if any(served[h] + denied[h] + blocked[h] != cycles for h in order):
        raise ValueError('service accounting does not cover the window')
    return {'window': [left, right], 'windowCycles': cycles, 'harts': order,
            'selectedCycles': served, 'eligibleUnselectedCycles': denied,
            'ineligibleUnselectedCycles': blocked, 'acceptedServiceMeasured': False,
            'longestReadyDenial': longest, 'quiesceCycles': quiesce,
            'handoffCounts': counts, 'switchReasons': reasons,
            'switchDrainWait': {'samples': len(waits), 'total': sum(waits),
                                'max': max(waits, default=0)},
            'unfinishedDecisionAtEnd': pending is not None,
            'completedHandoffs': len(completed), 'fairnessBoundProven': False,
            'scope': 'observed eligibility and handoff cost; a denied cycle is not '
                     'by itself a policy defect, and readiness is the scheduler input'}


def rtt_metrics(trace, window, harts=(0, 1)):
    """Accepted-load to delivered-response latency at the core D-cache port."""
    left, right = window
    active_set = set(harts)
    if right <= left or not active_set <= {0, 1}:
        raise ValueError('invalid attribution window or hart set')
    req_re = re.compile(r'^\[smt-rtt\] req cycle=(\d+) tag=(\d+) idx=([0-9a-f]+) active=(\d+)$')
    other_re = re.compile(r'^\[smt-rtt\] (resp|kill) cycle=(\d+) tag=(\d+) active=(\d+)$')
    outstanding, killed = {}, set()
    at_end = None
    samples = {h: [] for h in sorted(active_set)}
    stale = crossed = killed_responses = observed = 0
    last = -1
    for line in trace.splitlines():
        if not line.startswith('[smt-rtt] '):
            continue
        observed += 1
        request = req_re.fullmatch(line)
        event = None if request else other_re.fullmatch(line)
        if not request and not event:
            raise ValueError('malformed load transaction event')
        kind = 'req' if request else event[1]
        cycle = int(request[1] if request else event[2])
        tag = int(request[2] if request else event[3])
        active = int(request[4] if request else event[4])
        if cycle < last or active not in active_set:
            raise ValueError('load events out of order or outside the declared hart set')
        last = cycle
        if cycle > right and at_end is None:
            at_end = outstanding.copy()
        if kind == 'req':
            if tag in outstanding:
                raise ValueError('a load tag was reissued while still outstanding')
            outstanding[tag] = (cycle, active)
            killed.discard(tag)
        elif kind == 'kill':
            killed.add(tag)
        elif tag not in outstanding:
            stale += 1
        else:
            start, owner = outstanding.pop(tag)
            was_killed = tag in killed
            killed.discard(tag)
            if was_killed:
                killed_responses += 1
            elif not left <= start <= right or not left <= cycle <= right:
                continue
            elif owner != active:
                crossed += 1
            else:
                samples[owner].append(cycle - start)
    if at_end is None:
        at_end = outstanding.copy()
    counted = {h: sorted(values) for h, values in samples.items()}
    # A dead or uncompiled observer is a measurement failure; a window that
    # genuinely performs no load (a register-only loop) legitimately has none.
    if not observed:
        raise ValueError('no load transaction was observed at all')
    return {'window': [left, right], 'harts': sorted(active_set), 'observedEvents': observed,
            'completedSamples': {h: len(v) for h, v in counted.items()},
            'latencyMin': {h: (v[0] if v else None) for h, v in counted.items()},
            'latencyMedian': {h: (v[len(v) // 2] if v else None) for h, v in counted.items()},
            'latencyMax': {h: (v[-1] if v else None) for h, v in counted.items()},
            'latencyMean': {h: (sum(v) / len(v) if v else None) for h, v in counted.items()},
            'buckets': {h: {bound: sum(1 for value in v if value <= bound)
                            for bound in (4, 8, 16, 32, 64, 128)} for h, v in counted.items()},
            'outstandingAtEnd': len(at_end),
            'outstandingAgesAtEnd': {h: sorted(right - c for c, owner in at_end.values() if owner == h)
                                     for h in sorted(active_set)},
            'crossSwitchCensored': crossed, 'exceptionCountsScope': 'whole trace',
            'killedResponses': killed_responses, 'staleResponses': stale,
            'levelAttributionProven': False,
            'scope': 'accepted request to delivered response at the core load port; '
                     'ownership is the scheduler active hart under the drained handoff, '
                     'so cross-switch, killed and censored samples are excluded, and no '
                     'cache level is inferred from latency'}


def activation_controls(model, data, out):
    startup = os.environ.get('SMT2_REVIEW_STARTUP') == '1'
    before = os.environ.get('SMT2_REVIEW_STARTUP_BEFORE') == '1'
    lrsc = os.environ.get('SMT2_REVIEW_LRSC') == '1'
    balance = os.environ.get('SMT2_REVIEW_BALANCE') == '1'
    attribution = os.environ.get('SMT2_REVIEW_ATTRIBUTION') == '1'
    asym = os.environ.get('SMT2_REVIEW_ASYM') == '1'
    mem_depth = int(os.environ.get('SMT2_REVIEW_MEM_DEPTH', '64'))
    mem_sum = set_memory_depth(mem_depth)
    dep = os.environ.get('SMT2_REVIEW_DEP') == '1'
    if dep:
        asym = True
    # In dep mode the role bit selects 'ind' (the branch-taken body); dep is the
    # fall-through. Same markers and oracle as the compute/memory pairing.
    dep_arms = {'shared-di': (3, 2, {0: 'dep', 1: 'ind'}),
                'shared-id': (3, 1, {0: 'ind', 1: 'dep'}),
                'solo-d0': (1, 0, {0: 'dep'}), 'solo-i0': (1, 1, {0: 'ind'}),
                'solo-d1': (2, 0, {1: 'dep'}), 'solo-i1': (2, 2, {1: 'ind'}),
                'oracle-negative': (3, 2, {0: 'dep', 1: 'ind'})}
    pmu = os.environ.get('SMT2_REVIEW_PMU') == '1'
    pmuevt = os.environ.get('SMT2_REVIEW_PMUEVT') == '1'
    pmumiss = os.environ.get('SMT2_REVIEW_PMUMISS') == '1'
    lock = os.environ.get('SMT2_REVIEW_LOCK') == '1'
    ipi = os.environ.get('SMT2_REVIEW_IPI') == '1'
    if (lock or ipi) and (not startup or before or lrsc or balance or asym):
        raise ValueError('lock/ipi require startup mode without the other workloads')
    if lock and ipi:
        raise ValueError('select one of lock or ipi')
    ipi_arms = {'wfi-sibling': 3, 'solo0': 1, 'oracle-negative': 3}
    if (pmu or pmuevt or pmumiss) and (not startup or before or lrsc or balance or asym or lock):
        raise ValueError('pmu probes require startup mode without the other workloads')
    # The waiter's spin loop carries a PAUSE only when SMT2_REVIEW_LOCK_PAUSE=1, so
    # the hinted and unhinted runs are otherwise identical and directly comparable.
    lock_pause = os.environ.get('SMT2_REVIEW_LOCK_PAUSE') == '1'
    lock_arms = {'contended': 3, 'solo0': 1, 'solo1': 2, 'oracle-negative': 3}
    if sum((pmu, pmuevt, pmumiss)) > 1:
        raise ValueError('select one pmu probe at a time')
    # (lo0, hi0, lo1, hi1) on the D$-miss delta. hart1 issues no memory access, so its
    # own count must be exactly 0; any nonzero value is a miss charged to the successor.
    pmumiss_arms = {'isolated': (1, 64, 0, 0),
                    'leak-negative': (1, 64, 1, 64),
                    'oracle-negative': (1000, 2000, 0, 0)}
    # (lo0, hi0, lo1, hi1) bounds on each hart's own load-event delta. Quotas are
    # 256 and 768; the event ORs commit ports, so the floor allows a 2x undercount.
    # Shared or cross-attributed counting lands near 1024 and is refused.
    pmuevt_arms = {'attributed': (128, 256, 384, 768),
                   'shared-negative': (512, 1024, 512, 1024),
                   'oracle-negative': (1024, 2048, 1024, 2048)}
    # Expected mhpmevent3 readback per hart under each hypothesis. Per-hart banks
    # are the architectural requirement, so that arm must pass and the shared
    # hypothesis must fail; SMT2_REVIEW_PMU_SHARED selects the pre-repair polarity.
    # Banked signature is (h0=1, h1=0): hart0 still reads back its OWN earlier
    # write while hart1 never sees it, so both directions of isolation are shown.
    # Shared signature is (h0=2, h1=1): each hart reads back the peer's write.
    if os.environ.get('SMT2_REVIEW_PMU_SHARED') == '1':
        pmu_arms = {'shared': (2, 1), 'banked-negative': (1, 0), 'oracle-negative': (2, 1)}
    else:
        pmu_arms = {'banked': (1, 0), 'shared-negative': (2, 1), 'oracle-negative': (1, 0)}
    if balance and (not startup or before or lrsc):
        raise ValueError('balance requires startup mode without before/LRSC')
    if asym and (not startup or before or lrsc or balance):
        raise ValueError('asym requires startup mode without before/LRSC/balance')
    if attribution and not (balance or asym):
        raise ValueError('attribution observers require a measurement workload')
    # active mask, roles bitmap (bit h set = memory role), expected role per hart
    asym_arms = {'shared-cm': (3, 2, {0: 'compute', 1: 'memory'}),
                 'shared-mc': (3, 1, {0: 'memory', 1: 'compute'}),
                 'solo-c0': (1, 0, {0: 'compute'}),
                 'solo-m0': (1, 1, {0: 'memory'}),
                 'solo-c1': (2, 0, {1: 'compute'}),
                 'solo-m1': (2, 2, {1: 'memory'}),
                 'oracle-negative': (3, 2, {0: 'compute', 1: 'memory'})}
    consumer = os.environ.get('SMT2_REVIEW_LRSC_CONSUMER', 'rs1')
    if lrsc and (not startup or consumer not in ('rs1', 'rs2', 'alu')):
        raise ValueError('LR/SC controls require startup mode and a supported consumer')
    original = (data / ('smt_dual_active.S' if startup else 'mini_ipi_hart1_sp.S')).read_text()
    linker = data / 'link_verilator.ld'
    cap = int(os.environ.get('SMT2_REVIEW_MINI_CYCLES', '250000' if startup and before else '30000'))
    arms = (('rvc',) if before else ('rvc', 'norvc', 'oracle-negative')) if startup else ('ipi', 'no-ipi')
    if balance:
        arms = ('rvc', 'norvc', 'solo0', 'solo1', 'oracle-negative')
    if dep:
        asym_arms = dep_arms
    if asym:
        arms = tuple(asym_arms)
    if pmu:
        arms = tuple(pmu_arms)
    if pmuevt:
        arms = tuple(pmuevt_arms)
    if pmumiss:
        arms = tuple(pmumiss_arms)
    if lock:
        arms = tuple(lock_arms)
    if ipi:
        arms = tuple(ipi_arms)
    selected = os.environ.get('SMT2_REVIEW_STARTUP_ARM')
    if selected:
        if selected not in arms:
            raise ValueError('unknown startup arm')
        arms = (selected,)
    records = []
    for arm in arms:
        work = out / arm
        work.mkdir()
        text = ('#define SMT_IPI\n' if ipi else '#define SMT_LOCK\n' if lock else '#define SMT_PMUMISS\n' if pmumiss else '#define SMT_PMUEVT\n' if pmuevt else '#define SMT_PMU\n' if pmu else '#define SMT_ASYM\n' if asym else '#define SMT_BALANCE\n' if balance else '#define SMT_LRSC_DEP\n' if lrsc else '#define SMT_BOOT_RENDEZVOUS\n' if startup else '') + original
        if balance and arm.startswith('solo'):
            text = '#define SMT_BALANCE_SOLO ' + arm[-1] + '\n' + text
        if pmu:
            expect_h0, expect_h1 = pmu_arms[arm]
            text = f'#define PMU_EXP_H0 {expect_h0}\n#define PMU_EXP_H1 {expect_h1}\n' + text
        if pmuevt:
            lo0, hi0, lo1, hi1 = pmuevt_arms[arm]
            text = (f'#define PMUEVT_LO0 {lo0}\n#define PMUEVT_HI0 {hi0}\n'
                    f'#define PMUEVT_LO1 {lo1}\n#define PMUEVT_HI1 {hi1}\n') + text
        if ipi:
            text = f'#define IPI_ACTIVE {ipi_arms[arm]}\n' + text
        if lock:
            text = f'#define LOCK_ACTIVE {lock_arms[arm]}\n' + text
            if lock_pause:
                text = '#define LOCK_PAUSE\n' + text
        if pmumiss:
            lo0, hi0, lo1, hi1 = pmumiss_arms[arm]
            text = (f'#define PMUMISS_LO0 {lo0}\n#define PMUMISS_HI0 {hi0}\n'
                    f'#define PMUMISS_LO1 {lo1}\n#define PMUMISS_HI1 {hi1}\n') + text
        if dep:
            text = '#define SMT_DEP\n' + text
        if asym:
            text = (f'#define ASYM_MEM_ITERS {mem_depth}\n'
                    f'#define ASYM_MEM_SUM {mem_sum}\n') + text
        if asym:
            active, bitmap, _ = asym_arms[arm]
            text = f'#define ASYM_ACTIVE {active}\n#define ASYM_ROLES {bitmap}\n' + text
        if lrsc and consumer != 'rs1':
            text = '#define SMT_LRSC_' + consumer.upper() + '\n' + text
        if arm == 'norvc' or (asym and os.environ.get('SMT2_REVIEW_ASYM_NORVC') == '1'):
            text = '.option norvc\n' + text
        if arm == 'oracle-negative':
            text = '#define SMT_BOOT_FAULT\n' + text
        if arm == 'no-ipi':
            for store in ('  sw   t1, 0(t0)', '  sw   t1, 4(t0)'):
                if text.count(store) != 1:
                    raise RuntimeError('IPI control site changed')
                text = text.replace(store, '  .word 0x00000013')
        asm = work / 'mini.S'
        asm.write_text(text)
        elf = work / 'mini.elf'
        command = ['riscv-none-elf-gcc', '-march=rv64imafdc_zicsr', '-mabi=lp64d',
                   '-nostdlib', '-nostartfiles', '-Wl,--no-relax', '-T', str(linker),
                   '-o', str(elf), str(asm)]
        compilation = capture(command)
        (work / 'compile.json').write_text(json.dumps({'command': command, **compilation}, indent=2))
        if compilation['rc']:
            raise RuntimeError('activation mini did not compile')
        text_hash = None
        if balance or asym:
            image = work / 'text.bin'
            copied = capture(['riscv-none-elf-objcopy', '-O', 'binary', '--only-section=.text', str(elf), str(image)])
            if copied['rc']:
                raise RuntimeError('cannot bind the measured instruction image')
            text_hash = digest(image)
        symbols = capture(['riscv-none-elf-nm', '-n', str(elf)])
        symbol_map = {name: int(value, 16) for value, name in re.findall(
            r'^([0-9a-fA-F]+)\s+\w\s+(\w+)$', symbols['stdout'], re.M)}
        address = re.findall(r'^([0-9a-fA-F]+)\s+\w\s+tohost$', symbols['stdout'], re.M)
        if len(address) != 1:
            raise RuntimeError('activation mini tohost is not unique')
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(('SOFT_', 'PEEL_', 'CVA6_', 'G6LC_'))}
        env['CVA6_TRAP_DUMP'] = '1'
        log_path = work / 'run.log'
        command = [str(model), '--seed=1', f'+time_out={cap}', f'+max-cycles={cap}',
                   '+debug_disable', '+quiet_axi', '+smt_progress',
                   '+tohost_addr=0x' + address[0], str(elf)]
        # The lock oracle reads retirement markers, so it needs the flow trace too.
        observers = ['+smt_flow_trace'] if balance or asym or lock or ipi or os.environ.get('SMT2_REVIEW_STARTUP_FLOW') == '1' else []
        if attribution:
            observers += ['+smt_sched_trace', '+smt_rtt_trace']
        for argument in observers:
            command.insert(-1, argument)
        with log_path.open('w') as log:
            result = subprocess.run(command, cwd=work, env=env,
                                    stdout=log, stderr=subprocess.STDOUT, timeout=180)
        log = log_path.read_text(errors='replace')
        (work / 'flow.log').write_text('\n'.join(line for line in log.splitlines() if line.startswith('[smt-flow]')))
        progress = {int(h): int(n) for h, n in re.findall(r'\[smt-progress\].*hart=(\d+) retired=(\d+)', log)}
        terminated = bool(re.search(r'\[rvfi_tracer\] INFO: Simulation terminated', log))
        matched = (result.returncode == 0 and terminated and progress.get(0, 0) > 0
                   and progress.get(1, 0) > 0 and 'sp1=0x80007000' in log) if arm == 'ipi' else (
                   result.returncode == 0 and not terminated and 'after 30000 cycles' in log
                   and progress.get(0, 0) > 0 and progress.get(1) == 0)
        if startup:
            if before:
                matched = (result.returncode == 0 and not terminated and f'after {cap} cycles' in log
                           and progress.get(0, 0) > 0 and progress.get(1) == 0)
            else:
                trace = '\n'.join(p.read_text() for p in work.glob('trace_rvfi_hart_*.dasm'))
                stores = re.findall(r'\bmem (0x[0-9a-fA-F]+) (0x[0-9a-fA-F]+)', trace)
                # A pmu arm that states the banked hypothesis must fail on a shared
                # counter; that refusal is what makes the probe a discriminator.
                verdict = 3 if arm == 'oracle-negative' or ((pmu or pmuevt or pmumiss) and arm.endswith('-negative')) else 1
                matched = (terminated and progress.get(0, 0) > 0 and progress.get(1, 0) > 0
                           and any(int(a, 16) == int(address[0], 16) and int(v, 16) == verdict for a, v in stores)
                           and ((result.returncode != 0) if verdict == 3 else result.returncode == 0))
        record = {'arm': arm, 'lrscConsumer': consumer if lrsc else None,
                  'rc': result.returncode, 'retiredByHart': progress,
                  'pins': [line for line in log.splitlines() if line.startswith(('[hangpc]', '[smt-progress]'))],
                  'explicitTermination': terminated, 'matched': matched,
                  'elapsedVerdicts': re.findall(r'\*\*\* (?:SUCCESS|FAILED).*', log),
                  'sourceSha256': digest(asm), 'elfSha256': digest(elf), 'textSha256': text_hash,
                  'modelSha256': digest(model), 'logSha256': digest(log_path),
                  'scope': 'asymmetric compute/memory roles, not Linux or adaptive policy' if asym else 'dual-runnable fixed-work baseline, not Linux or adaptive policy' if balance else 'directed LR/SC result dependency' if lrsc else 'directed reset rendezvous' if startup else 'directed IPI activation, not OpenSBI completion'}
        if ipi and arm != 'oracle-negative':
            peer = ipi_arms[arm] == 3
            published = {(int(a, 16), int(v, 16)) for a, v in re.findall(
                r'^3 .*?\bmem (0x[0-9a-fA-F]+) (0x[0-9a-fA-F]+)\s*$', trace, re.M)}
            base = symbol_map['ipi_state']
            expect = {(base + 8, 512), (base + 16, 1)}
            if peer:
                expect |= {(base + 72, 0x5A), (base + 80, 1)}
            record['publicationsChecked'] = expect <= published
            record['matched'] = record['matched'] and record['publicationsChecked']
            try:
                record['ipiMetrics'] = ipi_metrics(log, symbol_map, peer)
            except ValueError as error:
                record.update(matched=False, metricsError=str(error))
        if lock and arm != 'oracle-negative':
            workers = (0, 1) if lock_arms[arm] == 3 else (lock_arms[arm] - 1,)
            published = {(int(a, 16), int(v, 16)) for a, v in re.findall(
                r'^3 .*?\bmem (0x[0-9a-fA-F]+) (0x[0-9a-fA-F]+)\s*$', trace, re.M)}
            expected = {(symbol_map['lock_state'] + h * 64 + offset, value)
                        for h in workers for offset, value in ((8, 512), (16, 1))}
            record['publicationsChecked'] = expected <= published
            record['matched'] = record['matched'] and record['publicationsChecked']
            try:
                record['lockMetrics'] = lock_metrics(log, symbol_map, workers)
            except ValueError as error:
                record.update(matched=False, metricsError=str(error))
        if pmumiss:
            published = {int(a, 16): int(v, 16) for a, v in re.findall(
                r'^3 .*?\bmem (0x[0-9a-fA-F]+) (0x[0-9a-fA-F]+)\s*$', trace, re.M)}
            base = symbol_map['pmumiss_state']
            record['pmuMissDeltas'] = {
                'ownMissDeltaByHart': {h: published.get(base + h * 64 + 8) for h in (0, 1)},
                'scope': 'hart0 strides past the D$ while hart1 issues no memory access; '
                         'a nonzero hart1 count would be a miss charged to the successor'}
        if pmuevt:
            published = {int(a, 16): int(v, 16) for a, v in re.findall(
                r'^3 .*?\bmem (0x[0-9a-fA-F]+) (0x[0-9a-fA-F]+)\s*$', trace, re.M)}
            base = symbol_map['pmuevt_state']
            record['pmuEventDeltas'] = {
                'ownLoadEventDeltaByHart': {h: published.get(base + h * 64 + 8) for h in (0, 1)},
                'loadQuotaByHart': {0: 256, 1: 768},
                'scope': 'own mhpmcounter3 delta across a window spanning many handoffs; '
                         'the event ORs commit ports, so a delta below its quota is '
                         'expected and only cross-hart inflation is refused'}
        if pmu:
            published = {int(a, 16): int(v, 16) for a, v in re.findall(
                r'^3 .*?\bmem (0x[0-9a-fA-F]+) (0x[0-9a-fA-F]+)\s*$', trace, re.M)}
            base = symbol_map['pmu_state']
            record['pmuObserved'] = {
                'peerSelectorSeenByHart': {h: published.get(base + h * 64 + 8) for h in (0, 1)},
                'ownScratchSeenByHart': {h: published.get(base + h * 64 + 16) for h in (0, 1)},
                'scope': 'mhpmevent3 readback after a handshaked peer write; '
                         'mscratch is the architecturally per-hart control'}
        if asym and arm != 'oracle-negative':
            roles = asym_arms[arm][2]
            publications = {(int(a, 16), int(v, 16)) for a, v in re.findall(
                r'^3 .*?\bmem (0x[0-9a-fA-F]+) (0x[0-9a-fA-F]+)\s*$', trace, re.M)}
            expected = {(symbol_map['asym_state'] + h * 64 + offset, value)
                        for h, role in roles.items()
                        for offset, value in ((8, ASYM_RESULTS[role]), (16, 1))}
            record['publicationsChecked'] = expected <= publications
            record['matched'] = record['matched'] and record['publicationsChecked']
            try:
                report = asym_metrics(log, symbol_map, roles)
                record['asymMetrics'] = report
                if attribution:
                    window = report['commonWindow']
                    if not window:
                        raise ValueError('the roles never overlapped, so nothing is attributable')
                    record['schedMetrics'] = sched_metrics(log, window, (0, 1))
                    record['rttMetrics'] = rtt_metrics(log, window, (0, 1))
                    record['coreSchedMetrics'] = sched_metrics(log, report['coreWindow'], (0, 1))
                    record['roleRttMetrics'] = {h: rtt_metrics(log, roi, (0, 1))
                                                for h, roi in report['roiWindows'].items()}
                    record['roleLoadCountsChecked'] = all(
                        record['roleRttMetrics'][h]['completedSamples'][h] ==
                        (ASYM_ITERATIONS[role] if role == 'memory' else 0)
                        for h, role in roles.items())
                    record['matched'] = record['matched'] and record['roleLoadCountsChecked']
            except ValueError as error:
                record.update(matched=False, metricsError=str(error))
        if balance and arm != 'oracle-negative':
            active = (int(arm[-1]),) if arm.startswith('solo') else (0, 1)
            publications = {(int(a, 16), int(v, 16)) for a, v in re.findall(
                r'^3 .*?\bmem (0x[0-9a-fA-F]+) (0x[0-9a-fA-F]+)\s*$', trace, re.M)}
            expected = {(symbol_map['balance_state'] + h * 64 + offset, value)
                        for h in active for offset, value in ((8, 512 * (h + 1)), (16, 1))}
            record['publicationsChecked'] = expected <= publications
            record['matched'] = record['matched'] and record['publicationsChecked']
            try:
                record['balanceMetrics'] = balance_metrics(log, symbol_map, active)
                if attribution:
                    # The scheduler and the load port see every hart regardless of
                    # which harts this arm gives work to, so they are not scoped to
                    # the workload's active set.
                    window = record['balanceMetrics']['commonWindow']
                    record['schedMetrics'] = sched_metrics(log, window, (0, 1))
                    record['rttMetrics'] = rtt_metrics(log, window, (0, 1))
                    selected_cycles = record['schedMetrics']['selectedCycles']
                    record['workersSelectedInWindow'] = all(selected_cycles[h] > 0 for h in active)
            except ValueError as error:
                record.update(matched=False, metricsError=str(error))
        if record['matched'] and ((balance and arm == 'rvc') or (asym and arm.startswith('shared-'))):
            quiet = work / 'observer-off'
            quiet.mkdir()
            off_command = [argument for argument in command if argument not in observers]
            with (quiet / 'run.log').open('w') as output:
                off = subprocess.run(off_command, cwd=quiet, env=env, stdout=output,
                                     stderr=subprocess.STDOUT, timeout=180)
            off_log = (quiet / 'run.log').read_text(errors='replace')
            on_traces = sorted(work.glob('trace_rvfi_hart_*.dasm'))
            off_traces = sorted(quiet.glob('trace_rvfi_hart_*.dasm'))
            equivalent = (off.returncode == result.returncode and len(on_traces) == len(off_traces) == 1
                          and on_traces[0].stat().st_size > 0
                          and digest(on_traces[0]) == digest(off_traces[0])
                          and '[rvfi_tracer] INFO: Simulation terminated' in off_log
                          and re.findall(r'\*\*\* (?:SUCCESS|FAILED).*', off_log) == record['elapsedVerdicts'])
            record['observerEquivalent'] = equivalent
            record['matched'] = record['matched'] and equivalent
        records.append(record)
        (out / 'activation-results.json').write_text(json.dumps(records, indent=2) + '\n')
        print(json.dumps(record), flush=True)
    if balance:
        arms_by_name = {r['arm']: r for r in records}
        required = ('rvc', 'solo0', 'solo1')
        summary = {'pairedSoloComparisonAvailable': False, 'adaptivePolicyImplemented': False,
                   'linuxQualified': False, 'saturationQualified': False}
        if all(name in arms_by_name and arms_by_name[name]['matched'] for name in required):
            if len({arms_by_name[name]['textSha256'] for name in required}) != 1:
                raise RuntimeError('solo and shared instruction images differ')
            shared = arms_by_name['rvc']['balanceMetrics']['bodyIPC']
            relative = {h: shared[h] / arms_by_name[f'solo{h}']['balanceMetrics']['bodyIPC'][h] for h in (0, 1)}
            summary.update(pairedSoloComparisonAvailable=True, identicalInstructionImage=True,
                           relativePerHartIPC=relative, weightedSpeedup=sum(relative.values()),
                           worstHartSlowdown=max(1 / value for value in relative.values()))
        (out / 'balance-summary.json').write_text(json.dumps(summary, indent=2))
    if ipi:
        by_name = {r['arm']: r for r in records}
        summary = {'scope': 'idle-sibling cost and per-hart IPI wake routing; no '
                            'Linux IPI path, no adaptive policy'}
        if all(n in by_name and by_name[n]['matched'] for n in ('wfi-sibling', 'solo0')):
            shared = by_name['wfi-sibling']['ipiMetrics']
            alone = by_name['solo0']['ipiMetrics']
            summary.update(
                roiCyclesWithHaltedSibling=shared['roiCycles'],
                roiCyclesSolo=alone['roiCycles'],
                idleSiblingCostRatio=shared['roiCycles'] / alone['roiCycles'],
                haltedPeerRetiredNoWork=shared['peerBodyRetirements'] == 0,
                # hart0 checked its own mip.MSIP stayed clear after sending the IPI
                ipiWokeOnlyTheTargetHart=True)
        (out / 'ipi-summary.json').write_text(json.dumps(summary, indent=2))
    if lock:
        by_name = {r['arm']: r for r in records}
        summary = {'adaptivePolicyImplemented': False, 'spinHintInWaiterLoop': lock_pause,
                   'scope': 'one lock, identical critical sections; the waiter produces '
                            'nothing while spinning, so equal sibling service is not the goal'}
        needed = ('contended', 'solo0', 'solo1')
        if all(n in by_name and by_name[n]['matched'] for n in needed):
            shared = by_name['contended']['lockMetrics']['criticalSectionCycles']
            alone = {h: by_name[f'solo{h}']['lockMetrics']['criticalSectionCycles'][h]
                     for h in (0, 1)}
            summary.update(
                mutualExclusionHeld=True,
                criticalSectionCyclesContended=shared, criticalSectionCyclesSolo=alone,
                holderSlowdownFromSpinningSibling={h: shared[h] / alone[h] for h in (0, 1)})
        (out / 'lock-summary.json').write_text(json.dumps(summary, indent=2))
    if pmu:
        by_name = {r['arm']: r for r in records}
        summary = {'countersArePerHart': None, 'hintAbiImplemented': False,
                   'scope': 'ownership of mhpmevent3 only, not a full PMU or SBI contract'}
        if all(name in by_name and by_name[name]['matched'] for name in pmu_arms):
            observed = {name: by_name[name]['pmuObserved'] for name in pmu_arms}
            reference = 'shared' if 'shared' in observed else 'banked'
            selectors = observed[reference]['peerSelectorSeenByHart']
            scratch = observed[reference]['ownScratchSeenByHart']
            if any(report['peerSelectorSeenByHart'] != selectors for report in observed.values()):
                raise ValueError('observed counter behaviour changed between arms')
            summary.update(
                peerSelectorSeenByHart=selectors, ownScratchSeenByHart=scratch,
                perHartControlHolds=scratch == {0: 0x100, 1: 0x101},
                countersArePerHart=selectors == {0: 1, 1: 0},
                countersAreShared=selectors == {0: 2, 1: 1},
                # guarded above: every arm matched, so the banked arm did fail
                bankedHypothesisRefused=True)
        (out / 'pmu-summary.json').write_text(json.dumps(summary, indent=2))
    if asym:
        by_name = {r['arm']: r for r in records}
        # hart 0 runs compute in shared-cm and memory in shared-mc, and each role
        # again alone, so a role slowdown is not confounded with the hart index.
        summary = asym_capacity(by_name)
        (out / 'asym-summary.json').write_text(json.dumps(summary, indent=2))
    return 0 if all(r['matched'] for r in records) else 1


def main():
    import resource

    repo = Path(os.environ.get('TH_REPO_DIR', '/opt/testharness/repo')).resolve()
    out = Path(os.environ['TH_OUT_DIR']).resolve()
    out.mkdir(parents=True, exist_ok=True)
    model = Path(os.environ['SMT2_REVIEW_MODEL']).resolve()
    elf = Path(os.environ['SMT2_REVIEW_ELF']).resolve()
    driver = repo / 'verif/regress/soft-ladder-opensbi-soak.sh'
    inspect = os.environ.get('SMT2_REVIEW_INSPECT') == '1'
    evidence = {'model': str(model), 'elf': str(elf), 'inspectOnly': inspect,
                'runnerSha256': digest(Path(__file__))}
    for name, path in [('model', model), ('elf', elf), ('driver', driver)]:
        if not path.is_file():
            raise RuntimeError(f'missing {name}: {path}')
        evidence[name + 'Sha256'] = digest(path)
    evidence['symbols'] = capture(['riscv-none-elf-nm', '-n', str(elf)])
    (out / 'symbols.txt').write_text(evidence['symbols']['stdout'])
    disasm_start = int(os.environ.get('SMT2_REVIEW_DISASM_START', '0x80012550'), 0)
    disasm_end = int(os.environ.get('SMT2_REVIEW_DISASM_END', '0x800125c0'), 0)
    if not 0 <= disasm_start < disasm_end <= disasm_start + 65536:
        raise ValueError('invalid bounded disassembly interval')
    evidence['pinDisassembly'] = capture([
        'riscv-none-elf-objdump', '-d', f'--start-address={disasm_start}',
        f'--stop-address={disasm_end}', str(elf)])
    metadata = {}
    for name in ('build.log', '.soft-ladder-flavour', 'Variane_testharness__verFiles.dat',
                 'Variane_testharness.mk'):
        path = model.parent / name
        if path.is_file():
            text = path.read_text(errors='replace')
            metadata[name] = {'sha256': digest(path), 'lines': [line for line in text.splitlines()
                if any(word in line for word in ('--threads', 'VERILATOR_ROOT', 'flavour', 'vthreads='))][:12]}
    evidence['buildMetadata'] = metadata
    dependencies = '\n'.join(p.read_text(errors='replace') for p in model.parent.glob('*.d'))
    evidence['compiledRuntimeHeaders'] = sorted(set(re.findall(r'\S+/include/verilated_funcs\.h', dependencies)))
    evidence['versions'] = {tool: capture([tool, '--version']) for tool in ('verilator', 'riscv-none-elf-gcc')}
    runtime_record = Path('/opt/testharness/runs/review-cacheability-pair-20260916/output/runtime.json')
    if runtime_record.is_file():
        runtime = json.loads(runtime_record.read_text())
        evidence['recordedRuntime'] = runtime
        evidence['runtimeHeaders'] = {}
        for key in ('privateRoot', 'originalRoot'):
            header = Path(runtime[key]) / 'include/verilated_funcs.h'
            evidence['runtimeHeaders'][key] = {'path': str(header), 'sha256': digest(header)}
    canaries = Path('/opt/testharness/runs/review-private-runtime-rebuild-20260915/output/canaries.json')
    if canaries.is_file():
        evidence['recordedCanaries'] = json.loads(canaries.read_text())
    (out / 'audit.json').write_text(json.dumps(evidence, indent=2) + '\n')
    print(json.dumps({k: v for k, v in evidence.items()
                      if k not in ('symbols', 'versions', 'pinDisassembly')}, indent=2), flush=True)
    print(evidence['pinDisassembly']['stdout'], flush=True)
    if inspect:
        trace_root = os.environ.get('SMT2_REVIEW_TRACE_ROOT')
        if trace_root:
            tails = {}
            pattern = os.environ.get('SMT2_REVIEW_TRACE_FILTER', '').replace(',', '|')
            for path in sorted(Path(trace_root).glob('trace_rvfi_hart_*.dasm')):
                tail = deque(maxlen=min(2000, max(1, int(os.environ.get('SMT2_REVIEW_TRACE_TAIL_LINES', '24')))))
                match_limit = min(2000, max(1, int(os.environ.get('SMT2_REVIEW_TRACE_MATCH_LIMIT', '80'))))
                match_tail = os.environ.get('SMT2_REVIEW_TRACE_MATCH_TAIL') == '1'
                matches = deque(maxlen=match_limit)
                match_count = number = 0
                with path.open(errors='replace') as fh:
                    for number, line in enumerate(fh, 1):
                        tail.append(line)
                        subject = line
                        if os.environ.get('SMT2_REVIEW_TRACE_PC_ONLY') == '1':
                            fields = line.split()
                            subject = fields[1] if len(fields) > 1 and fields[0] in ('0', '1', '2', '3') else ''
                        if pattern and re.search(pattern, subject):
                            match_count += 1
                            if match_tail or len(matches) < match_limit:
                                matches.append({'line': number, 'text': line.rstrip()})
                tails[path.name] = {'sha256': digest(path), 'lines': number, 'matchCount': match_count,
                                    'tail': list(tail), 'matches': list(matches)}
                if path.stat().st_size <= 8_000_000:
                    shutil.copy2(path, out / path.name)
            (out / 'trace-tails.json').write_text(json.dumps(tails, indent=2) + '\n')
            flow_pattern = os.environ.get('SMT2_REVIEW_FLOW_FILTER', '').replace(',', '|')
            log_tails = {}
            for path in sorted([*Path(trace_root).glob('veri_B_*.log'), *Path(trace_root).glob('run.log')]):
                log_tail = deque(maxlen=60)
                flow = []
                with path.open(errors='replace') as fh:
                    for line in fh:
                        log_tail.append(line.rstrip())
                        if line.startswith('[smt-flow]') and (not flow_pattern or re.search(flow_pattern, line)):
                            flow.append(line)
                log_tails[path.name] = list(log_tail)
                (out / 'flow.log').write_text(''.join(flow))
            (out / 'log-tails.json').write_text(json.dumps(log_tails, indent=2))
        return 0

    data = Path(os.environ['TH_DATA_DIR'])
    manifest = json.loads((data / 'build-manifest.json').read_text())
    if manifest['executableSha256'] != evidence['modelSha256']:
        raise RuntimeError('model does not match the uploaded build manifest')
    if manifest['configuration']['flavour'] != 'B' or manifest['target'] != 'g6lc64_smt2':
        raise RuntimeError('expected a fetch_B SMT2 build manifest')
    verfiles = (model.parent / 'Variane_testharness__verFiles.dat').read_text()
    if not re.search(r'--threads\s+1(?:\s|["\'])', verfiles):
        raise RuntimeError('generated model does not record --threads 1')
    check_fetch_b_sources(verfiles)
    runtime_hash = os.environ['SMT2_REVIEW_RUNTIME_SHA256']
    if not evidence['compiledRuntimeHeaders'] or any(
            digest(Path(path)) != runtime_hash for path in evidence['compiledRuntimeHeaders']):
        raise RuntimeError('compiler dependencies do not match the expected runtime header')
    expected_elf = os.environ['SMT2_REVIEW_ELF_SHA256']
    if evidence['elfSha256'] != expected_elf:
        raise RuntimeError('payload changed since inspection')
    symbols = re.findall(r'^([0-9a-fA-F]+)\s+\w\s+tohost$',
                         evidence['symbols']['stdout'], re.M)
    if len(symbols) != 1:
        raise RuntimeError('expected one tohost symbol')
    if capture(['pgrep', '-af', '[/]Variane_testharness( |$)'])['rc'] != 1:
        raise RuntimeError('another harness is running or process check failed')
    resource.setrlimit(resource.RLIMIT_STACK, (resource.RLIM_INFINITY, resource.RLIM_INFINITY))
    if os.environ.get('SMT2_REVIEW_ACTIVATION') == '1' or os.environ.get('SMT2_REVIEW_STARTUP') == '1':
        result = activation_controls(model, data, out)
        if digest(model) != evidence['modelSha256']:
            raise RuntimeError('activation model changed during the controls')
        return result
    inputs = out / 'inputs'
    inputs.mkdir()
    frozen_elf = inputs / elf.name
    frozen_model = inputs / 'Variane_testharness'
    frozen_driver = inputs / driver.name
    for source, dest in ((elf, frozen_elf), (model, frozen_model), (driver, frozen_driver),
                         (data / 'build-manifest.json', inputs / 'build-manifest.json')):
        shutil.copy2(source, dest)
    canary_source = Path('/opt/testharness/runs/review-private-runtime-20260915/output/constant_canary.cpp')
    canary_results = []
    for label, root_key, expected in [('original', 'originalRoot', 1), ('fixed', 'privateRoot', 0)]:
        executable = out / ('canary-' + label)
        compilation = capture(['g++', '-std=c++17', '-O2',
                               '-I' + evidence['recordedRuntime'][root_key] + '/include',
                               str(canary_source), '-o', str(executable)])
        if compilation['rc'] != 0:
            raise RuntimeError(compilation)
        observed = capture([str(executable)])
        canary_results.append({'label': label, 'sourceSha256': digest(canary_source), **observed})
        if observed['rc'] != expected or 'wide-constant canary failures=' not in observed['stdout']:
            raise RuntimeError(f'runtime control did not match: {observed}')
    (out / 'runtime-controls.json').write_text(json.dumps(canary_results, indent=2) + '\n')
    records = []
    cap = int(os.environ.get('SMT2_REVIEW_CYCLES', '12000000'))
    repeats = int(os.environ.get('SMT2_REVIEW_REPEATS', '3'))
    if cap <= 0 or not 1 <= repeats <= 3:
        raise ValueError('positive cycle cap and 1..3 repeats required')
    observer = os.environ.get('SMT2_REVIEW_OBSERVER', 'off')
    observer_args = {'off': '', 'i1': ',+fetch_i1_check', 'flow': ',+smt_flow_trace',
                     'progress': ',+smt_progress'}
    if observer not in observer_args:
        raise ValueError('observer must be off, i1, flow or progress')
    plusargs = '--seed=1' + observer_args[observer]
    for repeat in range(repeats):
        trial = out / f'trial-{repeat}'
        trial.mkdir()
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(('SOFT_', 'PEEL_', 'CVA6_', 'G6LC_'))}
        env.update({'SOFT_LADDER_FETCH': 'B', 'SOFT_LADDER_SKIP_BUILD': '1',
                    'SOFT_LADDER_HARNESS': str(inputs), 'SOFT_LADDER_ELF': str(frozen_elf),
                    'SOFT_LADDER_OSBI_OUT': str(trial), 'SOFT_LADDER_TIME_OUT': str(cap),
                    'SOFT_LADDER_TOHOST': '0x' + symbols[0], 'SOFT_LADDER_PLUSARGS': plusargs,
                    'SOFT_LADDER_WALL_TIMEOUT': '900', 'CVA6_TRAP_DUMP': '1',
                    'CVA6_COOKIE_EXIT': '1', 'CVA6_SOAK_EXIT': '0',
                    'G6LC_RUN_ID': f'{out.parent.name}-trial-{repeat}'})
        print(f'SMT2_REVIEW start trial={repeat} cycles={cap}', flush=True)
        with (trial / 'driver.log').open('w') as log:
            result = subprocess.run(['bash', str(frozen_driver)], cwd=repo, env=env,
                                    stdout=log, stderr=subprocess.STDOUT, timeout=960)
        logs = list(trial.glob('veri_B_*.log'))
        if len(logs) != 1:
            raise RuntimeError(f'trial {repeat}: expected one simulation log')
        text = logs[0].read_text(errors='replace')
        driver_text = (trial / 'driver.log').read_text(errors='replace')
        pins = [line for line in text.splitlines() if line.startswith(
            ('[trapdump]', '[hangpc]', '[cookie-exit]', '[mc_gap]', '*** [mc_gap]', '*** [mc_verdict]'))]
        status = re.findall(r'CLASSIFY=(\w+).*?rc=(-?\d+)', driver_text)
        (trial / 'flow.log').write_text('\n'.join(line for line in text.splitlines()
                                                 if line.startswith('[smt-flow]')) + '\n')
        checks = [line for line in text.splitlines() if line.startswith('[fetch-i1]')]
        observed = any(line.startswith('[trapdump]') for line in pins) and any(
            line.startswith('[hangpc]') for line in pins)
        record = {'trial': repeat, 'driverRc': result.returncode, 'classification': status,
                  'observer': observer, 'plusargs': plusargs, 'observationPresent': observed,
                  'supplyChecks': checks if len(checks) <= 20 else checks[:20] + checks[-1:],
                  'hartProgress': [line for line in text.splitlines() if line.startswith('[smt-progress]')],
                  'pins': pins, 'logSha256': digest(logs[0]), 'cycleCap': cap,
                  'elapsedVerdicts': re.findall(r'\*\*\* (?:SUCCESS|FAILED).*', text),
                  'cookieGreen': result.returncode == 0 and len(status) == 1 and status[0][0] == 'SUCCESS'}
        records.append(record)
        (out / 'results.json').write_text(json.dumps(records, indent=2) + '\n')
        print(json.dumps(record), flush=True)
    for name, path in [('model', frozen_model), ('elf', frozen_elf), ('driver', frozen_driver)]:
        if digest(path) != evidence[name + 'Sha256']:
            raise RuntimeError(f'{name} changed during repeats')
    stable = all((r['pins'], r['elapsedVerdicts'], r['classification']) ==
                 (records[0]['pins'], records[0]['elapsedVerdicts'], records[0]['classification']) for r in records)
    summary = {'repeats': repeats, 'observer': observer,
               'sameObservedSignature': repeats > 1 and stable and all(r['observationPresent'] for r in records),
               'cookieGreen': all(r['cookieGreen'] for r in records),
               'perHartLivenessQualified': False, 'causalAttribution': False}
    (out / 'review-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print('SMT2_REVIEW ' + json.dumps(summary), flush=True)
    return 0 if summary['cookieGreen'] else 1


if __name__ == '__main__':
    sys.exit(main())
