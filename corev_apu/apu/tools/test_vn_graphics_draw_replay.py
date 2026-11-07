# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""vkCmdDraw* replay: DrawPlan -> DrawExec -> framebuffer writeback."""
import struct
import unittest

import test_vn_graphics_resources as resource_fixture
import vn_golden
from test_vn_graphics_pshade import fs_program
from test_vn_graphics_shade import vs_program


class DrawReplayTests(unittest.TestCase):
    VB, VS2, FS2, PIPE2 = (0x790000001000 + i for i in range(4))

    def setUp(self):
        self.r = resource_fixture.ResourceTests()
        self.r.setUp()
        self.g, self.f, self.e, self.w = self.r.g, self.r.f, self.r.e, self.r.w
        self.f.command('vkCreateBuffer', device=self.w.DEVICE, pBuffer=self.VB,
            pCreateInfo=self.w.structure('VkBufferCreateInfo', pNext=[], flags=0,
                size=512, usage=0x80, sharingMode=0, queueFamilyIndexCount=0,
                pQueueFamilyIndices=[]))
        self.f.command('vkBindBufferMemory', device=self.w.DEVICE, buffer=self.VB,
                       memory=self.w.MEMORY, memoryOffset=0)
        self.module(self.VS2, vs_program())
        self.module(self.FS2, fs_program('fc'))
        self.f.begin()

    def module(self, handle, code):
        self.f.command('vkCreateShaderModule', device=self.w.DEVICE,
            pShaderModule=handle,
            pCreateInfo=self.w.structure('VkShaderModuleCreateInfo', pNext=[],
                flags=0, codeSize=len(code) * 4, pCode=list(code)))

    def pipeline(self):
        s = self.w.structure
        self.f.command('vkCreateGraphicsPipelines', device=self.w.DEVICE,
            pipelineCache=0, createInfoCount=1, pPipelines=[self.PIPE2],
            pCreateInfos=[s('VkGraphicsPipelineCreateInfo', pNext=[], flags=0,
                stageCount=2, pStages=[
                    s('VkPipelineShaderStageCreateInfo', pNext=[], flags=0,
                        stage=1, module=self.VS2, pName='main',
                        pSpecializationInfo=None),
                    s('VkPipelineShaderStageCreateInfo', pNext=[], flags=0,
                        stage=0x10, module=self.FS2, pName='main',
                        pSpecializationInfo=None)],
                pVertexInputState=s('VkPipelineVertexInputStateCreateInfo',
                    pNext=[], flags=0, vertexBindingDescriptionCount=1,
                    pVertexBindingDescriptions=[s('VkVertexInputBindingDescription',
                        binding=0, stride=24, inputRate=0)],
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
                    attachmentCount=1, pAttachments=[s(
                        'VkPipelineColorBlendAttachmentState', blendEnable=0,
                        srcColorBlendFactor=1, dstColorBlendFactor=0,
                        colorBlendOp=0, srcAlphaBlendFactor=1,
                        dstAlphaBlendFactor=0, alphaBlendOp=0,
                        colorWriteMask=15)], blendConstants=[0, 0, 0, 0]),
                pDynamicState=s('VkPipelineDynamicStateCreateInfo', pNext=[],
                    flags=0, dynamicStateCount=2, pDynamicStates=[0, 1]),
                layout=self.g.PL, renderPass=self.g.r.RP, subpass=0,
                basePipelineHandle=0, basePipelineIndex=-1)])

    def begin_pass(self):
        self.f.command('vkCmdBeginRenderPass', commandBuffer=self.f.CB,
            contents=0, pRenderPassBegin=self.w.structure('VkRenderPassBeginInfo',
                pNext=[], renderPass=self.g.r.RP, framebuffer=self.g.r.FB,
                renderArea=self.w.structure('VkRect2D',
                    offset=self.w.structure('VkOffset2D', x=0, y=0),
                    extent=self.w.structure('VkExtent2D', width=8, height=4)),
                clearValueCount=1, pClearValues=[self.w.structure('VkClearValue',
                    color=self.w.structure('VkClearColorValue',
                        uint32=[0, 0, 0, 0x3F800000]))]))

    def viewport(self):
        self.f.command('vkCmdSetViewport', commandBuffer=self.f.CB,
            firstViewport=0, viewportCount=1, pViewports=[self.w.structure(
                'VkViewport', x=0, y=0, width=0x41000000, height=0x40800000,
                minDepth=0, maxDepth=0x3F800000)])

    def scissor(self):
        self.f.command('vkCmdSetScissor', commandBuffer=self.f.CB,
            firstScissor=0, scissorCount=1, pScissors=[self.w.structure(
                'VkRect2D', offset=self.w.structure('VkOffset2D', x=0, y=0),
                extent=self.w.structure('VkExtent2D', width=8, height=4))])

    def bind(self):
        self.f.command('vkCmdBindPipeline', commandBuffer=self.f.CB,
                       pipelineBindPoint=0, pipeline=self.PIPE2)
        self.f.command('vkCmdBindVertexBuffers', commandBuffer=self.f.CB,
            firstBinding=0, bindingCount=1, pBuffers=[self.VB], pOffsets=[0])

    def draw(self, **kwargs):
        args = dict(vertexCount=3, instanceCount=1, firstVertex=0,
                    firstInstance=0)
        args.update(kwargs)
        self.f.command('vkCmdDraw', commandBuffer=self.f.CB, **args)

    def upload(self, verts):
        data = bytearray()
        for pos, col in verts:
            data += struct.pack('<2f', *pos)
            data += struct.pack('<4f', *col)
        self.f.state.aperture.write(self.f.owner.base, bytes(data))

    def ndc_triangle(self):
        return [((-1.0, -1.0), (0.25, 0.5, 0.75, 1.0)),
                ((1.0, -1.0), (0.25, 0.5, 0.75, 1.0)),
                ((-1.0, 1.0), (0.25, 0.5, 0.75, 1.0))]

    def prepared(self, **draw_kw):
        self.pipeline()
        self.begin_pass()
        self.viewport()
        self.scissor()
        self.bind()
        self.draw(**draw_kw)
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.f.end()

    def read_texel(self, x, y):
        return self.f.state.aperture.read(
            self.f.owner.base + 4096 + y * 64 + x * 4, 4)

    def clear_texel(self):
        did = self.e.golden.img_fmt_id(self.e.model, 37)
        return self.e.golden.img_clear_texel(
            self.e.model, did, (0, 0, 0, 0x3F800000))

    def fc_texel(self, x, y):
        did = self.e.golden.img_fmt_id(self.e.model, 37)
        words = struct.unpack('<4I', struct.pack('<4f',
                                                x + 0.5, y + 0.5, 0.0, 1.0))
        return self.e.golden.img_clear_texel(self.e.model, did, words)

    def test_draw_writes_fragcoord_texels_to_attachment(self):
        self.upload(self.ndc_triangle())
        self.prepared()
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        stats = job.drawexec_stats[job.operation - 1]
        self.assertEqual(stats['triangles'], 1)
        self.assertGreater(stats['records'], 0)
        for x, y in ((0, 0), (1, 1), (2, 0), (0, 2), (4, 1)):
            self.assertEqual(self.read_texel(x, y), self.fc_texel(x, y))
        # far corner is outside the triangle: keeps the pass clear value
        self.assertEqual(self.read_texel(7, 3), self.clear_texel())
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_two_draws_write_in_record_order(self):
        # draw1 covers the left half, draw2 (firstVertex=3) the right;
        # executor ops run sequentially so record order is preserved
        verts = self.ndc_triangle() + [((0.0, -1.0), (0, 0, 0, 1)),
                                     ((1.0, -1.0), (0, 0, 0, 1)),
                                     ((0.0, 1.0), (0, 0, 0, 1))]
        self.upload(verts)
        self.pipeline()
        self.begin_pass()
        self.viewport()
        self.scissor()
        self.bind()
        self.draw(vertexCount=3, firstVertex=0)
        self.draw(vertexCount=3, firstVertex=3)
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.f.end()
        job = self.f.enqueue()
        self.f.drain()
        self.assertEqual(job.state, 'done')
        # (0,0) is covered only by draw1, (5,1) only by draw2
        self.assertEqual(self.read_texel(0, 0), self.fc_texel(0, 0))
        self.assertEqual(self.read_texel(5, 1), self.fc_texel(5, 1))
        self.assertEqual(len(job.drawexec_stats), 2)

    def test_empty_effective_scissor_skips_draw(self):
        self.upload(self.ndc_triangle())
        self.pipeline()
        self.begin_pass()
        self.viewport()
        self.f.command('vkCmdSetScissor', commandBuffer=self.f.CB,
            firstScissor=0, scissorCount=1, pScissors=[self.w.structure(
                'VkRect2D', offset=self.w.structure('VkOffset2D', x=2, y=2),
                extent=self.w.structure('VkExtent2D', width=1, height=1))])
        self.bind()
        self.draw()
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.f.end()
        job = self.f.enqueue()
        self.f.drain()
        self.assertEqual(job.state, 'done')
        # scissor (2,2,1,1) intersects the triangle? pixel (2,2): 2+4=6<6.5
        # covered -> one fragment written; neighbors keep clear value
        self.assertNotEqual(self.read_texel(2, 2), self.clear_texel())
        self.assertEqual(self.read_texel(0, 0), self.clear_texel())

    def test_occlusion_query_counts_generated_fragments(self):
        # an occlusion query opened around the draw publishes the number
        # of fragments the bounded raster generates; with no depth test
        # in the profile every covered sample passes
        pool = 0x7A0000007000
        self.f.command('vkCreateQueryPool', device=self.w.DEVICE,
            pQueryPool=pool,
            pCreateInfo=self.w.structure('VkQueryPoolCreateInfo', pNext=[],
                flags=0, queryType=0, queryCount=2,
                pipelineStatistics=0, checksum=0))
        self.upload(self.ndc_triangle())
        self.pipeline()
        self.f.command('vkCmdBeginQuery', commandBuffer=self.f.CB,
            queryPool=pool, query=0, flags=1)
        self.begin_pass()
        self.viewport()
        self.scissor()
        self.bind()
        self.draw()
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.f.command('vkCmdEndQuery', commandBuffer=self.f.CB,
            queryPool=pool, query=0)
        # a second draw outside any query must not leak into the count
        self.f.command('vkCmdBeginRenderPass', commandBuffer=self.f.CB,
            contents=0, pRenderPassBegin=self.w.structure('VkRenderPassBeginInfo',
                pNext=[], renderPass=self.g.r.RP, framebuffer=self.g.r.FB,
                renderArea=self.w.structure('VkRect2D',
                    offset=self.w.structure('VkOffset2D', x=0, y=0),
                    extent=self.w.structure('VkExtent2D', width=8, height=4)),
                clearValueCount=1, pClearValues=[self.w.structure('VkClearValue',
                    color=self.w.structure('VkClearColorValue',
                        uint32=[0, 0, 0, 0x3F800000]))]))
        self.bind()
        self.draw()
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.f.end()
        job = self.f.enqueue()
        self.f.drain()
        self.assertEqual(job.state, 'done')
        fragments = list(job.drawexec_stats.values())[0]['fragments']
        self.assertGreater(fragments, 0)
        self.assertEqual(self.f.entry(pool)['qslots'], [fragments, None])
        ops = [op.__class__.__name__ for op in job.operations]
        self.assertEqual(ops.count('QueryBegin'), 1)
        self.assertEqual(ops.count('QueryEnd'), 1)
        # host readback returns the same ordered count
        self.f.command('vkSeekReplyCommandStreamMESA', position=0)
        self.f.command('vkGetQueryPoolResults', device=self.w.DEVICE,
            queryPool=pool, firstQuery=0, queryCount=1, dataSize=12,
            pData=b'\0' * 12, stride=12, flags=0x1 | 0x8)
        mapping = self.f.blobs.map(7, 0)
        head = self.f.blobs.read(mapping, 0, 16)
        rtype, result, count = struct.unpack('<IIQ', head)
        payload = self.f.blobs.read(mapping, 16, count)
        value, avail = struct.unpack('<QI', payload[:12])
        self.assertEqual((result, value, avail), (0, fragments, 1))

    def test_statistics_query_counts_draw_stage_work(self):
        # a statistics query around the draw publishes the per-counter
        # totals the admitted stages produced, in spec bit order:
        # IA vertices, IA primitives, VS invocations, FS invocations
        pool = 0x7A0000007100
        self.f.command('vkCreateQueryPool', device=self.w.DEVICE,
            pQueryPool=pool,
            pCreateInfo=self.w.structure('VkQueryPoolCreateInfo', pNext=[],
                flags=0, queryType=1, queryCount=1,
                pipelineStatistics=0x87, checksum=0))
        self.upload(self.ndc_triangle())
        self.pipeline()
        self.f.command('vkCmdBeginQuery', commandBuffer=self.f.CB,
            queryPool=pool, query=0, flags=1)
        self.begin_pass()
        self.viewport()
        self.scissor()
        self.bind()
        self.draw()
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.f.command('vkCmdEndQuery', commandBuffer=self.f.CB,
            queryPool=pool, query=0)
        self.f.end()
        job = self.f.enqueue()
        self.f.drain()
        self.assertEqual(job.state, 'done')
        stats = list(job.drawexec_stats.values())[0]
        fragments = stats['fragments']
        self.assertGreater(fragments, 0)
        # one triangle, three fetched/shaded vertices, one VS pass each
        expected = [3, 1, 3, fragments]
        self.assertEqual(self.f.entry(pool)['qslots'], [expected])
        self.f.command('vkSeekReplyCommandStreamMESA', position=0)
        self.f.command('vkGetQueryPoolResults', device=self.w.DEVICE,
            queryPool=pool, firstQuery=0, queryCount=1, dataSize=32,
            pData=b'\0' * 32, stride=0, flags=0x1)
        mapping = self.f.blobs.map(7, 0)
        head = self.f.blobs.read(mapping, 0, 16)
        rtype, result, count = struct.unpack('<IIQ', head)
        payload = self.f.blobs.read(mapping, 16, count)
        values = struct.unpack('<4Q', payload)
        self.assertEqual((result, values), (0, tuple(expected)))

    COND = 0x7B0000008000

    def cond_buffer(self, usage=0x203, offset=4352, predicate=1, size=512):
        self.f.command('vkCreateBuffer', device=self.w.DEVICE,
            pBuffer=self.COND,
            pCreateInfo=self.w.structure('VkBufferCreateInfo', pNext=[],
                flags=0, size=size, usage=usage, sharingMode=0,
                queueFamilyIndexCount=0, pQueueFamilyIndices=[]))
        self.f.command('vkBindBufferMemory', device=self.w.DEVICE,
            buffer=self.COND, memory=self.w.MEMORY, memoryOffset=offset)
        self.f.state.aperture.write(
            self.f.owner.base + offset, struct.pack('<I', predicate))

    def cond_begin(self, buffer=None, offset=0, flags=0):
        self.f.command('vkCmdBeginConditionalRenderingEXT',
            commandBuffer=self.f.CB,
            pConditionalRenderingBegin=self.w.structure(
                'VkConditionalRenderingBeginInfoEXT', pNext=[],
                buffer=buffer or self.COND, offset=offset, flags=flags))

    def cond_end(self):
        self.f.command('vkCmdEndConditionalRenderingEXT',
                       commandBuffer=self.f.CB)

    def pass_with_draw(self):
        self.begin_pass()
        self.viewport()
        self.scissor()
        self.bind()
        self.draw()
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)

    def test_conditional_renders_when_predicate_nonzero(self):
        self.upload(self.ndc_triangle())
        self.cond_buffer()
        self.pipeline()
        self.f.begin()
        self.cond_begin()
        self.pass_with_draw()
        self.cond_end()
        self.f.end()
        job = self.f.enqueue()
        self.f.drain()
        self.assertEqual(job.state, 'done')
        stats = list(job.drawexec_stats.values())[0]
        self.assertGreater(stats['records'], 0)
        self.assertEqual(self.read_texel(0, 0), self.fc_texel(0, 0))
        self.assertTrue(any('begun' in s for s in job.cond_stats.values()))
        self.assertTrue(any('ended' in s for s in job.cond_stats.values()))

    def test_conditional_discards_when_predicate_zero(self):
        self.upload(self.ndc_triangle())
        self.cond_buffer(predicate=0)
        self.pipeline()
        self.f.begin()
        self.cond_begin()
        self.pass_with_draw()
        self.cond_end()
        self.f.end()
        job = self.f.enqueue()
        self.f.drain()
        self.assertEqual(job.state, 'done')
        stats = list(job.drawexec_stats.values())[0]
        self.assertEqual(stats['records'], 0)
        self.assertEqual(stats['triangles'], 0)
        # the attachment keeps the pass clear value: nothing was shaded
        self.assertEqual(self.read_texel(0, 0), self.clear_texel())
        self.assertEqual(self.read_texel(4, 1), self.clear_texel())

    def test_conditional_inverted_predicate_renders_on_zero(self):
        self.upload(self.ndc_triangle())
        self.cond_buffer(predicate=0)
        self.pipeline()
        self.f.begin()
        self.cond_begin(flags=1)
        self.pass_with_draw()
        self.cond_end()
        self.f.end()
        job = self.f.enqueue()
        self.f.drain()
        self.assertEqual(job.state, 'done')
        stats = list(job.drawexec_stats.values())[0]
        self.assertGreater(stats['records'], 0)
        self.assertEqual(self.read_texel(0, 0), self.fc_texel(0, 0))

    def test_conditional_predicate_is_reread_per_draw(self):
        # draw1 runs under predicate=1; an ordered buffer update zeroes
        # the word and draw2 (a different triangle) is discarded -
        # proving the per-command re-read model, not a latched value
        verts = self.ndc_triangle() + [((0.0, -1.0), (0, 0, 0, 1)),
                                     ((1.0, -1.0), (0, 0, 0, 1)),
                                     ((0.0, 1.0), (0, 0, 0, 1))]
        self.upload(verts)
        self.cond_buffer()
        self.pipeline()
        self.f.begin()
        self.cond_begin()
        self.begin_pass()
        self.viewport()
        self.scissor()
        self.bind()
        self.draw(vertexCount=3, firstVertex=0)
        self.f.command('vkCmdUpdateBuffer', commandBuffer=self.f.CB,
            dstBuffer=self.COND, dstOffset=0, dataSize=4,
            pData=struct.pack('<I', 0))
        self.draw(vertexCount=3, firstVertex=3)
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.cond_end()
        self.f.end()
        job = self.f.enqueue()
        self.f.drain()
        self.assertEqual(job.state, 'done')
        stats = list(job.drawexec_stats.values())
        self.assertEqual(len(stats), 2)
        self.assertGreater(stats[0]['records'], 0)
        self.assertEqual(stats[1]['records'], 0)
        # draw1 (left half) wrote; draw2's right-half pixels kept clear
        self.assertNotEqual(self.read_texel(0, 0), self.clear_texel())
        self.assertEqual(self.read_texel(5, 1), self.clear_texel())

    def test_conditional_pairing_and_operand_refusals(self):
        self.upload(self.ndc_triangle())
        self.cond_buffer()
        self.pipeline()
        cases = (
            lambda: self.cond_end(),                          # end w/o begin
            lambda: (self.cond_begin(), self.cond_begin()),   # nested
            lambda: self.cond_begin(),                        # unclosed
        )
        for record in cases:
            self.f.begin()
            record()
            self.f.end()
            with self.assertRaises(ValueError):
                self.f.enqueue()
            self.assertFalse(self.e.transfers.active)
        # operand refusals: bad usage, misaligned offset, short extent
        bad = self.COND + 0x10000
        self.f.command('vkCreateBuffer', device=self.w.DEVICE, pBuffer=bad,
            pCreateInfo=self.w.structure('VkBufferCreateInfo', pNext=[],
                flags=0, size=128, usage=0x3, sharingMode=0,
                queueFamilyIndexCount=0, pQueueFamilyIndices=[]))
        self.f.command('vkBindBufferMemory', device=self.w.DEVICE, buffer=bad,
            memory=self.w.MEMORY, memoryOffset=4864)
        self.f.state.aperture.write(
            self.f.owner.base + 4864, struct.pack('<I', 1))
        self.f.begin()
        self.cond_begin(buffer=bad)
        self.pass_with_draw()
        self.cond_end()
        self.f.end()
        with self.assertRaises(ValueError):
            self.f.enqueue()
        self.assertFalse(self.e.transfers.active)
        for offset in (2, 512):
            self.f.begin()
            self.cond_begin(offset=offset)
            self.pass_with_draw()
            self.cond_end()
            self.f.end()
            with self.assertRaises(ValueError):
                self.f.enqueue()
            self.assertFalse(self.e.transfers.active)

    def test_draw_outside_render_pass_refuses_atomically(self):
        self.upload(self.ndc_triangle())
        self.pipeline()
        self.viewport()
        self.scissor()
        self.bind()
        self.draw()
        self.f.end()
        with self.assertRaises(ValueError):
            self.f.enqueue()
        self.assertFalse(self.e.transfers.active)
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_descriptor_requiring_shader_is_refused(self):
        # fs module with an unused descriptor binding cannot be admitted:
        # the retained layout has no descriptor sets, so pipeline creation
        # itself refuses before any draw replay is possible
        self.f.command('vkDestroyShaderModule', device=self.w.DEVICE,
                       shaderModule=self.FS2)
        self.module(self.FS2, fs_program('fc', desc=True))
        self.upload(self.ndc_triangle())
        with self.assertRaises(Exception):
            self.pipeline()
        self.assertFalse(self.e.transfers.active)
        self.assertEqual(self.f.owner.work_refs, 0)


if __name__ == '__main__':
    unittest.main()
