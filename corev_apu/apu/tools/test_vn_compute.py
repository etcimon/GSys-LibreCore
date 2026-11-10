# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Internal cooperative compute with real owned memory, not wire shader admission."""
import struct
import unittest
from unittest.mock import patch

import test_vn_transfers as transfer_fixture
import vn_golden
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

    def test_global_invocation_id_drives_per_lane_store(self):
        # corpus builtin_gid.spv: dst[gl_GlobalInvocationID.x] =
        # gl_GlobalInvocationID.x*3+1.  groups=(4,1,1) x LocalSize 8 ->
        # 32 invocations with GID.x = 0..31; each writes a distinct slot,
        # so a wrong workgroup/lane decomposition cannot reproduce
        # dst[i] = 3i+1.  Exercises ShaderRuntime's per-workgroup wg
        # decomposition and round-robin lane scheduling end-to-end.
        code = tuple(vn_golden.spv_words('builtin_gid'))
        op = Compute(code, (ShaderBinding(self.owner, 0, 128, kind=7),),
                     groups=(4, 1, 1))
        job = self.executor.enqueue(self.context, [op])
        self.drain()
        self.assertEqual(job.state, 'done')
        vals = struct.unpack('<32I',
                             self.state.aperture.read(self.owner.base, 128))
        self.assertEqual(vals, tuple(3 * i + 1 for i in range(32)))

    def test_workgroup_and_local_index_builtins_drive_stores(self):
        # corpus builtin_lindex.spv (LocalSize 4x4): w = WorkGroupId.x +
        # WorkGroupId.y*NumWorkGroups.x; dst[w*16 + LocalInvocationIndex] =
        # LocalInvocationIndex + w.  groups=(2,2,1) -> 4 workgroups x 16
        # lanes: exercises the 2-D workgroup-id decomposition, the
        # NumWorkgroups readback and the per-lane linear index — a wrong
        # wg.x/wg.y/lane ordering cannot reproduce dst[w*16+l] = l+w.
        code = tuple(vn_golden.spv_words('builtin_lindex'))
        op = Compute(code, (ShaderBinding(self.owner, 0, 256, kind=7),),
                     groups=(2, 2, 1))
        job = self.executor.enqueue(self.context, [op])
        self.drain()
        self.assertEqual(job.state, 'done')
        vals = struct.unpack('<64I',
                             self.state.aperture.read(self.owner.base, 256))
        self.assertEqual(vals, tuple(l + w for w in range(4)
                                     for l in range(16)))

    def test_local_invocation_id_xy_and_global_y_drive_stores(self):
        # corpus builtin_lid.spv (LocalSize 8x2): i = GlobalInvocationID.y *
        # NumWorkGroups.x * 8 + GlobalInvocationID.x;
        # dst[i] = WorkGroupId.x*1000 + LocalInvocationId.y*100 +
        # LocalInvocationId.x.  groups=(2,1,1) -> 2 workgroups x 16 lanes:
        # exercises the 2-D local-id decomposition (liy=(inv//lx)%ly), the
        # global-Y fold and the NumWorkgroups readback together.
        code = tuple(vn_golden.spv_words('builtin_lid'))
        op = Compute(code, (ShaderBinding(self.owner, 0, 128, kind=7),),
                     groups=(2, 1, 1))
        job = self.executor.enqueue(self.context, [op])
        self.drain()
        self.assertEqual(job.state, 'done')
        vals = struct.unpack('<32I',
                             self.state.aperture.read(self.owner.base, 128))
        exp = [0] * 32
        for w in range(2):
            for liy in range(2):
                for lix in range(8):
                    exp[liy * 16 + w * 8 + lix] = w * 1000 + liy * 100 + lix
        self.assertEqual(vals, tuple(exp))

    def test_shared_memory_barrier_reduction(self):
        # corpus barrier_reduce.spv (LocalSize 64, one workgroup):
        # sh[i]=src[i]; barrier; tree-reduce sh[i]+=sh[i+s] for s=32..1;
        # dst[0]=sh[0] (total), dst[64+i]=sh[i].  Exercises the Workgroup
        # slab shared across all 64 lanes plus barrier() rendezvous — a
        # per-lane slab or missing barrier yields a wrong partial sum.
        # Two SBUF bindings: src readonly @0 (64 uints), dst @512 (128).
        code = tuple(vn_golden.spv_words('barrier_reduce'))
        src = struct.pack('<64I', *range(64))
        self.state.aperture.write(self.owner.base, src)
        self.state.aperture.write(self.owner.base + 512, bytes(512))
        op = Compute(code, (ShaderBinding(self.owner, 0, 256, binding=0,
                                           kind=7),
                             ShaderBinding(self.owner, 512, 512, binding=1,
                                           kind=7)),
                     groups=(1, 1, 1))
        job = self.executor.enqueue(self.context, [op])
        # 64 lanes x a multi-round barrier tree reduction needs more poll
        # quanta than the shared drain()'s 256.
        for _ in range(4096):
            if not self.executor.active:
                break
            self.executor.poll()
        self.assertFalse(self.executor.active)
        self.assertEqual(job.state, 'done')
        # oracle: replay the same tree reduction over src[i]=i
        sh = list(range(64))
        for s in (32, 16, 8, 4, 2, 1):
            for i in range(s):
                sh[i] += sh[i + s]
        out = struct.unpack('<128I',
                            self.state.aperture.read(self.owner.base + 512,
                                                     512))
        self.assertEqual(out[0], sh[0])
        self.assertEqual(out[64:128], tuple(sh))

    def test_atomic_histogram_shared_counter_and_barriers(self):
        # corpus atomic_hist.spv (LocalSize 32, one workgroup):
        #   dst[v&3]      += 1            (atomicAdd, data-dependent index)
        #   dst[4+(v&3)]   = max(..., v)  (atomicMax)
        #   shared wgcount += v&7         (Workgroup atomic + barrier)
        #   lane1: dst[8] += wgcount
        #   dst[16+i]     = atomicOr(...)  (returns OLD value -> stores 0)
        # src[i]=i over 32 lanes.  A per-lane slab, a missing barrier, or
        # an atomic that drops its RMW write all corrupt the histogram /
        # max / counter cells independently.
        code = tuple(vn_golden.spv_words('atomic_hist'))
        src = struct.pack('<64I', *range(64))
        self.state.aperture.write(self.owner.base, src)
        self.state.aperture.write(self.owner.base + 512, bytes(512))
        op = Compute(code, (ShaderBinding(self.owner, 0, 256, binding=0,
                                           kind=7),
                             ShaderBinding(self.owner, 512, 256, binding=1,
                                           kind=7)),
                     groups=(1, 1, 1))
        job = self.executor.enqueue(self.context, [op])
        for _ in range(4096):
            if not self.executor.active:
                break
            self.executor.poll()
        self.assertFalse(self.executor.active)
        self.assertEqual(job.state, 'done')
        out = struct.unpack('<64I',
                            self.state.aperture.read(self.owner.base + 512,
                                                     256))
        # histogram: i&3 hits each bucket 8 times
        self.assertEqual(out[0:4], (8, 8, 8, 8))
        # per-bucket max of v=i: bucket b tops out at 28+b
        self.assertEqual(out[4:8], (28, 29, 30, 31))
        # shared counter = sum_{i=0..31}(i&7) = 4*(0+..+7) = 112
        self.assertEqual(out[8], 112)
        # atomicOr returns the pre-op cell (0); the plain store keeps 0
        self.assertEqual(out[16:48], (0,) * 32)

    def test_atomic_compare_exchange_retry_loop_counts_lanes(self):
        # corpus atomic_cas.spv (LocalSize 8, one workgroup): a
        # do { cur = dst[0] } while (atomicCompSwap(dst[0], cur,
        # cur+1) != cur) retry loop plus per-lane Exchange/Min/And/Xor
        # self-assignments (which store the atomic's OLD-value return
        # back, netting 0).  The only observable is dst[0]: every lane
        # must land exactly one successful CAS bump, so dst[0] == 8.
        # A wrong OpAtomicCompareExchange operand decode (Value and
        # Comparator trail the Equal/Unequal semantics pair) makes every
        # CAS compare fail and leaves dst[0] at its preload image.
        code = tuple(vn_golden.spv_words('atomic_cas'))
        self.state.aperture.write(self.owner.base, struct.pack(
            '<64I', *range(64)))
        self.state.aperture.write(self.owner.base + 512, bytes(512))
        op = Compute(code, (ShaderBinding(self.owner, 0, 256, binding=0,
                                           kind=7),
                             ShaderBinding(self.owner, 512, 256, binding=1,
                                           kind=7)),
                     groups=(1, 1, 1))
        job = self.executor.enqueue(self.context, [op])
        for _ in range(4096):
            if not self.executor.active:
                break
            self.executor.poll()
        self.assertFalse(self.executor.active)
        self.assertEqual(job.state, 'done')
        out = struct.unpack('<64I',
                            self.state.aperture.read(self.owner.base + 512,
                                                     256))
        # dst[0] started 0; 8 lanes each CAS-bump it once -> 8.
        self.assertEqual(out[0], 8)

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
