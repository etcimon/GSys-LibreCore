# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Dynamic values remain immutable and bound to their command recording."""
import struct
import unittest

import test_vn_replay as replay_fixture
from vn_graphics_dynamic import validate
from vn_native_execution import StreamFault


def bits(value):
    return struct.unpack('<I', struct.pack('<f', value))[0]


class DynamicTests(unittest.TestCase):
    def setUp(self):
        self.f = replay_fixture.ReplayTests()
        self.f.native_profile = True
        self.f.setUp()
        self.e, self.w = self.f.engine, self.f.wire
        self.f.begin()

    def snapshot(self):
        return self.f.front.cbd[self.f.front.idmap[self.f.CB]]['recs'][-1]['native_graphics_dynamic']

    def viewport(self, values=(0, 0, 8, 4, 0, 1), *, first=0, count=1, raw=None):
        words = tuple(map(bits, values)) if raw is None else raw
        self.f.command('vkCmdSetViewport', commandBuffer=self.f.CB, firstViewport=first,
            viewportCount=count, pViewports=[self.w.structure('VkViewport',
                **dict(zip(('x', 'y', 'width', 'height', 'minDepth', 'maxDepth'), words)))])
        return self.snapshot()

    def scissor(self, values=(0, 0, 8, 4), *, first=0, count=1):
        x, y, width, height = values
        self.f.command('vkCmdSetScissor', commandBuffer=self.f.CB, firstScissor=first,
            scissorCount=count, pScissors=[self.w.structure('VkRect2D',
                offset=self.w.structure('VkOffset2D', x=x, y=y),
                extent=self.w.structure('VkExtent2D', width=width, height=height))])
        return self.snapshot()

    def viewport_wc(self, values=(0, 0, 8, 4, 0, 1), *, count=1):
        words = tuple(map(bits, values))
        self.f.command('vkCmdSetViewportWithCount', commandBuffer=self.f.CB,
            viewportCount=count, pViewports=[self.w.structure('VkViewport',
                **dict(zip(('x', 'y', 'width', 'height', 'minDepth', 'maxDepth'), words)))])
        return self.snapshot()

    def scissor_wc(self, values=(0, 0, 8, 4), *, count=1):
        x, y, width, height = values
        self.f.command('vkCmdSetScissorWithCount', commandBuffer=self.f.CB,
            scissorCount=count, pScissors=[self.w.structure('VkRect2D',
                offset=self.w.structure('VkOffset2D', x=x, y=y),
                extent=self.w.structure('VkExtent2D', width=width, height=height))])
        return self.snapshot()

    def line_width(self, value=1.0):
        self.f.command('vkCmdSetLineWidth', commandBuffer=self.f.CB,
                       lineWidth=bits(value))
        return self.snapshot()

    def refuses(self, method, *args, **kwargs):
        case = DynamicTests()
        case.setUp()
        with self.assertRaisesRegex(StreamFault, 'graphics dynamic'):
            getattr(case, method)(*args, **kwargs)
        self.assertEqual(case.f.owner.work_refs, 0)
        self.assertFalse(case.e.transfers.active)

    def test_viewport_keeps_exact_float_words_without_work(self):
        source = self.viewport()
        expected = tuple(map(bits, (0, 0, 8, 4, 0, 1)))
        self.assertEqual((source.kind, source.values), ('viewport', expected))
        self.assertEqual(validate(self.e, 1, source), expected)
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_later_set_does_not_mutate_prior_snapshot(self):
        source = self.viewport()
        later = self.viewport((1, 2, 4, 2, 0, 1))
        self.assertNotEqual(source.values, later.values)
        self.assertEqual(validate(self.e, 1, source), tuple(map(bits, (0, 0, 8, 4, 0, 1))))

    def test_zero_extent_scissor_is_preserved(self):
        source = self.scissor((0, 0, 0, 4))
        self.assertEqual(validate(self.e, 1, source), (0, 0, 0, 4))

    def test_negative_origin_and_reverse_depth_are_preserved(self):
        source = self.viewport((-4, -2, 8, 4, 1, 0))
        self.assertEqual(validate(self.e, 1, source), tuple(map(bits, (-4, -2, 8, 4, 1, 0))))

    def test_nonfinite_dimensions_depth_and_bounds_fail(self):
        for values in ((float('nan'), 0, 8, 4, 0, 1),
                       (0, 0, float('inf'), 4, 0, 1), (0, 0, 0, 4, 0, 1),
                       (0, 0, 8, -4, 0, 1), (0, 0, 8193, 4, 0, 1),
                       (16382, 0, 8, 4, 0, 1), (0, 0, 8, 4, -1, 1),
                       (0, 0, 8, 4, 0, 2)):
            with self.subTest(values=values):
                self.refuses('viewport', values)

    def test_scissor_negative_and_overflowing_ranges_fail(self):
        for values in ((-1, 0, 8, 4), (0, -1, 8, 4), (0, 0, 8193, 4),
                       (8190, 0, 8, 4), (0, 8190, 8, 8)):
            with self.subTest(values=values):
                self.refuses('scissor', values)

    def test_first_and_count_are_checked_before_truncation(self):
        for method in ('viewport', 'scissor'):
            for kwargs in (dict(first=1), dict(first=65536), dict(count=0), dict(count=2)):
                with self.subTest(method=method, kwargs=kwargs):
                    self.refuses(method, **kwargs)

    def test_withcount_count1_matches_base_dynamic_state(self):
        for wc, base in ((self.viewport_wc, self.viewport),
                         (self.scissor_wc, self.scissor)):
            with self.subTest(wc=wc.__name__):
                snap = wc()
                self.assertEqual(snap.kind, base().kind)
                self.assertEqual(snap.values, base().values)

    def test_withcount_count_above_single_slot_is_refused(self):
        for method in ('viewport_wc', 'scissor_wc'):
            for kwargs in (dict(count=0), dict(count=2)):
                with self.subTest(method=method, kwargs=kwargs):
                    self.refuses(method, **kwargs)

    def test_reset_invalidates_old_recording_even_when_cb_handle_survives(self):
        source = self.viewport()
        self.f.end()
        self.f.command('vkResetCommandBuffer', commandBuffer=self.f.CB, flags=0)
        with self.assertRaisesRegex(KeyError, 'recording epoch'):
            validate(self.e, 1, source)
        self.assertEqual(source.values, tuple(map(bits, (0, 0, 8, 4, 0, 1))))

    def test_recording_dynamic_state_replays_without_work(self):
        self.viewport()
        self.scissor()
        self.f.end()
        job = self.e.replay.enqueue(1, [self.f.CB], compute=True)
        self.assertEqual(job.operations, ())
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_line_width_single_slot_value_is_preserved(self):
        # vkCmdSetLineWidth carries one fp32 in imm[0]; the bounded profile
        # admits only the fixed 1.0 width (lineWidthRange=[1,1]).
        source = self.line_width()
        self.assertEqual((source.kind, source.values),
                         ('line_width', (bits(1.0),)))
        self.assertEqual(validate(self.e, 1, source), (bits(1.0),))
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_line_width_outside_bounded_range_or_nonfinite_fails(self):
        for value in (0.5, 2.0, float('nan'), float('inf'), -1.0):
            with self.subTest(value=value):
                self.refuses('line_width', value)


if __name__ == '__main__':
    unittest.main()
