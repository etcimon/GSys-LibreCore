# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Internal cooperative compute with real owned memory, not wire shader admission."""
import unittest
from unittest.mock import patch

import test_vn_transfers as transfer_fixture
from vn_compute import Compute, ShaderBinding
from vn_transfer_executor import Transfer


def program(*, add=False, padding=0, barrier=False, index=0, local=1):
    words = [0x07230203, 0x00010300, 0, 32, 0]

    def op(code, *args):
        words.extend(((len(args) + 1) << 16 | code, *args))

    op(17, 1)                                      # Shader capability.
    op(14, 0, 1)                                   # Logical/GLSL450.
    op(15, 5, 10, 0x6E69616D, 0)                   # GLCompute main.
    op(16, 10, 17, local, 1, 1)
    op(71, 6, 34, 0)
    op(71, 6, 33, 0)
    op(71, 7, 6, 4)                                # ArrayStride.
    op(71, 17, 2)                                  # Block.
    op(72, 17, 0, 35, 0)                           # Member Offset.
    op(19, 1)
    op(33, 2, 1)
    op(21, 3, 32, 0)
    op(29, 7, 3)
    op(30, 17, 7)
    op(32, 4, 12, 17)
    op(32, 8, 12, 3)
    for identifier, value in ((5, 5), (9, 0), (18, index), (19, 2), (20, 0x108)):
        op(43, 3, identifier, value)
    op(59, 4, 6, 12)
    op(54, 1, 10, 0, 2)
    op(248, 11)
    for _ in range(padding):
        op(0)
    op(65, 8, 12, 6, 9, 18)
    if add:
        op(61, 3, 13, 12)
        op(128, 3, 14, 13, 5)
    if barrier:
        op(224, 19, 19, 20)
    op(62, 12, 14 if add else 5)
    op(253)
    op(56)
    return tuple(words)


class ComputeTests(unittest.TestCase):
    def setUp(self):
        self.f = transfer_fixture.TransferTests()
        self.f.setUp()
        self.e, self.executor, self.context = self.f.engine, self.f.executor, self.f.context
        self.owner, self.state = self.f.owner, self.f.state

    def operation(self, code=None, **kwargs):
        return Compute(code or program(), (ShaderBinding(self.owner, 0, 4),), **kwargs)

    def drain(self):
        for _ in range(256):
            if not self.executor.active:
                return
            self.executor.poll()
        self.fail('bounded compute cohort did not drain')

    def test_real_ssbo_store_and_lease_retirement(self):
        job = self.executor.enqueue(self.context, [self.operation()])
        self.assertEqual(self.owner.work_refs, 1)
        self.assertEqual(self.state.aperture.read(self.owner.base, 4), b'\0' * 4)
        self.drain()
        self.assertEqual(job.state, 'done')
        self.assertEqual(self.state.aperture.read(self.owner.base, 4), (5).to_bytes(4, 'little'))
        self.assertEqual(self.owner.work_refs, 0)
        self.assertGreater(job.compute_stats[0]['steps'], 0)

    def test_compute_reads_prior_transfer_and_later_copy_reads_shader_store(self):
        first = Transfer('update', self.owner, 0, 4, data=(7).to_bytes(4, 'little'))
        last = Transfer('copy', self.owner, 16, 4, self.owner, 0)
        job = self.executor.enqueue(self.context, [first, self.operation(program(add=True)), last])
        self.drain()
        self.assertEqual(job.state, 'done')
        self.assertEqual(self.state.aperture.read(self.owner.base + 16, 4),
                         (12).to_bytes(4, 'little'))

    def test_instruction_quantum_defers_store_and_context_reset_cancels(self):
        job = self.executor.enqueue(self.context, [self.operation(program(padding=100))])
        self.executor.poll()
        self.assertEqual(job.state, 'running')
        self.assertEqual(job.runtimes[0].steps, 32)
        self.f.service.reset()
        self.assertEqual((job.state, self.owner.work_refs), ('cancelled', 0))
        self.assertFalse(job.runtimes)

    def test_instruction_watchdog_faults_instead_of_silent_completion(self):
        job = self.executor.enqueue(self.context, [self.operation(max_steps=1)])
        self.drain()
        self.assertEqual(job.state, 'faulted')
        self.assertIn('instruction budget', job.error)
        self.assertEqual(self.state.aperture.read(self.owner.base, 4), b'\0' * 4)

    def test_workgroup_barrier_resumes_and_zero_group_is_empty(self):
        job = self.executor.enqueue(self.context, [self.operation(program(barrier=True))])
        self.drain()
        self.assertEqual(job.state, 'done')
        zero = self.executor.enqueue(self.context, [self.operation(groups=(0, 1, 1))])
        self.drain()
        self.assertEqual(zero.state, 'done')
        self.assertEqual(zero.compute_stats[0]['steps'], 0)

    def test_robust_oob_store_does_not_escape_binding(self):
        job = self.executor.enqueue(self.context, [self.operation(program(index=8))])
        self.drain()
        self.assertEqual(job.state, 'done')
        self.assertEqual(job.compute_stats[0]['robust'], 1)
        self.assertEqual(self.state.aperture.read(self.owner.base, 36), b'\0' * 36)

    def test_uniform_binding_is_not_a_write_capability(self):
        op = Compute(program(), (ShaderBinding(self.owner, 0, 4, kind=6),))
        job = self.executor.enqueue(self.context, [op])
        self.drain()
        self.assertEqual(job.state, 'faulted')
        self.assertEqual(self.owner.work_refs, 0)

    def test_io_failure_is_terminal_and_not_replayed(self):
        job = self.executor.enqueue(self.context, [self.operation()])
        with patch.object(self.state.aperture, 'write', side_effect=OSError('shader DMA fault')):
            self.executor.poll()
        self.assertEqual(job.state, 'faulted')
        self.executor.poll()
        self.assertEqual(self.state.aperture.read(self.owner.base, 4), b'\0' * 4)

    def test_shader_pins_block_relocation_and_failed_admission_rolls_back(self):
        job = self.executor.enqueue(self.context, [self.operation(program(padding=100))])
        with self.assertRaises(BlockingIOError):
            self.owner.relocate(49152)
        self.executor.cancel_context(self.context)
        self.assertEqual((job.state, self.owner.work_refs), ('cancelled', 0))
        invalid = Compute(program(), (ShaderBinding(self.owner, 5000, 4),))
        with self.assertRaises(ValueError):
            self.executor.enqueue(self.context, [invalid])
        self.assertEqual(self.owner.work_refs, 0)

    def test_bad_module_duplicate_bindings_and_large_geometry_reject_before_pins(self):
        for op in (
                self.operation(code=(0, 0, 0, 0, 0)),
                self.operation(code=program()[:5] + (0,)),
                self.operation(groups=(64, 64, 64)),
                Compute(program(), (ShaderBinding(self.owner, 0, 4),) * 2)):
            with self.assertRaises(ValueError):
                self.executor.enqueue(self.context, [op])
        self.assertFalse(self.executor.active)
        self.assertEqual(self.owner.work_refs, 0)

    def test_read_callback_reset_cannot_write_into_retired_context(self):
        base = self.owner.base
        self.state.aperture.write(base, (7).to_bytes(4, 'little'))
        original = self.state.aperture.read

        def retiring_read(address, size):
            data = original(address, size)
            self.f.service.reset()
            return data

        job = self.executor.enqueue(self.context, [self.operation(program(add=True))])
        with patch.object(self.state.aperture, 'read', side_effect=retiring_read):
            self.executor.poll()
        self.assertEqual((job.state, self.owner.work_refs), ('cancelled', 0))
        self.assertFalse(self.executor.active)


if __name__ == '__main__':
    unittest.main()
