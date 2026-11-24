# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Dynamic rendering (vkCmdBeginRendering): command-side RenderPass/Framebuffer
synthesis, attachment clears and graphics-draw routing."""
import struct
import unittest

import test_vn_replay as replay_fixture
import test_vn_graphics_draw_replay as draw_fixture
from vn_dynamic_rendering import BeginRendering, EndRendering
from vn_native_execution import StreamFault


class DynamicRenderingTests(unittest.TestCase):
    IMAGE, VIEW = 0x700000007000, 0x700020007002

    def setUp(self):
        self.f = replay_fixture.ReplayTests()
        self.f.native_profile = True
        self.f.setUp()
        self.e, self.w = self.f.engine, self.f.wire
        self.image()
        self.view()

    def image(self, fmt=37, w=8, h=4, usage=0x13, offset=4096):
        self.f.command('vkCreateImage', device=self.w.DEVICE, pImage=self.IMAGE,
            pCreateInfo=self.w.structure('VkImageCreateInfo', pNext=[], flags=0,
                imageType=1, format=fmt,
                extent=self.w.structure('VkExtent3D', width=w, height=h, depth=1),
                mipLevels=1, arrayLayers=1, samples=1, tiling=0, usage=usage,
                sharingMode=0, queueFamilyIndexCount=0, pQueueFamilyIndices=[],
                initialLayout=0))
        self.f.command('vkBindImageMemory', device=self.w.DEVICE, image=self.IMAGE,
                       memory=self.w.MEMORY, memoryOffset=offset)

    def view(self, fmt=37, handle=None, image=None):
        self.f.command('vkCreateImageView', device=self.w.DEVICE,
            pView=handle or self.VIEW,
            pCreateInfo=self.w.structure('VkImageViewCreateInfo', pNext=[], flags=0,
                image=image or self.IMAGE, viewType=1, format=fmt,
                components=self.w.structure('VkComponentMapping',
                                            r=0, g=0, b=0, a=0),
                subresourceRange=self.w.structure('VkImageSubresourceRange',
                    aspectMask=1, baseMipLevel=0, levelCount=1,
                    baseArrayLayer=0, layerCount=1)))

    def attachment(self, view=None, load=1, store=0, clear=(9, 9, 9, 9), layout=2):
        return self.w.structure('VkRenderingAttachmentInfo',
            imageView=view or self.VIEW, imageLayout=layout,
            resolveMode=0, resolveImageView=0, resolveImageLayout=0,
            loadOp=load, storeOp=store,
            clearValue=self.w.structure('VkClearValue', color=self.w.structure(
                'VkClearColorValue', uint32=list(clear))))

    def begin(self, colors=None, depth=None, stencil=None, w=8, h=4,
              layer=1, view_mask=0, x=0, y=0):
        colors = colors if colors is not None else [self.attachment()]
        self.f.command('vkCmdBeginRendering', commandBuffer=self.f.CB,
            pRenderingInfo=self.w.structure('VkRenderingInfo', pNext=[], flags=0,
                renderArea=self.w.structure('VkRect2D',
                    offset=self.w.structure('VkOffset2D', x=x, y=y),
                    extent=self.w.structure('VkExtent2D', width=w, height=h)),
                layerCount=layer, viewMask=view_mask,
                colorAttachmentCount=len(colors), pColorAttachments=colors,
                pDepthAttachment=depth, pStencilAttachment=stencil))

    def recs(self):
        front = self.f.front
        return front.cbd[front.idmap[self.f.CB]]['recs']

    def dynamic(self, index=-1):
        return self.recs()[index].get('native_dynamic_render')

    def test_begin_synthesizes_render_pass_framebuffer_operand(self):
        self.f.begin()
        self.begin()
        state = self.dynamic()
        self.assertIsInstance(state, BeginRendering)
        rp = state.render_pass_state
        # recovered VkFormat 37 (R8G8B8A8_UNORM) matches the image view format
        self.assertEqual(rp.attachments, ((37, 1, 0, 0, 0, 0, 0, 0),))
        self.assertEqual(rp.colors, ((0, 2),))
        self.assertEqual(rp.depths, (None,))
        fb = state.framebuffer_state
        self.assertEqual((fb.width, fb.height), (8, 4))
        self.assertEqual(len(fb.attachments), 1)
        self.assertEqual(len(state.operand.attachments), 1)
        self.assertEqual(state.area, (0, 0, 8, 4))
        self.assertEqual(state.attachment_ops,
                         ((1, 0, (9, 9, 9, 9)),))

    def test_end_rendering_pairs_with_begin(self):
        self.f.begin()
        self.begin()
        self.f.command('vkCmdEndRendering', commandBuffer=self.f.CB)
        self.assertIsInstance(self.dynamic(-1), EndRendering)
        self.assertIs(self.dynamic(-1).begin, self.dynamic(-2))

    def test_end_without_begin_refuses(self):
        self.f.begin()
        with self.assertRaises(StreamFault):
            self.f.command('vkCmdEndRendering', commandBuffer=self.f.CB)

    def test_nested_begin_refuses(self):
        self.f.begin()
        self.begin()
        with self.assertRaises(StreamFault):
            self.begin()

    def test_depth_attachment_synthesizes_depth_slot(self):
        depth_img = 0x700000009000
        self.f.command('vkCreateImage', device=self.w.DEVICE, pImage=depth_img,
            pCreateInfo=self.w.structure('VkImageCreateInfo', pNext=[], flags=0,
                imageType=1, format=126,
                extent=self.w.structure('VkExtent3D', width=8, height=4, depth=1),
                mipLevels=1, arrayLayers=1, samples=1, tiling=0, usage=0x23,
                sharingMode=0, queueFamilyIndexCount=0, pQueueFamilyIndices=[],
                initialLayout=0))
        self.f.command('vkBindImageMemory', device=self.w.DEVICE, image=depth_img,
                       memory=self.w.MEMORY, memoryOffset=4608)
        depth_view = 0x700020009002
        self.f.command('vkCreateImageView', device=self.w.DEVICE, pView=depth_view,
            pCreateInfo=self.w.structure('VkImageViewCreateInfo', pNext=[], flags=0,
                image=depth_img, viewType=1, format=126,
                components=self.w.structure('VkComponentMapping',
                                            r=0, g=0, b=0, a=0),
                subresourceRange=self.w.structure('VkImageSubresourceRange',
                    aspectMask=2, baseMipLevel=0, levelCount=1,
                    baseArrayLayer=0, layerCount=1)))
        self.f.begin()
        self.begin(colors=[self.attachment()],
                   depth=self.attachment(view=depth_view, layout=3))
        state = self.dynamic()
        rp = state.render_pass_state
        self.assertEqual(len(rp.attachments), 2)
        self.assertEqual(rp.depths, ((1, 3),))
        self.assertEqual(len(state.framebuffer_state.attachments), 2)
        self.assertEqual(len(state.attachment_ops), 2)

    def test_begin_synthesizes_multiple_color_attachments(self):
        # MRT: a second colour target (distinct VkFormat 44) parked at a free
        # offset; the synthesized RenderPass/Framebuffer/operand must carry
        # both attachments with independent loadOp/clearValue records.
        img2, view2 = 0x700000008000, 0x700020008002
        self.f.command('vkCreateImage', device=self.w.DEVICE, pImage=img2,
            pCreateInfo=self.w.structure('VkImageCreateInfo', pNext=[], flags=0,
                imageType=1, format=44,
                extent=self.w.structure('VkExtent3D', width=8, height=4,
                                        depth=1),
                mipLevels=1, arrayLayers=1, samples=1, tiling=0, usage=0x13,
                sharingMode=0, queueFamilyIndexCount=0, pQueueFamilyIndices=[],
                initialLayout=0))
        self.f.command('vkBindImageMemory', device=self.w.DEVICE, image=img2,
                       memory=self.w.MEMORY, memoryOffset=2048)
        self.f.command('vkCreateImageView', device=self.w.DEVICE, pView=view2,
            pCreateInfo=self.w.structure('VkImageViewCreateInfo', pNext=[],
                flags=0, image=img2, viewType=1, format=44,
                components=self.w.structure('VkComponentMapping',
                                            r=0, g=0, b=0, a=0),
                subresourceRange=self.w.structure('VkImageSubresourceRange',
                    aspectMask=1, baseMipLevel=0, levelCount=1,
                    baseArrayLayer=0, layerCount=1)))
        self.f.begin()
        self.begin(colors=[
            self.attachment(clear=(1, 2, 3, 4)),
            self.attachment(view=view2, clear=(5, 6, 7, 8))])
        state = self.dynamic()
        rp = state.render_pass_state
        self.assertEqual(len(rp.attachments), 2)
        self.assertEqual(rp.attachments[0][0], 37)
        self.assertEqual(rp.attachments[1][0], 44)
        self.assertEqual(rp.colors, ((0, 2), (1, 2)))
        self.assertEqual(len(state.framebuffer_state.attachments), 2)
        self.assertEqual(len(state.operand.attachments), 2)
        self.assertEqual(state.attachment_ops,
                         ((1, 0, (1, 2, 3, 4)), (1, 0, (5, 6, 7, 8))))


class DynamicDrawTests(draw_fixture.DrawReplayTests):
    """End-to-end vkCmdBeginRendering -> vkCmdDraw -> vkCmdEndRendering."""

    def dyn_pipeline(self, formats=(37,)):
        s = self.w.structure
        pri = s('VkPipelineRenderingCreateInfo', pNext=[], viewMask=0,
                colorAttachmentCount=len(formats),
                pColorAttachmentFormats=list(formats),
                depthAttachmentFormat=0, stencilAttachmentFormat=0,
                renderPass=0, subpass=0)
        self.f.command('vkCreateGraphicsPipelines', device=self.w.DEVICE,
            pipelineCache=0, createInfoCount=1, pPipelines=[self.PIPE2],
            pCreateInfos=[s('VkGraphicsPipelineCreateInfo', pNext=[pri], flags=0,
                stageCount=2, pStages=[
                    s('VkPipelineShaderStageCreateInfo', pNext=[], flags=0,
                        stage=1, module=self.VS2, pName='main',
                        pSpecializationInfo=None),
                    s('VkPipelineShaderStageCreateInfo', pNext=[], flags=0,
                        stage=0x10, module=self.FS2, pName='main',
                        pSpecializationInfo=None)],
                pVertexInputState=s('VkPipelineVertexInputStateCreateInfo',
                    pNext=[], flags=0, vertexBindingDescriptionCount=1,
                    pVertexBindingDescriptions=[s(
                        'VkVertexInputBindingDescription', binding=0,
                        stride=24, inputRate=0)],
                    vertexAttributeDescriptionCount=2,
                    pVertexAttributeDescriptions=[
                        s('VkVertexInputAttributeDescription', location=0,
                          binding=0, format=103, offset=0),
                        s('VkVertexInputAttributeDescription', location=1,
                          binding=0, format=109, offset=8)]),
                pInputAssemblyState=s('VkPipelineInputAssemblyStateCreateInfo',
                    pNext=[], flags=0, topology=3, primitiveRestartEnable=0),
                pTessellationState=None,
                pViewportState=s('VkPipelineViewportStateCreateInfo', pNext=[],
                    flags=0, viewportCount=1, pViewports=[], scissorCount=1,
                    pScissors=[]),
                pRasterizationState=s('VkPipelineRasterizationStateCreateInfo',
                    pNext=[], flags=0, depthClampEnable=0,
                    rasterizerDiscardEnable=0, polygonMode=0, cullMode=0,
                    frontFace=0, depthBiasEnable=0, depthBiasConstantFactor=0,
                    depthBiasClamp=0, depthBiasSlopeFactor=0,
                    lineWidth=0x3F800000),
                pMultisampleState=s('VkPipelineMultisampleStateCreateInfo',
                    pNext=[], flags=0, rasterizationSamples=1,
                    sampleShadingEnable=0, minSampleShading=0, pSampleMask=[],
                    alphaToCoverageEnable=0, alphaToOneEnable=0),
                pDepthStencilState=None,
                pColorBlendState=s('VkPipelineColorBlendStateCreateInfo',
                    pNext=[], flags=0, logicOpEnable=0, logicOp=0,
                    attachmentCount=len(formats),
                    pAttachments=[s('VkPipelineColorBlendAttachmentState',
                        blendEnable=0, srcColorBlendFactor=1,
                        dstColorBlendFactor=0, colorBlendOp=0,
                        srcAlphaBlendFactor=1, dstAlphaBlendFactor=0,
                        alphaBlendOp=0, colorWriteMask=15)
                        for _ in formats],
                    blendConstants=[0, 0, 0, 0]),
                pDynamicState=s('VkPipelineDynamicStateCreateInfo', pNext=[],
                    flags=0, dynamicStateCount=2, pDynamicStates=[0, 1]),
                layout=self.g.PL, renderPass=0, subpass=0,
                basePipelineHandle=0, basePipelineIndex=-1)])

    def begin_rendering(self, load=1, clear=(0, 0, 0, 0x3F800000), view=None,
                        depth=None, stencil=None):
        s = self.w.structure
        ca = s('VkRenderingAttachmentInfo', imageView=view or self.g.r.VIEW,
            imageLayout=2, resolveMode=0, resolveImageView=0,
            resolveImageLayout=0, loadOp=load, storeOp=0,
            clearValue=s('VkClearValue', color=s('VkClearColorValue',
                uint32=list(clear))))
        self.f.command('vkCmdBeginRendering', commandBuffer=self.f.CB,
            pRenderingInfo=s('VkRenderingInfo', pNext=[], flags=0,
                renderArea=s('VkRect2D', offset=s('VkOffset2D', x=0, y=0),
                    extent=s('VkExtent2D', width=8, height=4)),
                layerCount=1, viewMask=0, colorAttachmentCount=1,
                pColorAttachments=[ca], pDepthAttachment=depth,
                pStencilAttachment=stencil))

    def dyn_depth_view(self, fmt=126):
        s = self.w.structure
        self.f.command('vkCreateImage', device=self.w.DEVICE, pImage=self.DIMAGE,
            pCreateInfo=s('VkImageCreateInfo', pNext=[], flags=0, imageType=1,
                format=fmt,
                extent=s('VkExtent3D', width=8, height=4, depth=1),
                mipLevels=1, arrayLayers=1, samples=1, tiling=0, usage=0x23,
                sharingMode=0, queueFamilyIndexCount=0, pQueueFamilyIndices=[],
                initialLayout=0))
        self.f.command('vkBindImageMemory', device=self.w.DEVICE,
            image=self.DIMAGE, memory=self.w.MEMORY, memoryOffset=self.DEPTH_OFF)
        self.f.command('vkCreateImageView', device=self.w.DEVICE, pView=self.DVIEW,
            pCreateInfo=s('VkImageViewCreateInfo', pNext=[], flags=0,
                image=self.DIMAGE, viewType=1, format=fmt,
                components=s('VkComponentMapping', r=0, g=0, b=0, a=0),
                subresourceRange=s('VkImageSubresourceRange', aspectMask=2,
                    baseMipLevel=0, levelCount=1, baseArrayLayer=0,
                    layerCount=1)))

    def depth_attachment(self, view=None, load=1, depth=1.0, stencil=0,
                         layout=3):
        # wire VkClearValue union has no depthStencil arm: the depth clear
        # rides colour.uint32[0] as float32 bits; uint32[1][7:0] is the
        # stencil byte for packed D24S8 (device fmt 14).
        s = self.w.structure
        dbits = struct.unpack('<I', struct.pack('<f', depth))[0]
        return s('VkRenderingAttachmentInfo', imageView=view or self.DVIEW,
            imageLayout=layout, resolveMode=0, resolveImageView=0,
            resolveImageLayout=0, loadOp=load, storeOp=0,
            clearValue=s('VkClearValue', color=s('VkClearColorValue',
                uint32=[dbits, stencil, 0, 0])))

    def dyn_prepared(self, **kw):
        self.dyn_pipeline()
        self.begin_rendering(**kw)
        self.viewport()
        self.scissor()
        self.bind()
        self.draw()
        self.f.command('vkCmdEndRendering', commandBuffer=self.f.CB)
        self.f.end()

    def test_dynamic_rendering_draw_clears_and_shades(self):
        self.upload(self.ndc_triangle())
        self.dyn_prepared()
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        stats = job.drawexec_stats[job.operation - 1]
        self.assertEqual(stats['triangles'], 1)
        for x, y in ((0, 0), (1, 1), (2, 0), (0, 2), (4, 1)):
            self.assertEqual(self.read_texel(x, y), self.fc_texel(x, y))
        # loadOp=CLEAR leaves the uncovered corner at the clear texel
        self.assertEqual(self.read_texel(7, 3), self.clear_texel())
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_dynamic_rendering_draw_without_clear_keeps_memory(self):
        # loadOp=LOAD: no clear pattern ops precede the draw; the
        # uncovered corner keeps whatever the attachment already held.
        self.upload(self.ndc_triangle())
        # pre-seed the attachment with a sentinel via a fill is complex;
        # LOAD simply must not emit clears — the draw still shades.
        self.dyn_prepared(load=0)
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        for x, y in ((0, 0), (1, 1), (2, 0)):
            self.assertEqual(self.read_texel(x, y), self.fc_texel(x, y))

    def test_dynamic_rendering_depth_clear(self):
        # D32_SFLOAT (VkFormat 126 -> device fmt 12): loadOp=CLEAR fills the
        # depth attachment with the float32 clearValue over the render area,
        # independent of any draw.
        self.dyn_depth_view(fmt=126)
        self.begin_rendering(load=0,
                             depth=self.depth_attachment(depth=0.25))
        self.f.command('vkCmdEndRendering', commandBuffer=self.f.CB)
        self.f.end()
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        for x, y in ((0, 0), (3, 2), (7, 3)):
            self.assertAlmostEqual(self.read_depth(x, y), 0.25)

    def test_dynamic_rendering_ds_clear_packs_stencil(self):
        # D24_UNORM_S8_UINT (VkFormat 129 -> device fmt 14): the packed word
        # is {stencil[31:24], depth_unorm24[23:0]} — img_clear_texel reads
        # uint32[0] as float32->unorm24 depth and uint32[1][7:0] as stencil.
        self.dyn_depth_view(fmt=129)
        self.begin_rendering(load=0,
                             depth=self.depth_attachment(depth=1.0,
                                                          stencil=0xAB))
        self.f.command('vkCmdEndRendering', commandBuffer=self.f.CB)
        self.f.end()
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        word = self.read_ds(0, 0)
        self.assertEqual(word >> 24 & 0xFF, 0xAB)
        self.assertEqual(word & 0xFFFFFF, 0xFFFFFF)  # depth 1.0 -> unorm24 max


if __name__ == '__main__':
    unittest.main()
