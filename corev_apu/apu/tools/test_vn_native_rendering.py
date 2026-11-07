# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Rendering identity/lifetime foundation; draw execution remains refused."""
from dataclasses import replace
import unittest

import test_vn_replay as replay_fixture
from vn_native_execution import StreamFault
from vn_native_rendering import framebuffer_operand


class RenderingTests(unittest.TestCase):
    IMAGE, VIEW, RP, FB, RP2, FB2 = (
        0x700000007000, 0x700020007002, 0x700060007006,
        0x700070007007, 0x700080007008, 0x700090007009)

    def setUp(self):
        self.f = replay_fixture.ReplayTests()
        self.f.native_profile = True
        self.f.setUp()
        self.e, self.w = self.f.engine, self.f.wire
        self.image()
        self.view()
        self.render_pass()
        self.framebuffer()

    def image(self, usage=0x13, *, handle=None, offset=4096):
        handle = handle or self.IMAGE
        self.f.command('vkCreateImage', device=self.w.DEVICE, pImage=handle,
            pCreateInfo=self.w.structure('VkImageCreateInfo', pNext=[], flags=0,
                imageType=1, format=37, extent=self.w.structure(
                    'VkExtent3D', width=8, height=4, depth=1),
                mipLevels=1, arrayLayers=1, samples=1, tiling=0, usage=usage,
                sharingMode=0, queueFamilyIndexCount=0, pQueueFamilyIndices=[], initialLayout=0))
        self.f.command('vkBindImageMemory', device=self.w.DEVICE, image=handle,
                       memory=self.w.MEMORY, memoryOffset=offset)

    def view(self, *, handle=None, image=None):
        self.f.command('vkCreateImageView', device=self.w.DEVICE, pView=handle or self.VIEW,
            pCreateInfo=self.w.structure('VkImageViewCreateInfo', pNext=[], flags=0,
                image=image or self.IMAGE, viewType=1, format=37,
                components=self.w.structure('VkComponentMapping', r=0, g=0, b=0, a=0),
                subresourceRange=self.w.structure('VkImageSubresourceRange', aspectMask=1,
                    baseMipLevel=0, levelCount=1, baseArrayLayer=0, layerCount=1)))

    def render_pass(self, handle=None, *, fmt=37, load=1, store=0, final=1, color_layout=2,
                    samples=1, input_count=0, reference=0, count=1, initial=0):
        self.f.command('vkCreateRenderPass', device=self.w.DEVICE, pRenderPass=handle or self.RP,
            pCreateInfo=self.w.structure('VkRenderPassCreateInfo', pNext=[], flags=0,
                attachmentCount=count, pAttachments=[self.w.structure('VkAttachmentDescription',
                    flags=0, format=fmt, samples=samples, loadOp=load, storeOp=store,
                    stencilLoadOp=2, stencilStoreOp=1, initialLayout=initial, finalLayout=final)
                    for _ in range(count)],
                subpassCount=1, pSubpasses=[self.w.structure('VkSubpassDescription',
                    flags=0, pipelineBindPoint=0, inputAttachmentCount=input_count,
                    pInputAttachments=[self.w.structure('VkAttachmentReference',
                        attachment=0, layout=1)] * input_count,
                    colorAttachmentCount=count, pColorAttachments=[self.w.structure(
                        'VkAttachmentReference', attachment=reference if count == 1 else i,
                        layout=color_layout) for i in range(count)],
                    pResolveAttachments=[], pDepthStencilAttachment=None,
                    preserveAttachmentCount=0, pPreserveAttachments=[])],
                dependencyCount=0, pDependencies=[]))
        return self.f.entry(handle or self.RP)['native_rendering']

    def framebuffer(self, handle=None, *, width=8, height=4, layers=1, render_pass=None, views=None):
        views = views or [self.VIEW]
        self.f.command('vkCreateFramebuffer', device=self.w.DEVICE, pFramebuffer=handle or self.FB,
            pCreateInfo=self.w.structure('VkFramebufferCreateInfo', pNext=[], flags=0,
                renderPass=render_pass or self.RP, attachmentCount=len(views), pAttachments=views,
                width=width, height=height, layers=layers))
        return self.f.entry(handle or self.FB)['native_rendering']

    def operand(self, handle=None):
        return framebuffer_operand(self.e, 1, handle or self.FB)

    def test_color_attachment_resolution_returns_refs_without_leases(self):
        operand = self.operand()
        self.assertEqual((operand.framebuffer.width, operand.framebuffer.height), (8, 4))
        color, = operand.attachments
        self.assertIs(color.owner, self.f.owner)
        self.assertEqual((color.offset, color.size, color.pitch), (4096, 256, 64))
        self.assertEqual(len(operand.references), 5)
        self.assertEqual(self.f.owner.work_refs, 0)
        self.assertFalse(any(entry['pins'] for entry in self.f.front.ent if entry))

    def test_compatibility_ignores_load_store_and_reference_layout(self):
        original = self.f.entry(self.RP)['native_rendering']
        other = self.render_pass(self.RP2, load=0, store=1, final=5, color_layout=1)
        self.assertNotEqual(original, other)
        self.assertTrue(original.compatible(other))
        self.assertFalse(original.compatible(replace(other, context=object())))
        self.assertFalse(original.compatible(replace(other, device=other.device + 1)))

    def test_format_and_unused_reference_are_distinct_compatibility(self):
        original = self.f.entry(self.RP)['native_rendering']
        other = self.render_pass(self.RP2, fmt=44)
        self.assertFalse(original.compatible(other))
        self.assertFalse(original.compatible(replace(other, colors=((0xFFFFFFFF, 0),))))

    def test_framebuffer_keeps_render_pass_value_after_destroy_and_reuse(self):
        original = self.operand().framebuffer.render_pass
        self.f.command('vkDestroyRenderPass', device=self.w.DEVICE, renderPass=self.RP)
        other = self.render_pass(fmt=44)
        self.assertFalse(original.compatible(other))
        self.assertIs(self.operand().framebuffer.render_pass, original)
        with self.assertRaises(StreamFault):
            self.framebuffer(self.FB2)
        self.assertNotIn(self.FB2, self.f.front.idmap)

    def test_view_id_reuse_does_not_redirect_framebuffer(self):
        self.f.command('vkDestroyImageView', device=self.w.DEVICE, imageView=self.VIEW)
        self.view()
        with self.assertRaises(KeyError):
            self.operand()

    def test_image_reuse_beneath_old_view_is_rejected_at_creation(self):
        self.f.command('vkDestroyImage', device=self.w.DEVICE, image=self.IMAGE)
        self.image()
        with self.assertRaises(KeyError):
            self.operand()
        with self.assertRaises(KeyError):
            self.framebuffer(self.FB2)
        self.assertNotIn(self.FB2, self.f.front.idmap)

    def test_memory_rebinding_invalidates_attachment_operand(self):
        self.f.command('vkBindImageMemory', device=self.w.DEVICE, image=self.IMAGE,
                       memory=self.w.MEMORY, memoryOffset=4352)
        with self.assertRaises(KeyError):
            self.operand()

    def test_validator_rechecks_view_after_operand_resolution(self):
        operand = self.operand()
        self.f.entry(self.VIEW)['aux'] ^= 1 << 16
        with self.assertRaises(KeyError):
            operand.validate()
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_smaller_framebuffer_limits_attachment_rows(self):
        self.framebuffer(self.FB2, width=4, height=2)
        operand = self.operand(self.FB2)
        self.assertEqual((operand.framebuffer.width, operand.framebuffer.height), (4, 2))
        self.assertEqual((operand.attachments[0].size, operand.attachments[0].pitch), (128, 64))

    def test_four_distinct_color_attachments_keep_independent_generations(self):
        views = [self.VIEW]
        offsets = [4096, 4352, 4608, 3840]
        for i in range(1, 4):
            image, view = 0x710000001000 + i, 0x720000001000 + i
            self.image(handle=image, offset=offsets[i])
            self.view(handle=view, image=image)
            views.append(view)
        self.render_pass(self.RP2, count=4)
        self.framebuffer(self.FB2, render_pass=self.RP2, views=views)
        operand = self.operand(self.FB2)
        self.assertEqual([color.offset for color in operand.attachments], offsets)
        self.assertEqual(len(operand.references), 14)
        self.assertEqual(len({id(color.owner) for color in operand.attachments}), 1)
        self.f.command('vkDestroyImageView', device=self.w.DEVICE, imageView=views[2])
        with self.assertRaises(KeyError):
            operand.validate()

    def test_framebuffer_id_reuse_rejects_old_canonical_handle(self):
        old = self.operand().references[0][0]
        self.f.command('vkDestroyFramebuffer', device=self.w.DEVICE, framebuffer=self.FB)
        self.framebuffer()
        with self.assertRaises(KeyError):
            self.operand(old)

    def test_unsupported_render_pass_features_fail_before_allocation(self):
        for fields in (dict(samples=2), dict(input_count=1), dict(reference=1), dict(final=0)):
            with self.subTest(fields=fields):
                case = RenderingTests()
                case.setUp()
                with self.assertRaisesRegex(StreamFault, 'profile'):
                    case.render_pass(case.RP2, **fields)
                self.assertNotIn(case.RP2, case.f.front.idmap)

    def test_framebuffer_extent_and_layers_fail_before_allocation(self):
        for fields in (dict(width=9), dict(height=5), dict(layers=2)):
            with self.subTest(fields=fields):
                case = RenderingTests()
                case.setUp()
                with self.assertRaisesRegex(StreamFault, 'profile'):
                    case.framebuffer(case.FB2, **fields)
                self.assertNotIn(case.FB2, case.f.front.idmap)
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_attachment_requires_color_usage(self):
        self.f.command('vkDestroyImageView', device=self.w.DEVICE, imageView=self.VIEW)
        self.f.command('vkDestroyImage', device=self.w.DEVICE, image=self.IMAGE)
        self.image(usage=3)
        self.view()
        with self.assertRaises(StreamFault):
            self.framebuffer(self.FB2)

    def test_begin_render_pass_clear_replays_without_draw(self):
        self.f.begin()
        self.f.command('vkCmdBeginRenderPass', commandBuffer=self.f.CB, contents=0,
            pRenderPassBegin=self.w.structure('VkRenderPassBeginInfo', pNext=[],
                renderPass=self.RP, framebuffer=self.FB, renderArea=self.w.structure(
                    'VkRect2D', offset=self.w.structure('VkOffset2D', x=0, y=0),
                    extent=self.w.structure('VkExtent2D', width=8, height=4)),
                clearValueCount=1, pClearValues=[self.w.structure('VkClearValue',
                    color=self.w.structure('VkClearColorValue', uint32=[0, 0, 0, 0]))]))
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.f.end()
        self.e.replay.enqueue(1, [self.f.CB])
        self.f.drain()
        did = self.e.golden.img_fmt_id(self.e.model, 37)
        texel = self.e.golden.img_clear_texel(self.e.model, did, (0, 0, 0, 0))
        self.assertEqual(self.f.state.aperture.read(self.f.owner.base + 4096, 32),
                         texel * 8)
        self.assertEqual(self.f.owner.work_refs, 0)


if __name__ == '__main__':
    unittest.main()
