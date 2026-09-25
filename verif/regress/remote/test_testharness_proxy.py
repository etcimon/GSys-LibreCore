# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

import testharness_proxy as proxy


class OoORunVerdictTests(unittest.TestCase):
    def test_explicit_completion_and_timeout(self):
        from run_ooo_fp_review import run_outcome
        self.assertEqual(run_outcome(0, '*** SUCCESS *** (tohost = 0) after 883 cycles', 5000), 'pass')
        self.assertEqual(run_outcome(0, '*** SUCCESS *** (tohost = 0) after 5000 cycles', 5000), 'timeout')
        self.assertEqual(run_outcome(1, '*** FAILED *** (tohost = 3) after 883 cycles', 5000), 'fail')

    def test_errors_are_not_hangs_or_passes(self):
        from run_ooo_fp_review import run_outcome
        success = '*** SUCCESS *** (tohost = 0) after 883 cycles'
        for rc, text in [(0, ''), (-6, 'Aborting'), (0, success + '\n%Error'),
                         (1, success), (0, success + '\n' + success),
                         (0, '*** SUCCESS *** without a completion record')]:
            with self.subTest(rc=rc, text=text):
                self.assertEqual(run_outcome(rc, text, 5000), 'error')
        failure = '*** FAILED *** (tohost = 2) after 988 cycles'
        for rc, text in [(-6, failure), (2, failure + '\n%Error'), (2, failure + '\n' + failure)]:
            self.assertEqual(run_outcome(rc, text, 5000), 'error')
        self.assertEqual(run_outcome(0, success.replace('tohost = 0', 'tohost = 0x3'), 5000), 'fail')
        with self.assertRaises(ValueError):
            run_outcome(0, success, 0)


class RetirementROIComparisonTests(unittest.TestCase):
    def fixture(self):
        return '\n'.join(['3 0x100 (0xf0000053) f 0 0xffffffff00000000',
                          '3 0x104 (0x00553027) mem 0x200 0x4031000000000000',
                          '3 0x108 (0x00100513) x 10 0x1',
                          '3 0x10c (0x00008067)'])

    def test_same_ordered_effects_in_both_trace_formats(self):
        from run_ooo_fp_review import retirement_roi
        rtl = self.fixture()
        reference = '\n'.join('core   0: ' + row for row in rtl.splitlines())
        rows = retirement_roi(rtl, 0x100, 0x10c)
        self.assertEqual(rows, retirement_roi(reference, 0x100, 0x10c))
        self.assertEqual(rows[0][3], [('f', 0, 0xffffffff00000000)])
        self.assertEqual(len(rows), 3)

    def test_dropped_reordered_duplicated_and_corrupt_effects_disagree(self):
        from run_ooo_fp_review import retirement_roi
        rows = self.fixture().splitlines()
        expected = retirement_roi(self.fixture(), 0x100, 0x10c)
        variants = [rows[:1] + rows[2:], rows[:1] + [rows[2], rows[1], rows[3]],
                    rows[:1] + rows, [rows[0].replace('00000000', '00000001'), *rows[1:]],
                    [rows[0], rows[1].replace('0x200', '0x208'), *rows[2:]]]
        for variant in variants:
            self.assertNotEqual(retirement_roi('\n'.join(variant), 0x100, 0x10c), expected)
        for incomplete in ('', '\n'.join(rows[1:]), '\n'.join(rows[:-1])):
            with self.assertRaises(ValueError):
                retirement_roi(incomplete, 0x100, 0x10c)


class FaultContextTests(unittest.TestCase):
    def test_keeps_generation_and_hart_without_counting_drops(self):
        from run_ooo_fault_review import fault_context
        rows = ['[smt-flow] retire cycle=10 port=0 id=3 gen=1 hart=1 pc=100 valid=1 drop=1 ex=0',
                '[smt-flow] retire cycle=11 port=0 id=3 gen=2 hart=1 pc=200 valid=1 drop=0 ex=0',
                '[smt-flow] retire cycle=12 port=0 id=4 gen=2 hart=0 pc=300 valid=1 drop=0 ex=0']
        result = fault_context(rows)
        self.assertEqual(result['retiredByHart'], {1: 1, 0: 1})
        self.assertEqual(result['lastRetirements'][1], [rows[1]])
        self.assertEqual(result['faultCandidates'], [])

    def test_fault_context_is_bounded_and_does_not_invent_committed_traps(self):
        from run_ooo_fault_review import fault_context
        prefix = [f'[smt-flow] control cycle={n} flush=0' for n in range(40)]
        fault = '[smt-flow] wb cycle=41 port=2 id=3 gen=2 hart=1 pc=200 issued=1 cancelled=1 data=0 ex=1'
        result = fault_context(prefix + [fault] + ['suffix'] * 20)
        event = result['faultCandidates'][0]
        self.assertEqual(event['event'], fault)
        self.assertEqual(len(event['before']), 24)
        self.assertEqual(len(event['after']), 12)
        self.assertIn('not all committed traps', result['scope'])


class SourceModelProvenanceTests(unittest.TestCase):
    def manifest(self):
        return {'target': 'g6lc64_smt2', 'modelSha256': 'a' * 64, 'harts': 2,
                'qualificationOnly': True, 'rc': 0,
                'sources': {'config_pkg.sv': {'originalSha256': 'b' * 64, 'reviewSha256': 'c' * 64}}}

    def test_experimental_binding_preserves_source_hashes(self):
        from run_opensbi_source_review import validate_model_manifest
        manifest = self.manifest()
        result = validate_model_manifest(manifest, 'a' * 64, True)
        self.assertEqual(result['modelSourceHashes'], manifest['sources'])
        self.assertFalse(result['protectedAnchor'])
        self.assertTrue(result['modelQualificationOnly'])

    def test_rejects_missing_conflicting_or_ambiguous_identity(self):
        from run_opensbi_source_review import validate_model_manifest
        variants = [dict(self.manifest(), harts=1), dict(self.manifest(), rc=1),
                    dict(self.manifest(), qualificationOnly='true'), dict(self.manifest(), sources={}),
                    dict(self.manifest(), executableSha256='d' * 64),
                    dict(self.manifest(), modelSha256='e' * 64),
                    dict(self.manifest(), sources={'config_pkg.sv': {'reviewSha256': 'c' * 64}})]
        for manifest in variants:
            with self.subTest(manifest=manifest), self.assertRaises(ValueError):
                validate_model_manifest(manifest, 'a' * 64, True)
        with self.assertRaises(ValueError):
            validate_model_manifest(self.manifest(), 'a' * 64, False)

    def test_default_manifest_stays_distinct(self):
        from run_opensbi_source_review import validate_model_manifest
        manifest = {'target': 'g6lc64_smt2', 'executableSha256': 'a' * 64,
                    'sources': {'core/cva6.sv': 'b' * 64}}
        result = validate_model_manifest(manifest, 'a' * 64, False)
        self.assertTrue(result['protectedAnchor'])
        with self.assertRaises(ValueError):
            validate_model_manifest(manifest, 'a' * 64, True)

    def test_timeout_is_not_completion_even_with_payload_markers(self):
        from run_opensbi_source_review import source_outcome
        self.assertEqual(source_outcome(0, '*** SUCCESS *** (tohost = 0) after 1000 cycles', True, 1000), 'timeout')
        self.assertEqual(source_outcome(0, '*** SUCCESS *** (tohost = 0) after 999 cycles', True, 1000), 'pass')
        self.assertEqual(source_outcome(0, '*** SUCCESS *** (tohost = 0) after 999 cycles', False, 1000), 'incomplete')
        self.assertEqual(source_outcome(124, '', False, 1000), 'timeout')
        self.assertEqual(source_outcome(-6, '%Error', False, 1000), 'error')


class SourceProfileVerdictTests(unittest.TestCase):
    def test_requires_supervisor_completion_from_both_harts(self):
        from run_opensbi_source_review import source_passed
        log = '[rvfi_tracer] INFO: Simulation terminated after 800 cycles'
        trace = '\n'.join(f'1 0x80200000 (0x00303023) mem {address:#x} 0x1'
                          for address in (0x80201000, 0x80201080, 0x80201088))
        self.assertTrue(source_passed(0, log, trace, {0: 10, 1: 20}, 0x80201000, 0x80201080))
        failures = [(1, log, trace, {0: 10, 1: 20}),
                    (0, '*** SUCCESS *** after 8000000 cycles', trace, {0: 10, 1: 20}),
                    (0, log, trace.replace('1 0x80200000', '3 0x80200000'), {0: 10, 1: 20}),
                    (0, log, '\n'.join(trace.splitlines()[:2]), {0: 10, 1: 20}),
                    (0, log, trace, {0: 10, 1: 0}),
                    (0, log, trace.replace('0x80201000 0x1', '0x80201000 0x3'), {0: 10, 1: 20})]
        for rc, output, events, counts in failures:
            with self.subTest(rc=rc, output=output, events=events, counts=counts):
                self.assertFalse(source_passed(rc, output, events, counts, 0x80201000, 0x80201080))

    def test_four_harts_over_two_cores_need_every_mark_and_both_cores(self):
        from run_opensbi_source_review import hart_progress, source_passed
        scope = 'TOP.ariane_testharness.i_cluster.gen_core[%d].i_ariane.gen_std.i_cva6.issue_stage_i.i_scoreboard'
        progress_lines = ''.join(f'[smt-progress] scope={scope % c} hart={h} retired={10 * (2 * c + h + 1)} last_pc=0\n'
                                 for c in (0, 1) for h in (0, 1))
        log = ('[rvfi_tracer] INFO: Simulation terminated after 800 cycles\n' + progress_lines +
               '*** [mc_verdict] all 2 core(s) retired instructions\n')
        progress = hart_progress(log, 4, 2)
        self.assertEqual(progress, {0: 10, 1: 20, 2: 30, 3: 40})
        # A scope without gen_core[] collapses onto core 0 and can never satisfy harts 2/3.
        flat = ''.join(f'[smt-progress] scope=TOP.sb{c} hart={h} retired=1\n' for c in (0, 1) for h in (0, 1))
        self.assertEqual(hart_progress(flat, 4, 2), {0: 1, 1: 1})
        # The anchor form (no scope) still reads as harts 0 and 1.
        self.assertEqual(hart_progress('[smt-progress] hart=0 retired=2\n[smt-progress] hart=1 retired=3\n', 2, 1), {0: 2, 1: 3})
        marks = lambda n: '\n'.join(f'1 0x80200000 (0x00303023) mem {a:#x} 0x1'
                                    for a in [0x80201000] + [0x80201080 + 8 * h for h in range(n)])
        self.assertTrue(source_passed(0, log, marks(4), progress, 0x80201000, 0x80201080, 4, 2))
        failures = [(log, marks(3), progress),
                    (log, marks(4), {0: 10, 1: 20, 2: 30}),
                    (log.replace('*** [mc_verdict] all 2 core(s) retired instructions\n', ''), marks(4), progress),
                    (log + '*** [mc_verdict] FAIL: core(s) retired no instruction, retired_mask=01 (exit code 127)\n',
                     marks(4), {0: 10, 1: 20})]
        for output, events, counts in failures:
            with self.subTest(output=output[-60:], events=events[-40:], counts=counts):
                self.assertFalse(source_passed(0, output, events, counts, 0x80201000, 0x80201080, 4, 2))
        # A two-hart profile ignores an unrelated fifth mark and never needs the cluster verdict.
        self.assertTrue(source_passed(0, log.splitlines()[0], marks(3), {0: 1, 1: 1}, 0x80201000, 0x80201080))


class BalanceMetricsTests(unittest.TestCase):
    def fixture(self):
        symbols = {'balance_begin0': 0x100, 'balance_begin1': 0x104,
                   'balance_loop': 0x110, 'balance_xor': 0x114, 'balance_dec': 0x118,
                   'balance_branch': 0x11c, 'balance_loop_end': 0x120,
                   'balance_end0': 0x130, 'balance_end1': 0x134}
        rows = []
        def add(hart, pc):
            rows.append(f'[smt-flow] retire cycle={len(rows) + 1} port=0 id=1 gen={len(rows)} '
                        f'hart={hart} pc={pc:016x} valid=1 drop=0 ex=0')
        add(0, 0x100)
        add(1, 0x104)
        for _ in range(2):
            for h in (0, 1):
                for pc in (0x110, 0x114, 0x118, 0x11c):
                    add(h, pc)
        add(0, 0x130)
        add(1, 0x134)
        return symbols, rows

    def test_checks_both_workers_without_claiming_fairness(self):
        from run_smt2_soak_review import balance_metrics
        symbols, rows = self.fixture()
        report = balance_metrics('\n'.join(rows), symbols, iterations=2)
        self.assertEqual(report['bodyRetirements'], {0: 8, 1: 8})
        self.assertEqual(report['commonRetirementShare'], {0: 0.5, 1: 0.5})
        self.assertFalse(report['boundedFairnessProven'])
        self.assertFalse(report['saturationQualified'])

    def test_rejects_missing_reordered_duplicated_or_wrong_owner_events(self):
        from run_smt2_soak_review import balance_metrics
        symbols, rows = self.fixture()
        mutations = [[], rows[:-1], rows[:2] + rows[3:], rows[:3] + [rows[2]] + rows[3:],
                     [rows[0].replace('hart=0', 'hart=1'), *rows[1:]],
                     rows[:2] + [rows[3], rows[2]] + rows[4:],
                     [rows[0].replace('cycle=1', 'cycle=oops'), *rows[1:]],
                     [r.replace('pc=0000000000000114', 'pc=0000000000000118') for r in rows],
                     [r.replace('hart=1', 'hart=2') for r in rows],
                     [r.replace('valid=1', 'valid=0') for r in rows]]
        for bad in mutations:
            with self.subTest(events=bad[:3]):
                with self.assertRaises(ValueError):
                    balance_metrics('\n'.join(bad), symbols, iterations=2)

    def test_solo_does_not_accept_peer_work(self):
        from run_smt2_soak_review import balance_metrics
        symbols, rows = self.fixture()
        solo = [r for r in rows if 'hart=0 ' in r]
        report = balance_metrics('\n'.join(solo), symbols, active_harts=(0,), iterations=2)
        self.assertEqual(report['activeHarts'], [0])
        with self.assertRaises(ValueError):
            balance_metrics('\n'.join(rows), symbols, active_harts=(0,), iterations=2)


class AsymmetricRoleMetricsTests(unittest.TestCase):
    def fixture(self, compute_iters=2, memory_iters=2):
        symbols = {'asym_begin0': 0x100, 'asym_begin1': 0x104,
                   'asym_cmp_add': 0x110, 'asym_cmp_xor': 0x112,
                   'asym_cmp_dec': 0x114, 'asym_cmp_branch': 0x116,
                   'asym_mem_load': 0x140, 'asym_mem_add': 0x144,
                   'asym_mem_step': 0x146, 'asym_mem_dec': 0x148,
                   'asym_mem_branch': 0x14a,
                   'asym_end0': 0x180, 'asym_end1': 0x184}
        rows = []

        def add(hart, pc):
            rows.append(f'[smt-flow] retire cycle={len(rows) + 1} port=0 id=1 gen={len(rows)} '
                        f'hart={hart} pc={pc:016x} valid=1 drop=0 ex=0')

        add(0, 0x100)
        add(1, 0x104)
        for _ in range(compute_iters):
            for pc in (0x110, 0x112, 0x114, 0x116):
                add(0, pc)
        for _ in range(memory_iters):
            for pc in (0x140, 0x144, 0x146, 0x148, 0x14a):
                add(1, pc)
        add(0, 0x180)
        add(1, 0x184)
        return symbols, rows

    def patched(self, compute_iters=2, memory_iters=2):
        import run_smt2_soak_review as runner
        return patch.dict(runner.ASYM_ITERATIONS,
                          {'compute': compute_iters, 'memory': memory_iters})

    def test_reports_each_role_separately(self):
        from run_smt2_soak_review import asym_metrics
        symbols, rows = self.fixture()
        with self.patched():
            report = asym_metrics('\n'.join(rows), symbols, {0: 'compute', 1: 'memory'})
        self.assertEqual(report['bodyRetirements'], {0: 8, 1: 10})
        self.assertEqual(report['roles'], {0: 'compute', 1: 'memory'})
        self.assertEqual(report['cyclesPerIteration'][0], report['roiCycles'][0] / 2)
        self.assertFalse(report['saturationQualified'])

    def test_core_window_is_not_the_sum_of_sibling_windows(self):
        from run_smt2_soak_review import asym_metrics
        symbols, rows = self.fixture()
        with self.patched():
            report = asym_metrics('\n'.join(rows), symbols, {0: 'compute', 1: 'memory'})
        self.assertEqual(report['coreWindow'], [1, 22])
        self.assertEqual(report['coreWindowCycles'], 22)
        self.assertEqual(report['roiWindows'], {0: [1, 21], 1: [2, 22]})
        self.assertEqual(report['coreBodyRetirements'], 18)

    def test_unassigned_role_body_cannot_hide_outside_the_expected_span(self):
        from run_smt2_soak_review import asym_metrics
        symbols, rows = self.fixture()
        foreign = [r.replace('hart=1', 'hart=0') for r in rows
                   if 'pc=0000000000000104' not in r and 'pc=0000000000000184' not in r]
        with self.patched():
            with self.assertRaises(ValueError):
                asym_metrics('\n'.join(foreign), symbols, {0: 'compute'})

    def test_a_solo_arm_rejects_peer_role_work(self):
        from run_smt2_soak_review import asym_metrics
        symbols, rows = self.fixture()
        with self.patched():
            with self.assertRaises(ValueError):
                asym_metrics('\n'.join(rows), symbols, {0: 'compute'})
            solo = [r for r in rows if 'hart=0 ' in r]
            report = asym_metrics('\n'.join(solo), symbols, {0: 'compute'})
        self.assertEqual(report['roles'], {0: 'compute'})

    def test_rejects_swapped_roles_and_wrong_iteration_counts(self):
        from run_smt2_soak_review import asym_metrics
        symbols, rows = self.fixture()
        with self.patched():
            with self.assertRaises(ValueError):
                asym_metrics('\n'.join(rows), symbols, {0: 'memory', 1: 'compute'})
            with self.assertRaises(ValueError):
                asym_metrics('\n'.join(rows[:-3]), symbols, {0: 'compute', 1: 'memory'})
            with self.assertRaises(ValueError):
                asym_metrics('\n'.join(rows), symbols, {0: 'compute', 1: 'wizardry'})
        with self.patched(memory_iters=3):
            with self.assertRaises(ValueError):
                asym_metrics('\n'.join(rows), symbols, {0: 'compute', 1: 'memory'})


class IdleSiblingIpiTests(unittest.TestCase):
    def rows(self, peer_body=False):
        symbols = {'ipi_begin0': 0x200, 'ipi_end0': 0x230,
                   'ipi_loop': 0x210, 'ipi_dec': 0x212, 'ipi_branch': 0x214}
        events = [(10, 0, 0x200)]
        events += [(11 + i, 0, pc) for i, pc in enumerate([0x210, 0x212, 0x214] * 2)]
        if peer_body:
            events.append((18, 1, 0x210))
        events.append((20, 0, 0x230))
        return symbols, [f'[smt-flow] retire cycle={c} port=0 id=1 gen=0 hart={h} '
                         f'pc={pc:016x} valid=1 drop=0 ex=0' for c, h, pc in events]

    def patched(self):
        import run_smt2_soak_review as runner
        return patch.object(runner, 'IPI_ITERATIONS', 2)

    def test_measures_region_with_a_halted_peer(self):
        from run_smt2_soak_review import ipi_metrics
        symbols, rows = self.rows()
        with self.patched():
            report = ipi_metrics('\n'.join(rows), symbols, True)
        self.assertEqual(report['roiCycles'], 11)
        self.assertEqual(report['peerBodyRetirements'], 0)

    def test_halted_peer_executing_work_is_refused(self):
        from run_smt2_soak_review import ipi_metrics
        symbols, rows = self.rows(peer_body=True)
        with self.patched():
            with self.assertRaises(ValueError):
                ipi_metrics('\n'.join(rows), symbols, True)


class LockMutualExclusionTests(unittest.TestCase):
    def rows(self, first_end=40, second_begin=50):
        symbols = {'lock_begin0': 0x100, 'lock_begin1': 0x104,
                   'lock_loop': 0x110, 'lock_dec': 0x112, 'lock_branch': 0x114,
                   'lock_end0': 0x130, 'lock_end1': 0x134}
        events = [(10, 0, 0x100)]
        events += [(11 + i, 0, pc) for i, pc in enumerate([0x110, 0x112, 0x114] * 2)]
        events += [(first_end, 0, 0x130), (second_begin, 1, 0x104)]
        events += [(second_begin + 1 + i, 1, pc)
                   for i, pc in enumerate([0x110, 0x112, 0x114] * 2)]
        events += [(second_begin + 20, 1, 0x134)]
        return symbols, [f'[smt-flow] retire cycle={c} port=0 id=1 gen=0 hart={h} '
                         f'pc={pc:016x} valid=1 drop=0 ex=0' for c, h, pc in events]

    def patched(self):
        import run_smt2_soak_review as runner
        return patch.object(runner, 'LOCK_ITERATIONS', 2)

    def test_measures_each_section_and_confirms_exclusion(self):
        from run_smt2_soak_review import lock_metrics
        symbols, rows = self.rows()
        with self.patched():
            report = lock_metrics('\n'.join(rows), symbols)
        self.assertTrue(report['mutualExclusionHeld'])
        self.assertEqual(report['criticalSectionCycles'][0], 31)

    def test_overlapping_sections_are_refused(self):
        from run_smt2_soak_review import lock_metrics
        symbols, rows = self.rows(first_end=80, second_begin=50)
        with self.patched():
            with self.assertRaises(ValueError):
                lock_metrics('\n'.join(rows), symbols)


class SharedCoreCapacityTests(unittest.TestCase):
    def fixture(self):
        shared = {'roiCycles': {0: 20, 1: 30}, 'coreWindowCycles': 30,
                  'overlapCycles': 20, 'roles': {0: 'compute', 1: 'memory'}}
        swapped = {**shared, 'roiCycles': {0: 30, 1: 20},
                   'roles': {0: 'memory', 1: 'compute'}}
        reports = {'shared-cm': shared, 'shared-mc': swapped,
                   'solo-c0': {'roiCycles': {0: 10}}, 'solo-m0': {'roiCycles': {0: 12}},
                   'solo-c1': {'roiCycles': {1: 11}}, 'solo-m1': {'roiCycles': {1: 15}}}
        return {name: {'matched': True, 'textSha256': 'same', 'asymMetrics': report}
                for name, report in reports.items()}

    def test_pairs_same_hart_controls_and_one_core_denominator(self):
        from run_smt2_soak_review import asym_capacity
        report = asym_capacity(self.fixture())
        first, second = (report['batches'][name] for name in ('shared-cm', 'shared-mc'))
        self.assertEqual(first['slowdownByHart'], {0: 2, 1: 2})
        self.assertEqual(second['slowdownByHart'], {0: 2.5, 1: 20 / 11})
        self.assertEqual(first['batchSpeedupVsSerialSolo'], 25 / 30)
        self.assertEqual(first['nonOverlapCycles'], 10)
        self.assertFalse(report['softwareHintAbiImplemented'])

    def test_missing_failed_or_mismatched_controls_do_not_qualify(self):
        from run_smt2_soak_review import asym_capacity
        records = self.fixture()
        records.pop('solo-c1')
        self.assertFalse(asym_capacity(records)['pairedSoloComparisonAvailable'])
        records = self.fixture()
        records['solo-m0']['matched'] = False
        self.assertFalse(asym_capacity(records)['pairedSoloComparisonAvailable'])
        records = self.fixture()
        records['solo-m1']['textSha256'] = 'different'
        with self.assertRaises(ValueError):
            asym_capacity(records)


class SchedulerAttributionTests(unittest.TestCase):
    def trace(self):
        return ['[smt-sched] state cycle=10 active=0 ready=11 dmiss=00 imiss=00 block=00 '
                'quiesce=0 hold=0 trap=0 flush=0',
                '[smt-sched] decide cycle=14 from=0 to=1 reason=0010',
                '[smt-sched] state cycle=15 active=0 ready=11 dmiss=00 imiss=00 block=00 '
                'quiesce=1 hold=0 trap=0 flush=0',
                '[smt-sched] switch cycle=17 from=0 to=1 reason=0010 waited=3',
                '[smt-sched] state cycle=18 active=1 ready=10 dmiss=00 imiss=00 block=01 '
                'quiesce=0 hold=0 trap=0 flush=0']

    def test_attributes_service_denial_and_handoff_cost(self):
        from run_smt2_soak_review import sched_metrics
        report = sched_metrics('\n'.join(self.trace()), (10, 27))
        self.assertEqual(report['selectedCycles'], {0: 8, 1: 10})
        self.assertEqual(report['eligibleUnselectedCycles'], {0: 0, 1: 8})
        self.assertEqual(report['ineligibleUnselectedCycles'], {0: 10, 1: 0})
        self.assertEqual(report['longestReadyDenial'], {0: 0, 1: 8})
        self.assertEqual(report['quiesceCycles'], 3)
        self.assertEqual(report['switchReasons'],
                         {'yield': 0, 'miss': 0, 'quantum': 1, 'starve': 0})
        self.assertEqual(report['switchDrainWait'], {'samples': 1, 'total': 3, 'max': 3})
        self.assertFalse(report['fairnessBoundProven'])
        self.assertFalse(report['unfinishedDecisionAtEnd'])

    def test_selected_cycles_do_not_claim_accepted_work(self):
        from run_smt2_soak_review import sched_metrics
        report = sched_metrics('\n'.join(self.trace()), (10, 27))
        self.assertEqual(sum(report['selectedCycles'].values()), report['windowCycles'])
        self.assertFalse(report['acceptedServiceMeasured'])
        self.assertNotIn('servedCycles', report)

    def test_events_outside_the_window_do_not_count_as_service(self):
        from run_smt2_soak_review import sched_metrics
        report = sched_metrics('\n'.join(self.trace()), (20, 29))
        self.assertEqual(report['selectedCycles'], {0: 0, 1: 10})
        self.assertEqual(report['handoffCounts'], {'decide': 0, 'switch': 0, 'abort': 0})

    def test_rejects_inconsistent_or_unusable_observations(self):
        from run_smt2_soak_review import sched_metrics
        rows = self.trace()
        for bad in ([], [rows[0]] + [rows[0].replace('cycle=10', 'cycle=9')],
                    [rows[0], rows[3]], [rows[0], rows[1], rows[1]],
                    [rows[0], rows[1], rows[3].replace('waited=3', 'waited=2')],
                    [rows[0], rows[1], rows[3].replace('to=1', 'to=0')],
                    [rows[0].replace('active=0', 'active=5')],
                    [rows[0].replace('ready=11', 'ready=1x')],
                    [rows[0], rows[1].replace('reason=0010', 'reason=0000'), rows[3]
                     .replace('reason=0010', 'reason=0000')],
                    [rows[0], '[smt-sched] switch cycle=17 from=0 to=1 reason=0010']):
            with self.subTest(rows=bad[-1:]):
                with self.assertRaises(ValueError):
                    sched_metrics('\n'.join(bad), (10, 27))

    def test_aborted_handoff_is_not_reported_as_a_switch(self):
        from run_smt2_soak_review import sched_metrics
        rows = [self.trace()[0], self.trace()[1],
                '[smt-sched] abort cycle=17 from=0 to=1 reason=0010 waited=3']
        report = sched_metrics('\n'.join(rows), (10, 27))
        self.assertEqual(report['handoffCounts'], {'decide': 1, 'switch': 0, 'abort': 1})
        self.assertEqual(report['switchDrainWait']['samples'], 0)


class LoadLatencyAttributionTests(unittest.TestCase):
    def test_pairs_requests_and_reports_per_hart_latency(self):
        from run_smt2_soak_review import rtt_metrics
        rows = ['[smt-rtt] req cycle=100 tag=0 idx=1000 active=0',
                '[smt-rtt] resp cycle=104 tag=0 active=0',
                '[smt-rtt] req cycle=110 tag=1 idx=2000 active=1',
                '[smt-rtt] resp cycle=150 tag=1 active=1']
        report = rtt_metrics('\n'.join(rows), (100, 200))
        self.assertEqual(report['completedSamples'], {0: 1, 1: 1})
        self.assertEqual(report['latencyMax'], {0: 4, 1: 40})
        self.assertEqual(report['buckets'][1][32], 0)
        self.assertEqual(report['buckets'][1][64], 1)
        self.assertFalse(report['levelAttributionProven'])

    def test_classifies_stale_killed_crossed_and_outstanding_separately(self):
        from run_smt2_soak_review import rtt_metrics
        rows = ['[smt-rtt] resp cycle=99 tag=7 active=0',
                '[smt-rtt] req cycle=100 tag=0 idx=1000 active=0',
                '[smt-rtt] resp cycle=104 tag=0 active=0',
                '[smt-rtt] req cycle=105 tag=1 idx=3000 active=0',
                '[smt-rtt] kill cycle=106 tag=1 active=0',
                '[smt-rtt] resp cycle=108 tag=1 active=0',
                '[smt-rtt] req cycle=110 tag=2 idx=4000 active=0',
                '[smt-rtt] resp cycle=140 tag=2 active=1',
                '[smt-rtt] req cycle=150 tag=3 idx=5000 active=1']
        report = rtt_metrics('\n'.join(rows), (100, 200))
        self.assertEqual(report['completedSamples'], {0: 1, 1: 0})
        self.assertEqual((report['staleResponses'], report['killedResponses']), (1, 1))
        self.assertEqual((report['crossSwitchCensored'], report['outstandingAtEnd']), (1, 1))

    def test_rejects_reissue_disorder_and_a_dead_observer(self):
        from run_smt2_soak_review import rtt_metrics
        good = ['[smt-rtt] req cycle=100 tag=0 idx=1000 active=0',
                '[smt-rtt] resp cycle=104 tag=0 active=0']
        for bad in ([], [good[0], good[0]], [good[1], good[0]],
                    ['[smt-rtt] req cycle=100 tag=0 active=0'],
                    [good[0].replace('idx=1000', 'idx=10g0'), good[1]],
                    [good[0].replace('active=0', 'active=4'), good[1]]):
            with self.subTest(rows=bad[-1:]):
                with self.assertRaises(ValueError):
                    rtt_metrics('\n'.join(bad), (100, 200))

    def test_outstanding_is_measured_at_window_end_not_at_trace_end(self):
        from run_smt2_soak_review import rtt_metrics
        rows = ['[smt-rtt] req cycle=100 tag=0 idx=1000 active=0',
                '[smt-rtt] resp cycle=104 tag=0 active=0',
                '[smt-rtt] req cycle=150 tag=1 idx=2000 active=1',
                '[smt-rtt] resp cycle=250 tag=1 active=1']
        report = rtt_metrics('\n'.join(rows), (100, 200))
        self.assertEqual(report['outstandingAtEnd'], 1)
        self.assertEqual(report['outstandingAgesAtEnd'], {0: [], 1: [50]})
        self.assertEqual(report['completedSamples'], {0: 1, 1: 0})

    def test_a_window_performing_no_load_is_reported_not_rejected(self):
        from run_smt2_soak_review import rtt_metrics
        report = rtt_metrics('\n'.join(['[smt-rtt] req cycle=10 tag=0 idx=1000 active=0',
                                        '[smt-rtt] resp cycle=14 tag=0 active=0']), (100, 200))
        self.assertEqual(report['completedSamples'], {0: 0, 1: 0})
        self.assertEqual(report['observedEvents'], 2)
        self.assertEqual(report['latencyMax'], {0: None, 1: None})


class FetchBSourceBoundaryTests(unittest.TestCase):
    def test_generated_sources_refuse_legacy_inputs(self):
        from run_smt2_soak_review import check_fetch_b_sources
        clean = '/repo/core/fetch_B/frontend.sv /repo/core/smt/g6lc_issue_barrier.sv'
        check_fetch_b_sources(clean)
        check_fetch_b_sources(clean.replace('/', '\\'))
        for path in ('/repo/core/fetch_A/frontend/frontend.sv',
                     '/repo/core/smt_legacy/g6lc_issue_barrier.sv',
                     '/repo/core/Flist.smt_legacy'):
            with self.subTest(path=path):
                with self.assertRaises(RuntimeError):
                    check_fetch_b_sources(clean + ' ' + path)
                with self.assertRaises(RuntimeError):
                    check_fetch_b_sources((clean + ' ' + path).replace('/', '\\'))
        with self.assertRaises(RuntimeError):
            check_fetch_b_sources('/repo/core/smt/g6lc_issue_barrier.sv')

    def test_active_manifests_exclude_legacy_paths(self):
        root = Path(__file__).resolve().parents[3]
        variables = {'CVA6_REPO_DIR': root.as_posix(), 'TARGET_CFG': 'g6lc64_smt2',
                     'HPDCACHE_DIR': (root / 'core/cache_subsystem/hpdcache').as_posix()}
        visited = set()
        sources = []

        def visit(path):
            path = path.resolve()
            if path in visited:
                return
            visited.add(path)
            for raw in path.read_text(encoding='utf-8').splitlines():
                line = raw.split('//', 1)[0].strip()
                if not line:
                    continue
                for key, value in variables.items():
                    line = line.replace('${' + key + '}', value)
                self.assertNotRegex(line, r'(?:^|/)(?:fetch_A|smt_legacy)(?:/|$)')
                self.assertNotIn('Flist.smt_legacy', line)
                if line.startswith(('-f ', '-F ')):
                    nested = Path(line[3:].strip())
                    visit(nested if nested.is_absolute() else path.parent / nested)
                elif not line.startswith('+'):
                    source = Path(line)
                    source = source if source.is_absolute() else path.parent / source
                    self.assertTrue(source.is_file(), str(source))
                    sources.append(source.resolve())

        visit(root / 'core/Flist.cva6')
        self.assertIn((root / 'core/fetch_B/frontend.sv').resolve(), sources)
        self.assertEqual(len([p for p in sources if p.parent == (root / 'core/smt').resolve()]), 9)


class ArtifactTransferTests(unittest.TestCase):
    def remote(self):
        remote = proxy.Remote.__new__(proxy.Remote)
        remote.host = 'test-host'
        remote.base_opts = lambda: []
        return remote

    def test_pull_failure_is_not_success(self):
        result = subprocess.CompletedProcess(['rsync'], 11)
        with patch.object(proxy.subprocess, 'run', return_value=result):
            with self.assertRaises(subprocess.CalledProcessError) as error:
                self.remote().pull('/run/output/', Mock())
        self.assertEqual(error.exception.returncode, 11)

    def test_successful_pull(self):
        result = subprocess.CompletedProcess(['rsync'], 0)
        with patch.object(proxy.subprocess, 'run', return_value=result):
            self.remote().pull('/run/output/', Mock())

    def test_py_destination_option(self):
        args = proxy.build_parser().parse_args(['py', 'script.py', '--pull', '--dest', '/artifacts/run/output'])
        self.assertTrue(args.pull)
        self.assertEqual(args.dest, '/artifacts/run/output')

    def test_py_default_destination(self):
        args = proxy.build_parser().parse_args(['py', 'script.py', '--pull'])
        self.assertIsNone(args.dest)

    def test_pull_one_existing_run(self):
        args = proxy.build_parser().parse_args(['pull', '--tag', 'selected-run', '--dest', '/artifacts/run'])
        remote = Mock(host='test-host')
        self.assertEqual(proxy.cmd_pull(remote, args), 0)
        remote.pull.assert_called_once_with(f'{proxy.REMOTE_ROOT}/runs/selected-run/output/', Path('/artifacts/run'))

    def test_pull_rejects_path_traversal(self):
        args = proxy.build_parser().parse_args(['pull', '--tag', '../other'])
        remote = Mock(host='test-host')
        with self.assertRaises(SystemExit):
            proxy.cmd_pull(remote, args)
        remote.start_master.assert_not_called()


@unittest.skipUnless(shutil.which('bash'), 'bash is required for soak-driver tests')
class SoakDriverTests(unittest.TestCase):
    def run_driver(self, text, rc=0, *, missing_harness=False, missing_hold=False):
        with tempfile.TemporaryDirectory(prefix='soak-oracle-') as tmp:
            root = Path(tmp)
            scripts = root / 'verif' / 'regress'
            scripts.mkdir(parents=True)
            driver = scripts / 'soft-ladder-opensbi-soak.sh'
            original = Path(__file__).resolve().parents[1] / driver.name
            driver.write_bytes(original.read_bytes())
            model = root / 'work-ver-smt2'
            model.mkdir()
            harness = model / 'Variane_testharness'
            harness.write_text(
                "#!/usr/bin/env bash\nprintf '%s\\n' \"$FAKE_SOAK_LOG\"\nexit \"$FAKE_SOAK_RC\"\n",
                encoding='utf-8', newline='\n')
            harness.chmod(0o755)
            firmware = root / 'firmware' / 'build'
            firmware.mkdir(parents=True)
            elf = firmware / 'fw_payload_r3a_c15_plat_skip.elf'
            elf.write_bytes(b'fake ELF for runner-only oracle tests')
            env = {k: v for k, v in os.environ.items()
                   if not k.startswith(('SOFT_', 'PEEL_', 'CVA6_', 'G6LC_'))}
            env.update({
                'SOFT_LADDER_SKIP_BUILD': '1',
                'SOFT_LADDER_FETCH': 'B',
                'SOFT_LADDER_HARNESS': str(root / 'missing' if missing_harness else model),
                'SOFT_LADDER_DIR': str(firmware.parent),
                'SOFT_LADDER_OSBI_OUT': str(root / 'logs'),
                'SOFT_LADDER_WALL_TIMEOUT': '5',
                'FAKE_SOAK_LOG': text,
                'FAKE_SOAK_RC': str(rc),
            })
            if missing_hold:
                env['SOFT_LADDER_HOLD'] = '1'
            else:
                env['SOFT_LADDER_ELF'] = str(elf)
            return subprocess.run(['bash', str(driver)], env=env, cwd=root,
                                  capture_output=True, text=True, timeout=15)

    def test_cookie_success(self):
        for text in ('[cookie-exit] t=42 [1000]=0x51b1babe',
                     '[trapdump] [1000]=0000000051b1babe [1008]=0',
                     '[cookie-exit] t=42 [1000]=0x51b1babe00000000'):
            with self.subTest(text=text):
                result = self.run_driver(text)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('CLASSIFY=SUCCESS', result.stdout)

    def test_process_failure_preserves_status(self):
        result = self.run_driver('[trapdump] [1000]=0', 17)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('rc=17', result.stdout)

    def test_timeout_banner_is_not_success(self):
        result = self.run_driver('*** SUCCESS *** (tohost = 0) after 12000000 cycles')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('CLASSIFY=SUCCESS', result.stdout)

    def test_partial_or_unbound_cookie_is_not_success(self):
        for text in ('[cookie-exit] t=42 [1000]=0x51b1c001',
                     '[cookie-exit] t=42',
                     '[trapdump] [1000]=151b1babe0',
                     '[trapdump] [1000]=0 [1008]=51b1babe'):
            with self.subTest(text=text):
                result = self.run_driver(text)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertNotIn('CLASSIFY=SUCCESS', result.stdout)

    def test_cookie_does_not_hide_harness_failure(self):
        for rc in (124, 126, 127, 134, 137):
            with self.subTest(rc=rc):
                result = self.run_driver('[trapdump] [1000]=51b1babe', rc)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn(f'rc={rc}', result.stdout)
                self.assertNotIn('CLASSIFY=SUCCESS', result.stdout)

    def test_explicit_missing_model_cannot_fall_back(self):
        result = self.run_driver('[trapdump] [1000]=51b1babe', missing_harness=True)
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertNotIn('CLASSIFY=SUCCESS', result.stdout)

    def test_missing_hold_cannot_use_natural_payload(self):
        result = self.run_driver('[trapdump] [1000]=51b1babe', missing_hold=True)
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertNotIn('CLASSIFY=SUCCESS', result.stdout)


class CompilerControlPreflightTests(unittest.TestCase):
    EXPECTED = 'be176b279ada076a3459d8bd6509e0946ccf0994d5c35a092bede308bba8c8ff'
    VERFILES = ('C "--no-timing -j 8 '
                '/opt/testharness/runs/x/source/split-counter.vlt '
                'verilator_config.vlt --assert -f core/Flist.cva6"\n'
                'S 104 1 2 3 4 5 "/opt/testharness/runs/x/source/split-counter.vlt"\n')

    def failures(self, control, verfiles=None, exists=True, digest=None, waive=False):
        from run_opensbi_source_review import compiler_control_failures
        if verfiles is None:
            verfiles = self.VERFILES
        return compiler_control_failures(control, verfiles, exists, digest, waive)

    def test_missing_env_refuses_on_all_three_checks(self):
        failures = self.failures(None, exists=False)
        self.assertIn('control-supplied-and-present', failures)
        self.assertIn('control-sha256-mismatch', failures)
        self.assertIn('control-absent-from-verfiles', failures)

    def test_missing_file_is_reported(self):
        failures = self.failures('/nope/split-counter.vlt', exists=False)
        self.assertIn('control-supplied-and-present', failures)
        self.assertIn('control-sha256-mismatch', failures)

    def test_hash_mismatch_is_reported(self):
        failures = self.failures('/opt/testharness/runs/x/source/split-counter.vlt', digest='0' * 64)
        self.assertEqual(failures, ['control-sha256-mismatch'])

    def test_absent_from_verfiles_is_reported(self):
        failures = self.failures('/opt/ctl/other.vlt', digest=self.EXPECTED)
        self.assertEqual(failures, ['control-absent-from-verfiles'])

    def test_the_pinned_control_passes(self):
        failures = self.failures('/opt/testharness/runs/x/source/split-counter.vlt',
                                 digest=self.EXPECTED)
        self.assertEqual(failures, [])

    def test_wrong_path_substring_and_command_only_are_rejected(self):
        control = '/opt/testharness/runs/x/source/split-counter.vlt'
        for verfiles in (self.VERFILES.replace('/runs/x/', '/runs/y/'),
                         self.VERFILES.replace('split-counter.vlt', 'split-counter.vlt.bak'),
                         self.VERFILES.splitlines()[0], '', 'C "unterminated'):
            with self.subTest(verfiles=verfiles):
                self.assertIn('control-absent-from-verfiles',
                              self.failures(control, verfiles=verfiles, digest=self.EXPECTED))

    def test_waiver_suppresses_the_refusal(self):
        self.assertEqual(self.failures(None, exists=False, waive=True), [])

    def test_refusal_emits_results_and_exits_nonzero(self):
        from run_opensbi_source_review import refuse
        with tempfile.TemporaryDirectory() as td:
            out = Path(td)
            model = out / 'Variane_testharness'
            model.write_bytes(b'not a real model')
            provenance = {'protectedAnchor': True, 'experimentalModel': False,
                          'controlWaived': False}
            rc = refuse(model, out, provenance,
                        ['control-supplied-and-present'], None, None)
            result = json.loads((out / 'results.json').read_text())
        self.assertNotEqual(rc, 0)
        self.assertEqual(result['outcome'], 'refused')
        self.assertFalse(result['strictDualPassed'])
        self.assertFalse(result['timedOut'])
        self.assertEqual(result['refusedChecks'], ['control-supplied-and-present'])
        self.assertTrue(result['protectedAnchor'])

    def test_waiver_forfeits_the_anchor(self):
        from run_opensbi_source_review import apply_control_waiver
        provenance = {'protectedAnchor': True, 'controlWaived': False}
        apply_control_waiver(provenance, True)
        self.assertFalse(provenance['protectedAnchor'])
        self.assertTrue(provenance['controlWaived'])
        unprotected = {'protectedAnchor': False, 'controlWaived': False}
        apply_control_waiver(unprotected, True)
        self.assertFalse(unprotected['controlWaived'])


class BuildRecipeRecordTests(unittest.TestCase):
    VERFILES = ('C "--no-timing -Wno-MODDUP -j 8 '
                '/opt/testharness/runs/x/source/split-counter.vlt '
                '--no-timing verilator_config.vlt --assert -f core/Flist.cva6 '
                '/opt/testharness/repo/core/cva6.sv"\n'
                'S     11679  2366279  1787406472  585263775  1784498372  0 '
                '"/opt/testharness/repo/core/cva6.sv"\n'
                'S      2217  2366388  1787797557  942437603  1787797547  76752700 '
                '"verilator_config.vlt"\n')

    class FakeRemote:
        def __init__(self, verfiles, digest='d' * 64, version='Verilator 5.008'):
            self.verfiles = verfiles
            self.digest = digest
            self.version = version

        def out(self, script):
            if 'verFiles.dat' in script:
                return self.verfiles
            if 'sha256sum' in script:
                return self.digest
            if 'build.log' in script:
                return self.version
            return ''

    def args(self):
        return argparse.Namespace(
            flavour='B', target='g6lc64_smt2', jobs=None, vthreads=1,
            env=['SOFT_LADDER_BUILD_VLT_ARGS=/opt/testharness/runs/x/source/split-counter.vlt'])

    def test_recipe_carries_command_controls_and_tool_versions(self):
        recipe = proxy.build_recipe_record(
            self.FakeRemote(self.VERFILES), Path('.'), self.args(), 'work-ver-x')
        for key in ('verilatorCommand', 'verFilesSha256', 'verFilesEntries',
                    'compilerControls', 'extraVerilatorArgs', 'buildEnv',
                    'defines', 'target', 'flavour', 'verlib',
                    'verilatorVersion', 'proxySha256', 'jobs', 'vthreads'):
            self.assertIn(key, recipe)
        self.assertIn('--no-timing', recipe['verilatorCommand'])
        self.assertIn('split-counter.vlt', recipe['verilatorCommand'])
        self.assertEqual(recipe['verFilesEntries'], 2)
        self.assertEqual(
            [c['path'] for c in recipe['compilerControls']],
            ['/opt/testharness/runs/x/source/split-counter.vlt', 'verilator_config.vlt'])
        self.assertEqual(recipe['compilerControls'][0]['sha256'], 'd' * 64)
        self.assertEqual(recipe['extraVerilatorArgs'],
                         '/opt/testharness/runs/x/source/split-counter.vlt')
        self.assertEqual(recipe['target'], 'g6lc64_smt2')
        self.assertEqual(recipe['verilatorVersion'], 'Verilator 5.008')
        self.assertEqual(recipe['vthreads'], '1')
        self.assertEqual(recipe['jobs'], 'nproc')
        self.assertIsNotNone(recipe['proxySha256'])

    def test_an_unhashable_control_fails_closed(self):
        rem = self.FakeRemote(self.VERFILES, digest=None)
        with self.assertRaises(SystemExit):
            proxy.build_recipe_record(rem, Path('.'), self.args(), 'work-ver-x')

    def test_missing_command_dependencies_and_version_fail_closed(self):
        for contents, version in [('', 'Verilator 5.008'),
                                  (self.VERFILES.splitlines()[0], 'Verilator 5.008'),
                                  (self.VERFILES + self.VERFILES, 'Verilator 5.008'),
                                  (self.VERFILES, '')]:
            with self.subTest(contents=contents, version=version), self.assertRaises(SystemExit):
                proxy.build_recipe_record(self.FakeRemote(contents, version=version),
                                          Path('.'), self.args(), 'work-ver-x')


class SourceTraceStreamingTests(unittest.TestCase):
    def test_streamed_stores_keep_strict_completion_contract(self):
        from run_opensbi_source_review import source_passed
        log = '[rvfi_tracer] INFO: Simulation terminated after 800 cycles'
        rows = [f'1 0x80200000 (0x00303023) mem {address:#x} 0x1\n'
                for address in (0x80201000, 0x80201080, 0x80201088)]
        self.assertTrue(source_passed(0, log, iter(rows), {0: 10, 1: 20},
                                      0x80201000, 0x80201080))
        self.assertFalse(source_passed(0, log, iter(rows[:2]), {0: 10, 1: 20},
                                       0x80201000, 0x80201080))

    def compare(self, reference, current, extend=False):
        from run_opensbi_source_review import compare_reference
        with tempfile.TemporaryDirectory() as td:
            prior, trial = Path(td) / 'prior', Path(td) / 'trial'
            prior.write_text(reference)
            trial.write_text(current)
            return compare_reference(prior, trial, extend)

    def test_exact_replay_records_identity_not_an_independent_oracle(self):
        result = self.compare('a\nb\n', 'a\nb\n')
        self.assertEqual(result['status'], 'pass')
        self.assertEqual(result['matchedLines'], 2)
        self.assertEqual(len(result['sha256']), 64)
        self.assertFalse(result['independentArchitecturalOracle'])

    def test_dropped_extra_changed_and_empty_traces_fail(self):
        for reference, current, line in [('a\nb\n', 'a\n', 2),
                                         ('a\n', 'a\nb\n', 2),
                                         ('a\nb\n', 'a\nc\n', 2),
                                         ('', '', 1)]:
            with self.subTest(reference=reference, current=current):
                result = self.compare(reference, current)
                self.assertEqual(result['status'], 'fail')
                self.assertEqual(result['mismatchLine'], line)

    def test_extension_requires_a_nonempty_matching_prefix_and_more_work(self):
        self.assertEqual(self.compare('a\n', 'a\nb\n', True)['status'], 'pass')
        for prior, current in [('a\n', 'a\n'), ('a\nb\n', 'a\n'),
                               ('a\n', 'b\nc\n'), ('', 'a\n')]:
            with self.subTest(prior=prior, current=current):
                self.assertEqual(self.compare(prior, current, True)['status'], 'fail')


class SourceTrialVerdictTests(unittest.TestCase):
    def test_reference_failures_produce_structured_nonpasses(self):
        from run_opensbi_source_review import trial_verdict
        log = ('[rvfi_tracer] INFO: Simulation terminated after 80 cycles\n'
               '[smt-progress] hart=0 retired=2\n[smt-progress] hart=1 retired=3\n'
               '*** SUCCESS *** (tohost = 0) after 100 cycles\n')
        symbols = '00000200 T tohost\n00000300 T strict_seen\n'
        rows = ''.join(f'1 0x100 (0x00303023) mem {a:#x} 0x1\n' for a in (0x200, 0x300, 0x308))
        with tempfile.TemporaryDirectory() as td:
            trace, reference = Path(td) / 'trace', Path(td) / 'reference'
            trace.write_text(rows)
            reference.write_text(rows)
            result = trial_verdict(0, log, [trace], symbols, 1000, reference)
            self.assertEqual(result['outcome'], 'pass')
            self.assertTrue(result['strictDualPassed'])
            reference.write_text(rows.replace('0x100', '0x104'))
            result = trial_verdict(0, log, [trace], symbols, 1000, reference)
            self.assertEqual(result['outcome'], 'fail')
            self.assertFalse(result['strictDualPassed'])
            self.assertEqual(result['referencePrefix']['mismatchLine'], 1)
            result = trial_verdict(0, log, [trace], symbols, 1000, Path(td) / 'missing')
            self.assertEqual(result['outcome'], 'error')
            self.assertFalse(result['strictDualPassed'])
            reference.write_text(rows)
            trace.write_text(rows.splitlines(keepends=True)[0])
            result = trial_verdict(0, log, [trace], symbols, 1000, reference)
            self.assertEqual(result['outcome'], 'incomplete')
            self.assertEqual(result['referencePrefix']['status'], 'fail')
            result = trial_verdict(124, log, [trace], symbols, 1000, reference)
            self.assertEqual(result['outcome'], 'timeout')
            self.assertTrue(result['timedOut'])
            self.assertEqual(result['terminationPath'], 'wall-budget')

    def test_missing_control_refuses_before_execute_even_without_verfiles(self):
        import run_opensbi_source_review as runner
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            out, data = root / 'out', root / 'data'
            out.mkdir()
            data.mkdir()
            model = root / 'model'
            model.write_bytes(b'fixture model')
            manifest = {'target': 'g6lc64_smt2', 'executableSha256': runner.sha(model),
                        'sources': {'core/cva6.sv': 'a' * 64}}
            (data / 'build-manifest.json').write_text(json.dumps(manifest))
            env = {'TH_OUT_DIR': str(out), 'TH_DATA_DIR': str(data), 'SOURCE_REVIEW_MODEL': str(model)}
            with patch.dict(os.environ, env, clear=True), patch.object(runner.shutil, 'which', return_value='tool'), \
                 patch.object(runner, 'execute') as execute:
                self.assertEqual(runner.main(), 2)
            execute.assert_not_called()
            result = json.loads((out / 'results.json').read_text())
            self.assertEqual(result['outcome'], 'refused')
            self.assertFalse(result['simulationStarted'])
            self.assertFalse(result['strictDualPassed'])


class TerminationClassificationTests(unittest.TestCase):
    def test_tracer_terminated_log(self):
        from run_opensbi_source_review import termination_path
        text = ('*** [rvfi_tracer] INFO: Simulation terminated after   12765616 cycles!\n'
                '*** SUCCESS *** (tohost = 0) after 12765628 cycles\n')
        self.assertEqual(termination_path(0, text, 14000000), 'tracer')

    def test_assertion_stop_log(self):
        from run_opensbi_source_review import termination_path
        text = ("[12731487] %Error: pmp_entry.sv:81: Assertion failed in "
                "TOP.ariane_testharness.i_cluster.gen_core[0].i_ariane: 'assert' failed.\n"
                "%Error: /opt/testharness/repo/core/pmp/src/pmp_entry.sv:81: "
                "Verilog $stop\nAborting...\n")
        self.assertEqual(termination_path(255, text, 14000000), 'assertion-$stop')

    def test_cycle_and_wall_budgets_are_classified_separately(self):
        from run_opensbi_source_review import termination_path
        cap_hit = '*** SUCCESS *** (tohost = 0) after 14000000 cycles\n'
        self.assertEqual(termination_path(0, cap_hit, 14000000), 'cycle-budget')
        self.assertEqual(termination_path(124, '', 14000000), 'wall-budget')
        self.assertEqual(termination_path(0, 'no end marker\n', 14000000), 'unknown')


class ProxyNonDestructivePreflightTests(unittest.TestCase):
    def test_preflight_refuses_without_killing(self):
        args = argparse.Namespace(
            command=['sha256sum /tmp/Variane_testharness'],
            timeout=30, no_hang=True, tty=False)
        for name in ('cmd_run', 'cmd_soak', 'cmd_di', 'cmd_shell'):
            with self.subTest(entrypoint=name):
                rem = Mock()
                with patch.object(proxy, '_kill_stranded_harnesses') as killer, \
                     patch.object(proxy, '_no_overlap_guard',
                                  side_effect=SystemExit('busy')):
                    with self.assertRaises(SystemExit):
                        getattr(proxy, name)(rem, args)
                killer.assert_not_called()
                rem.run.assert_not_called()
                rem.start_master.assert_called_once()


class ParallelPythonOutputTests(unittest.TestCase):
    PEER = """\
import json
import os
import sys
import time
from pathlib import Path

name = Path(os.environ['TH_SCRIPT']).stem
out = Path(os.environ['TH_OUT_DIR'])
run = Path(os.environ['TH_RUN_DIR'])
(out / 'results.json').write_text(json.dumps(name))
(run / (name + '.ready')).write_text('1')
peers = {'alpha': 'beta', 'beta': 'alpha'}
peer = run / (peers[name] + '.ready')
deadline = time.time() + 5
while not peer.exists() and time.time() < deadline:
    time.sleep(0.02)
sys.exit(0 if peer.exists() else 3)
"""

    def run_generated(self, tmp, names, threads):
        run_dir = Path(tmp)
        scripts = run_dir / 'scripts'
        scripts.mkdir()
        for name in names:
            (scripts / f'{name}.py').write_text(self.PEER)
        runner = run_dir / '__th_py_runner__.py'
        runner.write_text(proxy._build_py_runner('test'))
        env = dict(os.environ, TH_PROXY_THREADS=str(threads))
        proc = subprocess.run(
            [sys.executable, str(runner)], cwd=run_dir, env=env,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, timeout=60)
        summary = json.loads((run_dir / 'output' / 'summary.json').read_text())
        return proc, summary, run_dir / 'output'

    def test_two_scripts_run_in_parallel_with_separate_outputs(self):
        with tempfile.TemporaryDirectory() as td:
            proc, summary, out = self.run_generated(td, ['alpha', 'beta'], 2)
            self.assertEqual(proc.returncode, 0, proc.stdout)
            self.assertEqual(summary['workers'], 2)
            self.assertEqual([r['rc'] for r in summary['results']], [0, 0])
            self.assertEqual(
                json.loads((out / 'alpha' / 'results.json').read_text()), 'alpha')
            self.assertEqual(
                json.loads((out / 'beta' / 'results.json').read_text()), 'beta')

    def test_single_script_keeps_flat_output_and_one_worker(self):
        with tempfile.TemporaryDirectory() as td:
            proc, summary, out = self.run_generated(td, ['alpha'], 12)
            self.assertEqual(proc.returncode, 3, proc.stdout)
            self.assertEqual(summary['workers'], 1)
            self.assertEqual(
                json.loads((out / 'results.json').read_text()), 'alpha')


if __name__ == '__main__':
    unittest.main()
