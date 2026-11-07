# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Bounded render-pass attachment clears through ordered command replay."""
import struct
import unittest

import test_vn_native_rendering as rendering_fixture
from vn_render_pass_commands import BeginPass, EndPass


def fbits(*values):
    return struct.unpack('<%dI' % len(values), struct.pack('<%df' % len(values), *values))


class ClearPassTests(unittest.TestCase):
    def setUp(self):
        self.r = rendering_fixture.RenderingTests()
        self.r.setUp()
        self.f, self.e, self.w = self.r.f, self.r.e, self.r.w
        self.f.begin()

    def begin(self, *, rp=None, fb=None, contents=0, area=(0, 0, 8, 4), count=1,
              values=None):
        if values is None:
            values = [self.w.structure('VkClearValue', color=self.w.structure(
                'VkClearColorValue', uint32=[0, 0, 0, 0x3F800000]))] * count
        x, y, width, height = area
        self.f.command('vkCmdBeginRenderPass', commandBuffer=self.f.CB, contents=contents,
            pRenderPassBegin=self.w.structure('VkRenderPassBeginInfo', pNext=[],
                renderPass=rp or self.r.RP, framebuffer=fb or self.r.FB,
                renderArea=self.w.structure('VkRect2D',
                    offset=self.w.structure('VkOffset2D', x=x, y=y),
                    extent=self.w.structure('VkExtent2D', width=width, height=height)),
                clearValueCount=count, pClearValues=values))
        return self.last()

    def last(self):
        return self.f.front.cbd[self.f.front.idmap[self.f.CB]]['recs'][-1]['native_render_pass']

    def end(self):
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)

    def texel(self, color=(0, 0, 0, 0x3F800000), fmt=37):
        did = self.e.golden.img_fmt_id(self.e.model, fmt)
        return self.e.golden.img_clear_texel(self.e.model, did, color)

    def read(self, offset, size):
        return self.f.state.aperture.read(self.f.owner.base + offset, size)

    def patterned(self):
        self.f.state.aperture.write(self.f.owner.base + 4096, b'P' * 256)

    def render_pass_loads(self, handle, loads, *, fmt=37):
        count = len(loads)
        self.f.command('vkCreateRenderPass', device=self.w.DEVICE, pRenderPass=handle,
            pCreateInfo=self.w.structure('VkRenderPassCreateInfo', pNext=[], flags=0,
                attachmentCount=count, pAttachments=[self.w.structure(
                    'VkAttachmentDescription', flags=0, format=fmt, samples=1,
                    loadOp=load, storeOp=0, stencilLoadOp=2, stencilStoreOp=1,
                    initialLayout=0, finalLayout=1) for load in loads],
                subpassCount=1, pSubpasses=[self.w.structure('VkSubpassDescription',
                    flags=0, pipelineBindPoint=0, inputAttachmentCount=0,
                    pInputAttachments=[], colorAttachmentCount=count,
                    pColorAttachments=[self.w.structure('VkAttachmentReference',
                        attachment=i, layout=2) for i in range(count)],
                    pResolveAttachments=[], pDepthStencilAttachment=None,
                    preserveAttachmentCount=0, pPreserveAttachments=[])],
                dependencyCount=0, pDependencies=[]))
        return self.f.entry(handle)['native_rendering']

    def clear_rect(self, attachments, rects):
        self.f.command('vkCmdClearAttachments', commandBuffer=self.f.CB,
            attachmentCount=len(attachments),
            pAttachments=[self.w.structure('VkClearAttachment',
                aspectMask=entry[2] if len(entry) > 2 else 1,
                colorAttachment=entry[0], clearValue=self.w.structure('VkClearValue',
                color=self.w.structure('VkClearColorValue', uint32=list(entry[1]))))
                for entry in attachments],
            rectCount=len(rects),
            pRects=[self.w.structure('VkClearRect',
                rect=self.w.structure('VkRect2D',
                    offset=self.w.structure('VkOffset2D', x=x, y=y),
                    extent=self.w.structure('VkExtent2D', width=width, height=height)),
                baseArrayLayer=base, layerCount=layers)
                for x, y, width, height, base, layers in rects])

    def load_pass(self):
        rp2, fb2 = 0x750000003000, 0x760000003001
        self.render_pass_loads(rp2, [0])
        self.r.framebuffer(fb2, render_pass=rp2)
        return rp2, fb2

    def second_attachment(self):
        image, view = 0x730000002000, 0x740000002000
        self.r.image(handle=image, offset=4352)
        self.r.view(handle=view, image=image)
        return image, view

    def test_pass_layout_transitions_publish_across_passes(self):
        self.begin()
        self.end()
        self.f.end()
        self.f.enqueue()
        self.f.drain()
        # UNDEFINED initial -> subpass CATT_OPT(2) -> final GENERAL(1)
        self.assertEqual(self.f.entry(self.r.IMAGE)['layout'], 1)
        # the published layout admits a pass declaring initialLayout=1
        rp2, fb2 = 0x750000003000, 0x760000003001
        self.r.render_pass(rp2, initial=1, final=6, color_layout=1)
        self.r.framebuffer(fb2, render_pass=rp2)
        self.f.begin()
        self.begin(rp=rp2, fb=fb2)
        self.end()
        self.f.end()
        self.f.enqueue()
        self.assertEqual(self.f.entry(self.r.IMAGE)['layout'], 6)

    def test_pass_initial_layout_mismatch_refuses_before_publish(self):
        rp2, fb2 = 0x750000003000, 0x760000003001
        self.r.render_pass(rp2, initial=2)  # image is still UNDEFINED(0)
        self.r.framebuffer(fb2, render_pass=rp2)
        self.begin(rp=rp2, fb=fb2)
        self.end()
        self.f.end()
        with self.assertRaisesRegex(ValueError, 'initialLayout'):
            self.f.enqueue()
        self.assertEqual(self.f.entry(self.r.IMAGE)['layout'], 0)

    def test_subrect_clear_writes_only_render_area_rows(self):
        self.patterned()
        source = self.begin(area=(1, 1, 6, 2))
        self.assertIsInstance(source, BeginPass)
        self.end()
        self.assertIsInstance(self.last(), EndPass)
        self.f.end()
        job = self.f.enqueue()
        self.assertEqual(len(job.operations), 2)
        self.assertTrue(all(op.kind == 'pattern' for op in job.operations))
        self.f.drain()
        texel = self.texel()
        self.assertEqual(self.read(4164, 24), texel * 6)
        self.assertEqual(self.read(4228, 24), texel * 6)
        self.assertEqual(self.read(4160, 4), b'P' * 4)
        self.assertEqual(self.read(4164 + 24, 8), b'P' * 8)
        self.assertEqual(self.read(4096, 64), b'P' * 64)
        self.assertEqual(self.read(4164 - 64, 64), b'P' * 64)
        self.assertEqual(self.f.owner.work_refs, 0)
        self.assertEqual(self.f.entry(self.f.CB)['state'] & 15,
                         self.e.golden.CB_EXEC)

    def test_full_clear_preserves_pitch_padding(self):
        self.patterned()
        self.begin(area=(0, 0, 8, 4))
        self.end()
        self.f.end()
        self.f.enqueue()
        self.f.drain()
        texel = self.texel()
        for row in range(4):
            base = 4096 + row * 64
            self.assertEqual(self.read(base, 32), texel * 8)
            self.assertEqual(self.read(base + 32, 32), b'P' * 32)

    def test_clear_color_uses_pinned_format_conversion(self):
        color = fbits(1, .5, 0, 1)
        values = [self.w.structure('VkClearValue', color=self.w.structure(
            'VkClearColorValue', uint32=list(color)))]
        self.begin(values=values)
        self.end()
        self.f.end()
        self.f.enqueue()
        self.f.drain()
        self.assertEqual(self.read(4096, 32), self.texel(color) * 8)

    def test_sequential_passes_clear_in_record_order(self):
        first = fbits(1, 0, 0, 1)
        second = fbits(0, 1, 0, 1)
        for color, area in ((first, (0, 0, 8, 4)), (second, (2, 1, 4, 2))):
            values = [self.w.structure('VkClearValue', color=self.w.structure(
                'VkClearColorValue', uint32=list(color)))]
            self.begin(area=area, values=values)
            self.end()
        self.f.end()
        self.f.enqueue()
        self.f.drain()
        texel1, texel2 = self.texel(first), self.texel(second)
        self.assertEqual(self.read(4096, 32), texel1 * 8)
        self.assertEqual(self.read(4096 + 3 * 64, 32), texel1 * 8)
        for row in (1, 2):
            base = 4096 + row * 64
            self.assertEqual(self.read(base, 8), texel1 * 2)
            self.assertEqual(self.read(base + 8, 16), texel2 * 4)
            self.assertEqual(self.read(base + 24, 8), texel1 * 2)

    def test_multiple_attachments_clear_independent_regions(self):
        _, view2 = self.second_attachment()
        rp2 = 0x750000003000
        fb2 = 0x760000003001
        self.render_pass_loads(rp2, [1, 1])
        self.r.framebuffer(fb2, render_pass=rp2, views=[self.r.VIEW, view2])
        colors = [fbits(1, 0, 0, 1), fbits(0, 0, 1, 1)]
        values = [self.w.structure('VkClearValue', color=self.w.structure(
            'VkClearColorValue', uint32=list(color))) for color in colors]
        self.begin(rp=rp2, fb=fb2, count=2, values=values)
        self.end()
        self.f.end()
        job = self.f.enqueue()
        self.assertEqual(len(job.operations), 8)
        self.f.drain()
        self.assertEqual(self.read(4096, 32), self.texel(colors[0]) * 8)
        self.assertEqual(self.read(4352, 32), self.texel(colors[1]) * 8)

    def test_load_and_dont_care_attachments_are_not_cleared(self):
        for loads in ((0, 1), (2, 1)):
            with self.subTest(loads=loads):
                case = ClearPassTests()
                case.setUp()
                _, view2 = case.second_attachment()
                rp2, fb2 = 0x750000003000, 0x760000003001
                case.render_pass_loads(rp2, loads)
                case.r.framebuffer(fb2, render_pass=rp2, views=[case.r.VIEW, view2])
                colors = [fbits(0, 0, 0, 0), fbits(0, 1, 0, 1)]
                values = [case.w.structure('VkClearValue', color=case.w.structure(
                    'VkClearColorValue', uint32=list(color))) for color in colors]
                case.begin(rp=rp2, fb=fb2, count=2, values=values)
                case.end()
                case.f.end()
                job = case.f.enqueue()
                self.assertEqual(len(job.operations), 4)
                case.f.drain()
                skipped = case.texel(colors[0])
                cleared = case.texel(colors[1])
                self.assertEqual(case.read(4096, 32), skipped * 8)
                self.assertEqual(case.read(4352, 32), cleared * 8)

    def test_compute_submission_mode_also_replays_clears(self):
        self.begin()
        self.end()
        self.f.end()
        self.e.replay.enqueue(1, [self.f.CB], compute=True)
        self.f.drain()
        self.assertEqual(self.read(4096, 32), self.texel() * 8)

    def test_unsupported_command_inside_pass_refuses_atomically(self):
        self.patterned()
        self.begin()
        self.f.command('vkCmdDispatch', commandBuffer=self.f.CB,
                       groupCountX=1, groupCountY=1, groupCountZ=1)
        self.end()
        self.f.end()
        with self.assertRaisesRegex(ValueError, 'unsupported replay'):
            self.f.enqueue()
        self.assertFalse(self.e.transfers.active)
        self.assertEqual(self.f.owner.work_refs, 0)
        self.assertEqual(self.read(4096, 32), b'P' * 32)

    def test_stale_framebuffer_refuses_without_writes(self):
        self.begin()
        self.end()
        self.f.end()
        self.f.command('vkDestroyFramebuffer', device=self.w.DEVICE, framebuffer=self.r.FB)
        self.r.framebuffer()
        with self.assertRaises(KeyError):
            self.f.enqueue()
        self.assertFalse(self.e.transfers.active)
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_attachment_rebind_fails_late_guard_before_work(self):
        self.begin()
        self.end()
        self.f.end()
        self.f.command('vkBindImageMemory', device=self.w.DEVICE, image=self.r.IMAGE,
                       memory=self.w.MEMORY, memoryOffset=4352)
        with self.assertRaises(KeyError):
            self.f.enqueue()
        self.assertFalse(self.e.transfers.active)
        self.assertEqual(self.read(4096, 32), b'\0' * 32)

    def test_clear_attachments_rect_writes_only_named_region(self):
        rp2, fb2 = self.load_pass()
        self.patterned()
        self.begin(rp=rp2, fb=fb2, count=0, values=[])
        color = fbits(0, 1, 0, 1)
        self.clear_rect([(0, color)], [(1, 1, 4, 2, 0, 1)])
        self.end()
        self.f.end()
        job = self.f.enqueue()
        self.assertEqual(len(job.operations), 2)
        self.f.drain()
        texel = self.texel(color)
        for row in (1, 2):
            base = 4096 + row * 64
            self.assertEqual(self.read(base, 4), b'P' * 4)
            self.assertEqual(self.read(base + 4, 16), texel * 4)
            self.assertEqual(self.read(base + 20, 12), b'P' * 12)
        self.assertEqual(self.read(4096, 64), b'P' * 64)
        self.assertEqual(self.read(4096 + 3 * 64, 64), b'P' * 64)

    def test_clear_attachments_multiple_targets_and_rects(self):
        _, view2 = self.second_attachment()
        rp2, fb2 = 0x750000003000, 0x760000003001
        self.render_pass_loads(rp2, [0, 0])
        self.r.framebuffer(fb2, render_pass=rp2, views=[self.r.VIEW, view2])
        self.f.state.aperture.write(self.f.owner.base + 4096, b'P' * 512)
        self.begin(rp=rp2, fb=fb2, count=0, values=[])
        c1, c2 = fbits(1, 0, 0, 1), fbits(0, 0, 1, 1)
        self.clear_rect([(0, c1), (1, c2)], [(0, 0, 8, 2, 0, 1), (0, 2, 8, 2, 0, 1)])
        self.end()
        self.f.end()
        job = self.f.enqueue()
        self.assertEqual(len(job.operations), 8)
        self.f.drain()
        self.assertEqual(self.read(4096, 32), self.texel(c1) * 8)
        self.assertEqual(self.read(4096 + 128, 32), self.texel(c1) * 8)
        self.assertEqual(self.read(4352, 32), self.texel(c2) * 8)
        self.assertEqual(self.read(4352 + 128, 32), self.texel(c2) * 8)
        self.assertEqual(self.read(4096 + 64, 32), self.texel(c1) * 8)

    def test_clear_attachments_rect_clips_to_render_area(self):
        rp2, fb2 = self.load_pass()
        self.patterned()
        self.begin(rp=rp2, fb=fb2, area=(2, 1, 4, 2), count=0, values=[])
        color = fbits(1, 0, 0, 1)
        self.clear_rect([(0, color)], [(0, 0, 8, 4, 0, 1)])
        self.end()
        self.f.end()
        self.f.enqueue()
        self.f.drain()
        texel = self.texel(color)
        for row in (1, 2):
            base = 4096 + row * 64
            self.assertEqual(self.read(base, 8), b'P' * 8)
            self.assertEqual(self.read(base + 8, 16), texel * 4)
            self.assertEqual(self.read(base + 24, 8), b'P' * 8)
        self.assertEqual(self.read(4096, 64), b'P' * 64)
        self.assertEqual(self.read(4096 + 3 * 64, 64), b'P' * 64)

    def test_clear_attachments_sequential_rects_clear_in_order(self):
        rp2, fb2 = self.load_pass()
        self.patterned()
        self.begin(rp=rp2, fb=fb2, count=0, values=[])
        c1, c2 = fbits(1, 0, 0, 1), fbits(0, 1, 0, 1)
        self.clear_rect([(0, c1)], [(0, 0, 8, 4, 0, 1)])
        self.clear_rect([(0, c2)], [(2, 1, 4, 2, 0, 1)])
        self.end()
        self.f.end()
        self.f.enqueue()
        self.f.drain()
        texel1, texel2 = self.texel(c1), self.texel(c2)
        self.assertEqual(self.read(4096, 32), texel1 * 8)
        self.assertEqual(self.read(4096 + 3 * 64, 32), texel1 * 8)
        for row in (1, 2):
            base = 4096 + row * 64
            self.assertEqual(self.read(base, 8), texel1 * 2)
            self.assertEqual(self.read(base + 8, 16), texel2 * 4)
            self.assertEqual(self.read(base + 24, 8), texel1 * 2)

    def test_clear_attachments_capture_refusals(self):
        for mode in ('aspect', 'target', 'duplicate', 'base_layer', 'layers',
                     'empty_rect', 'no_pass'):
            with self.subTest(mode=mode):
                case = ClearPassTests()
                case.setUp()
                rp2, fb2 = case.load_pass()
                if mode != 'no_pass':
                    case.begin(rp=rp2, fb=fb2, count=0, values=[])
                color = fbits(1, 0, 0, 1)
                atts = [(0, color)]
                rects = [(0, 0, 4, 4, 0, 1)]
                if mode == 'aspect':
                    atts = [(0, color, 2)]
                elif mode == 'target':
                    atts = [(5, color)]
                elif mode == 'duplicate':
                    atts = [(0, color), (0, fbits(0, 1, 0, 1))]
                elif mode == 'base_layer':
                    rects = [(0, 0, 4, 4, 1, 1)]
                elif mode == 'layers':
                    rects = [(0, 0, 4, 4, 0, 2)]
                elif mode == 'empty_rect':
                    rects = [(0, 0, 0, 4, 0, 1)]
                with self.assertRaisesRegex(Exception, 'clear attachments'):
                    case.clear_rect(atts, rects)
                self.assertEqual(case.f.owner.work_refs, 0)

    def test_clear_attachments_stale_framebuffer_refuses(self):
        rp2, fb2 = self.load_pass()
        self.begin(rp=rp2, fb=fb2, count=0, values=[])
        self.clear_rect([(0, fbits(1, 0, 0, 1))], [(0, 0, 4, 4, 0, 1)])
        self.end()
        self.f.end()
        self.f.command('vkDestroyFramebuffer', device=self.w.DEVICE, framebuffer=fb2)
        self.r.framebuffer(fb2, render_pass=rp2)
        with self.assertRaises(KeyError):
            self.f.enqueue()
        self.assertFalse(self.e.transfers.active)
        self.assertEqual(self.f.owner.work_refs, 0)

    COND = 0x7B0000008000

    def cond_buffer(self, predicate, offset=4608):
        self.f.command('vkCreateBuffer', device=self.w.DEVICE,
            pBuffer=self.COND,
            pCreateInfo=self.w.structure('VkBufferCreateInfo', pNext=[],
                flags=0, size=256, usage=0x203, sharingMode=0,
                queueFamilyIndexCount=0, pQueueFamilyIndices=[]))
        self.f.command('vkBindBufferMemory', device=self.w.DEVICE,
            buffer=self.COND, memory=self.w.MEMORY, memoryOffset=offset)
        self.f.state.aperture.write(
            self.f.owner.base + offset, predicate.to_bytes(4, 'little'))

    def gated_clear(self, predicate):
        self.patterned()
        rp2, fb2 = self.load_pass()
        self.cond_buffer(predicate)
        self.f.command('vkCmdBeginConditionalRenderingEXT',
            commandBuffer=self.f.CB,
            pConditionalRenderingBegin=self.w.structure(
                'VkConditionalRenderingBeginInfoEXT', pNext=[],
                buffer=self.COND, offset=0, flags=0))
        self.begin(rp=rp2, fb=fb2, count=0, values=[])
        color = fbits(1, 0, 0, 1)
        self.clear_rect([(0, color)], [(0, 0, 8, 4, 0, 1)])
        self.end()
        self.f.command('vkCmdEndConditionalRenderingEXT',
                       commandBuffer=self.f.CB)
        self.f.end()
        self.f.enqueue()
        self.f.drain()
        return self.read(4096, 32)

    def test_clear_attachments_skipped_when_predicate_zero(self):
        self.assertEqual(self.gated_clear(0), b'P' * 32)

    def test_clear_attachments_runs_when_predicate_nonzero(self):
        color = fbits(1, 0, 0, 1)
        self.assertEqual(self.gated_clear(1), self.texel(color) * 8)


if __name__ == '__main__':
    unittest.main()
