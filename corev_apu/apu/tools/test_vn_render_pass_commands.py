# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Render-pass metadata and scope guards; clears replay, drawing stays refused."""
import struct
import unittest

import test_vn_native_rendering as rendering_fixture
from vn_native_execution import StreamFault
from vn_render_pass_commands import BeginPass, EndPass, operand


class PassTests(unittest.TestCase):
    def setUp(self):
        self.r = rendering_fixture.RenderingTests()
        self.r.setUp()
        self.f, self.e, self.w = self.r.f, self.r.e, self.r.w
        self.f.begin()

    def begin(self, *, rp=None, contents=0, area=(0, 0, 8, 4), count=1, values=None,
              wire_only=False):
        if values is None:
            values = [self.w.structure('VkClearValue', color=self.w.structure(
                'VkClearColorValue', uint32=[0, 0, 0, 0x3F800000]))] * count
        x, y, width, height = area
        data = self.w.command('vkCmdBeginRenderPass', commandBuffer=self.f.CB, contents=contents,
            pRenderPassBegin=self.w.structure('VkRenderPassBeginInfo', pNext=[],
                renderPass=rp or self.r.RP, framebuffer=self.r.FB,
                renderArea=self.w.structure('VkRect2D',
                    offset=self.w.structure('VkOffset2D', x=x, y=y),
                    extent=self.w.structure('VkExtent2D', width=width, height=height)),
                clearValueCount=count, pClearValues=values))
        if wire_only:
            return data
        self.f.service.execute(1, data)
        return self.last()

    def last(self):
        return self.f.front.cbd[self.f.front.idmap[self.f.CB]]['recs'][-1]['native_render_pass']

    def end(self):
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        return self.last()

    def test_begin_end_values_and_references_without_work(self):
        source = self.begin(area=(1, 1, 6, 2))
        self.assertIsInstance(source, BeginPass)
        self.assertEqual(source.area, (1, 1, 6, 2))
        self.assertEqual(source.clears, ((0, 0, 0, 0x3F800000),))
        resolved = operand(self.e, 1, source)
        self.assertEqual(len(resolved.references), 8)
        self.assertIs(resolved.attachments[0].owner, self.f.owner)
        end = self.end()
        self.assertIsInstance(end, EndPass)
        self.assertIs(end.begin, source)
        self.f.end()
        resolved.validate()
        self.assertEqual(self.f.owner.work_refs, 0)
        self.assertFalse(any(entry['pins'] for entry in self.f.front.ent if entry))

    def test_compatible_pass_identity_is_by_value_not_handle(self):
        self.r.render_pass(self.r.RP2, load=2)
        source = self.begin(rp=self.r.RP2, count=0)
        self.assertEqual(source.clears, ())
        operand(self.e, 1, source).validate()

    def test_incompatible_format_is_refused(self):
        self.r.render_pass(self.r.RP2, fmt=44)
        with self.assertRaisesRegex(StreamFault, 'compatibility'):
            self.begin(rp=self.r.RP2)

    def test_render_pass_reuse_is_refused_by_late_guard(self):
        source = self.begin()
        resolved = operand(self.e, 1, source)
        self.f.command('vkDestroyRenderPass', device=self.w.DEVICE, renderPass=self.r.RP)
        self.r.render_pass()
        with self.assertRaises(KeyError):
            resolved.validate()
        with self.assertRaises(KeyError):
            operand(self.e, 1, source)

    def test_framebuffer_reuse_is_refused(self):
        source = self.begin()
        self.f.command('vkDestroyFramebuffer', device=self.w.DEVICE, framebuffer=self.r.FB)
        self.r.framebuffer()
        with self.assertRaises(KeyError):
            operand(self.e, 1, source)

    def test_attachment_rebinding_is_refused_by_late_guard(self):
        source = self.begin()
        resolved = operand(self.e, 1, source)
        self.f.command('vkBindImageMemory', device=self.w.DEVICE, image=self.r.IMAGE,
                       memory=self.w.MEMORY, memoryOffset=4000)
        with self.assertRaisesRegex(KeyError, 'provenance'):
            resolved.validate()

    def test_reset_invalidates_pass_recording(self):
        source = self.begin()
        resolved = operand(self.e, 1, source)
        self.end()
        self.f.end()
        self.f.command('vkResetCommandBuffer', commandBuffer=self.f.CB, flags=0)
        with self.assertRaisesRegex(KeyError, 'recording epoch'):
            resolved.validate()

    def test_bad_area_and_secondary_contents_are_refused(self):
        for kwargs in (dict(area=(-1, 0, 8, 4)), dict(area=(0, 0, 0, 4)),
                       dict(area=(1, 0, 8, 4)), dict(area=(0, 0, 8, 5)), dict(contents=1)):
            with self.subTest(kwargs=kwargs):
                case = PassTests()
                case.setUp()
                with self.assertRaisesRegex(StreamFault, 'render pass command'):
                    case.begin(**kwargs)
                self.assertEqual(case.f.owner.work_refs, 0)

    def test_missing_and_mismatched_clear_counts_are_refused(self):
        for kwargs in (dict(count=0), dict(count=1, values=[]), dict(count=2)):
            with self.subTest(kwargs=kwargs):
                case = PassTests()
                case.setUp()
                with self.assertRaisesRegex(StreamFault, 'render pass command'):
                    case.begin(**kwargs)

    def test_nested_or_unbalanced_scope_is_refused(self):
        for mode in ('nested', 'end_without_begin', 'open_at_end'):
            with self.subTest(mode=mode):
                case = PassTests()
                case.setUp()
                if mode != 'end_without_begin':
                    case.begin()
                with self.assertRaisesRegex(StreamFault, 'render pass command'):
                    if mode == 'nested':
                        case.begin()
                    elif mode == 'end_without_begin':
                        case.end()
                    else:
                        case.f.end()

    def test_sequential_scopes_keep_independent_begin_tokens(self):
        first = self.begin()
        self.end()
        second = self.begin(area=(0, 0, 4, 2))
        self.assertIs(self.end().begin, second)
        self.assertNotEqual(first.area, second.area)
        operand(self.e, 1, first).validate()

    def test_render_pass_clear_replays_through_bounded_executor(self):
        self.begin()
        self.end()
        self.f.end()
        self.e.replay.enqueue(1, [self.f.CB], compute=True)
        self.f.drain()
        did = self.e.golden.img_fmt_id(self.e.model, 37)
        texel = self.e.golden.img_clear_texel(self.e.model, did, (0, 0, 0, 0x3F800000))
        self.assertEqual(self.f.state.aperture.read(self.f.owner.base + 4096, 32),
                         texel * 8)
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_depth_stencil_clear_variant_is_refused(self):
        data = bytearray(self.begin(wire_only=True))
        words = struct.unpack('<%dI' % (len(data) // 4), data)
        decoder = self.e.golden.Sim(self.e.model, self.e.assembly)
        decoded = decoder.run(words, want_trace=True)
        self.assertFalse(decoded['fault'])
        positions = [position for pc, op, position in decoder.trace
                     if op == 'CHECK' and self.e.assembly['dec_ops'][pc][3].startswith(
                         'VkClearValue tag ')]
        self.assertEqual(len(positions), 1)
        struct.pack_into('<I', data, positions[0] * 4, 1)
        with self.assertRaises(StreamFault):
            self.f.service.execute(1, data)

    def test_reset_discards_an_open_scope_before_rerecording(self):
        source = self.begin()
        self.f.command('vkResetCommandBuffer', commandBuffer=self.f.CB, flags=0)
        self.f.begin()
        self.begin()
        self.end()
        with self.assertRaisesRegex(KeyError, 'recording epoch'):
            operand(self.e, 1, source)

    def test_next_subpass_is_outside_single_subpass_profile(self):
        self.begin()
        with self.assertRaisesRegex(StreamFault, 'render pass command next subpass'):
            self.f.command('vkCmdNextSubpass', commandBuffer=self.f.CB, contents=0)

    def test_context_retirement_invalidates_late_guard(self):
        resolved = operand(self.e, 1, self.begin())
        self.e.contexts[1].retired = True
        with self.assertRaises(KeyError):
            resolved.validate()


if __name__ == '__main__':
    unittest.main()
