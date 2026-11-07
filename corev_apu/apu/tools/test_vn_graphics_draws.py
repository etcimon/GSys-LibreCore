# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Nonexecuting draw plans compose state without fetch, raster or leases."""
import unittest

import test_vn_graphics_resources as resource_fixture
from vn_graphics_draws import GraphicsDraws
from vn_graphics_pipelines import operand as pipeline_operand


class DrawTests(unittest.TestCase):
    POOL, SET, VB, IB, XB, PIPE2 = (0x780000001000 + i for i in range(6))

    def setUp(self):
        self.r = resource_fixture.ResourceTests()
        self.r.setUp()
        self.g, self.f, self.e, self.w = self.r.g, self.r.f, self.r.e, self.r.w
        for handle, usage, size, offset in (
                (self.VB, 0x80, 512, 0), (self.IB, 0x40, 128, 512),
                (self.XB, 0x100, 64, 1024)):
            self.f.command('vkCreateBuffer', device=self.w.DEVICE, pBuffer=handle,
                pCreateInfo=self.w.structure('VkBufferCreateInfo', pNext=[], flags=0,
                    size=size, usage=usage, sharingMode=0, queueFamilyIndexCount=0,
                    pQueueFamilyIndices=[]))
            self.f.command('vkBindBufferMemory', device=self.w.DEVICE, buffer=handle,
                           memory=self.w.MEMORY, memoryOffset=offset)
        self.f.begin()

    def pipeline_attrs(self, *, render_pass=None, attributes=((0, 0, 109, 0),),
                       bindings=((0, 16, 0),), handle=None):
        s = self.w.structure
        self.f.command('vkCreateGraphicsPipelines', device=self.w.DEVICE, pipelineCache=0,
            createInfoCount=1, pPipelines=[handle or self.g.PIPE], pCreateInfos=[s(
                'VkGraphicsPipelineCreateInfo', pNext=[], flags=0, stageCount=2,
                pStages=[s('VkPipelineShaderStageCreateInfo', pNext=[], flags=0, stage=1,
                    module=self.g.VS, pName='main', pSpecializationInfo=None),
                    s('VkPipelineShaderStageCreateInfo', pNext=[], flags=0, stage=0x10,
                        module=self.g.FS, pName='main', pSpecializationInfo=None)],
                pVertexInputState=s('VkPipelineVertexInputStateCreateInfo', pNext=[], flags=0,
                    vertexBindingDescriptionCount=len(bindings),
                    pVertexBindingDescriptions=[s('VkVertexInputBindingDescription',
                        binding=b, stride=stride, inputRate=rate) for b, stride, rate in bindings],
                    vertexAttributeDescriptionCount=len(attributes),
                    pVertexAttributeDescriptions=[s('VkVertexInputAttributeDescription',
                        location=loc, binding=b, format=fmt, offset=off)
                        for loc, b, fmt, off in attributes]),
                pInputAssemblyState=s('VkPipelineInputAssemblyStateCreateInfo', pNext=[],
                    flags=0, topology=3, primitiveRestartEnable=0), pTessellationState=None,
                pViewportState=s('VkPipelineViewportStateCreateInfo', pNext=[], flags=0,
                    viewportCount=1, pViewports=[], scissorCount=1, pScissors=[]),
                pRasterizationState=s('VkPipelineRasterizationStateCreateInfo', pNext=[],
                    flags=0, depthClampEnable=0, rasterizerDiscardEnable=0, polygonMode=0,
                    cullMode=0, frontFace=0, depthBiasEnable=0, depthBiasConstantFactor=0,
                    depthBiasClamp=0, depthBiasSlopeFactor=0, lineWidth=0x3F800000),
                pMultisampleState=s('VkPipelineMultisampleStateCreateInfo', pNext=[], flags=0,
                    rasterizationSamples=1, sampleShadingEnable=0, minSampleShading=0,
                    pSampleMask=[], alphaToCoverageEnable=0, alphaToOneEnable=0),
                pDepthStencilState=None,
                pColorBlendState=s('VkPipelineColorBlendStateCreateInfo', pNext=[], flags=0,
                    logicOpEnable=0, logicOp=0, attachmentCount=1, pAttachments=[s(
                        'VkPipelineColorBlendAttachmentState', blendEnable=0,
                        srcColorBlendFactor=1, dstColorBlendFactor=0, colorBlendOp=0,
                        srcAlphaBlendFactor=1, dstAlphaBlendFactor=0, alphaBlendOp=0,
                        colorWriteMask=15)], blendConstants=[0, 0, 0, 0]),
                pDynamicState=s('VkPipelineDynamicStateCreateInfo', pNext=[], flags=0,
                    dynamicStateCount=2, pDynamicStates=[0, 1]),
                layout=self.g.PL, renderPass=render_pass or self.g.r.RP, subpass=0,
                basePipelineHandle=0, basePipelineIndex=-1)])

    def begin_pass(self, rp=None):
        self.f.command('vkCmdBeginRenderPass', commandBuffer=self.f.CB, contents=0,
            pRenderPassBegin=self.w.structure('VkRenderPassBeginInfo', pNext=[],
                renderPass=rp or self.g.r.RP, framebuffer=self.g.r.FB,
                renderArea=self.w.structure('VkRect2D',
                    offset=self.w.structure('VkOffset2D', x=0, y=0),
                    extent=self.w.structure('VkExtent2D', width=8, height=4)),
                clearValueCount=1, pClearValues=[self.w.structure('VkClearValue',
                    color=self.w.structure('VkClearColorValue',
                        uint32=[0, 0, 0, 0x3F800000]))]))

    def viewport(self):
        self.f.command('vkCmdSetViewport', commandBuffer=self.f.CB, firstViewport=0,
            viewportCount=1, pViewports=[self.w.structure('VkViewport', x=0, y=0,
                width=0x41000000, height=0x40800000, minDepth=0, maxDepth=0x3F800000)])

    def scissor(self):
        self.f.command('vkCmdSetScissor', commandBuffer=self.f.CB, firstScissor=0,
            scissorCount=1, pScissors=[self.w.structure('VkRect2D',
                offset=self.w.structure('VkOffset2D', x=0, y=0),
                extent=self.w.structure('VkExtent2D', width=8, height=4))])

    def bind_pipeline(self, handle=None):
        self.f.command('vkCmdBindPipeline', commandBuffer=self.f.CB,
                       pipelineBindPoint=0, pipeline=handle or self.g.PIPE)

    def bind_vb(self, first=0, buffers=(VB,), offsets=(0,)):
        self.f.command('vkCmdBindVertexBuffers', commandBuffer=self.f.CB,
            firstBinding=first, bindingCount=len(buffers), pBuffers=list(buffers),
            pOffsets=list(offsets))

    def bind_ib(self, index_type=0, offset=0):
        self.f.command('vkCmdBindIndexBuffer', commandBuffer=self.f.CB, buffer=self.IB,
                       offset=offset, indexType=index_type)

    def draw(self, name='vkCmdDraw', **kwargs):
        self.f.command(name, commandBuffer=self.f.CB, **kwargs)

    def state(self):
        recs = self.f.front.cbd[self.f.front.idmap[self.f.CB]]['recs']
        snap = next(rec['native_graphics_dynamic'] for rec in recs
                    if 'native_graphics_dynamic' in rec)
        state = GraphicsDraws(self.e, 1, snap)
        for rec in recs:
            state.replay(self.e.names[rec['ctype']], rec)
        return state

    def prepared(self, *, attrs=False, indexed=False, index_type=0, **draw_kw):
        if attrs:
            self.pipeline_attrs()
        else:
            self.g.pipeline()
        self.begin_pass()
        self.viewport()
        self.scissor()
        self.bind_pipeline()
        if attrs:
            self.bind_vb()
        if indexed:
            self.bind_ib(index_type=index_type)
        name = 'vkCmdDrawIndexed' if indexed else 'vkCmdDraw'
        args = dict(vertexCount=3, instanceCount=1, firstVertex=0, firstInstance=0)
        if indexed:
            args = dict(indexCount=3, instanceCount=1, firstIndex=0,
                        vertexOffset=0, firstInstance=0)
        args.update(draw_kw)
        self.draw(name, **args)
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.f.end()
        return self.state()

    def test_direct_draw_plan_composes_state_without_work(self):
        state = self.prepared()
        self.assertEqual(len(state.plans), 1)
        plan = state.plans[0]
        self.assertEqual((plan.command, plan.values), ('vkCmdDraw', (3, 1, 0, 0)))
        self.assertIsNone(plan.indirect)
        self.assertIsNone(plan.indices)
        self.assertEqual(plan.vertices, ())
        self.assertEqual(len(plan.attachments), 1)
        self.assertEqual(len(plan.viewport), 6)
        self.assertEqual(len(plan.scissor), 4)
        self.assertIs(plan.pipeline, pipeline_operand(self.e, 1, self.g.PIPE)[0])
        self.assertTrue(plan.references)
        plan.validate()
        self.assertEqual(self.f.owner.work_refs, 0)
        self.assertFalse(self.e.transfers.active)

    def test_indexed_draw_retains_typed_index_operand_and_signed_offset(self):
        state = self.prepared(indexed=True, vertexOffset=-7)
        plan = state.plans[0]
        self.assertEqual(plan.command, 'vkCmdDrawIndexed')
        self.assertEqual(plan.values, (3, 1, 0, 4294967289, 0))
        self.assertEqual(plan.indices.index_bytes, 2)
        self.assertEqual(plan.indices.offset, 512)
        plan.validate()

    def test_uint32_index_binding_changes_operand_width(self):
        state = self.prepared(indexed=True, index_type=1)
        self.assertEqual(state.plans[0].indices.index_bytes, 4)

    def test_vertex_attributes_resolve_guarded_spans(self):
        state = self.prepared(attrs=True)
        plan = state.plans[0]
        self.assertEqual(len(plan.vertices), 1)
        fetch = plan.vertices[0]
        self.assertEqual((fetch.location, fetch.binding, fetch.format, fetch.offset),
                         (0, 0, 109, 0))
        self.assertEqual((fetch.stride, fetch.rate), (16, 0))
        self.assertEqual(fetch.span.index_bytes, 0)
        plan.validate()

    def test_unbound_vertex_binding_is_refused(self):
        self.pipeline_attrs()
        self.begin_pass()
        self.viewport()
        self.scissor()
        self.bind_pipeline()
        self.draw('vkCmdDraw', vertexCount=3, instanceCount=1,
                  firstVertex=0, firstInstance=0)
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.f.end()
        with self.assertRaisesRegex(ValueError, 'unbound'):
            self.state()

    def test_draw_without_render_pass_is_refused(self):
        self.g.pipeline()
        self.viewport()
        self.scissor()
        self.bind_pipeline()
        self.draw('vkCmdDraw', vertexCount=3, instanceCount=1,
                  firstVertex=0, firstInstance=0)
        self.f.end()
        with self.assertRaisesRegex(ValueError, 'render pass'):
            self.state()

    def test_draw_after_end_render_pass_is_refused(self):
        self.g.pipeline()
        self.begin_pass()
        self.viewport()
        self.scissor()
        self.bind_pipeline()
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.draw('vkCmdDraw', vertexCount=3, instanceCount=1,
                  firstVertex=0, firstInstance=0)
        self.f.end()
        with self.assertRaisesRegex(ValueError, 'render pass'):
            self.state()

    def test_missing_scissor_is_refused(self):
        self.g.pipeline()
        self.begin_pass()
        self.viewport()
        self.bind_pipeline()
        self.draw('vkCmdDraw', vertexCount=3, instanceCount=1,
                  firstVertex=0, firstInstance=0)
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.f.end()
        with self.assertRaisesRegex(ValueError, 'viewport and scissor'):
            self.state()

    def test_pipeline_render_pass_mismatch_is_refused(self):
        self.g.r.render_pass(self.g.r.RP2, fmt=44)
        self.pipeline_attrs(render_pass=self.g.r.RP2)
        self.begin_pass()
        self.viewport()
        self.scissor()
        self.bind_pipeline()
        self.draw('vkCmdDraw', vertexCount=3, instanceCount=1,
                  firstVertex=0, firstInstance=0)
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.f.end()
        with self.assertRaisesRegex(ValueError, 'incompatible'):
            self.state()

    def test_later_binds_do_not_disturb_earlier_plan(self):
        self.pipeline_attrs()
        self.begin_pass()
        self.viewport()
        self.scissor()
        self.bind_pipeline()
        self.bind_vb(offsets=(64,))
        self.draw('vkCmdDraw', vertexCount=3, instanceCount=1,
                  firstVertex=0, firstInstance=0)
        self.bind_vb(offsets=(128,))
        self.draw('vkCmdDraw', vertexCount=4, instanceCount=1,
                  firstVertex=0, firstInstance=0)
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.f.end()
        state = self.state()
        self.assertEqual(len(state.plans), 2)
        first, second = state.plans
        self.assertEqual((first.vertices[0].span.offset,
                          second.vertices[0].span.offset), (64, 128))
        first.validate()
        second.validate()

    def test_compute_stage_push_is_not_consumed_by_graphics(self):
        self.g.pipeline()
        self.begin_pass()
        self.viewport()
        self.scissor()
        self.bind_pipeline()
        self.f.command('vkCmdPushConstants', commandBuffer=self.f.CB, layout=self.g.PL,
            stageFlags=0x20, offset=0, size=4,
            pValues=(5).to_bytes(4, 'little'))
        name, record = None, None
        recs = self.f.front.cbd[self.f.front.idmap[self.f.CB]]['recs']
        push_rec = next(rec for rec in recs if self.e.names[rec['ctype']] ==
                        'vkCmdPushConstants')
        snap = next(rec['native_graphics_dynamic'] for rec in recs
                    if 'native_graphics_dynamic' in rec)
        state = GraphicsDraws(self.e, 1, snap)
        for rec in recs:
            handled = state.replay(self.e.names[rec['ctype']], rec)
            if rec is push_rec:
                self.assertFalse(handled)
        self.assertEqual(state.bindings.push, {})

    def test_indirect_draw_retains_argument_operand(self):
        self.g.pipeline()
        self.begin_pass()
        self.viewport()
        self.scissor()
        self.bind_pipeline()
        self.draw('vkCmdDrawIndirect', buffer=self.XB, offset=8, drawCount=1, stride=16)
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.f.end()
        plan = self.state().plans[0]
        self.assertEqual(plan.command, 'vkCmdDrawIndirect')
        self.assertEqual(plan.values, (1, 16, 8))
        self.assertEqual((plan.indirect.index_bytes, plan.indirect.offset,
                          plan.indirect.size), (0, 1032, 16))
        plan.validate()

    def test_indirect_indexed_draw_uses_twenty_byte_record(self):
        self.g.pipeline()
        self.begin_pass()
        self.viewport()
        self.scissor()
        self.bind_pipeline()
        self.bind_ib()
        self.draw('vkCmdDrawIndexedIndirect', buffer=self.XB, offset=0,
                  drawCount=1, stride=20)
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.f.end()
        plan = self.state().plans[0]
        self.assertEqual(plan.values, (1, 20, 0))
        self.assertEqual(plan.indirect.size, 20)

    def test_indirect_draw_count_zero_is_a_recorded_noop(self):
        self.g.pipeline()
        self.begin_pass()
        self.viewport()
        self.scissor()
        self.bind_pipeline()
        self.draw('vkCmdDrawIndirect', buffer=self.XB, offset=0, drawCount=0, stride=16)
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.f.end()
        self.assertEqual(self.state().plans, [])

    def test_indirect_profile_violations_are_refused(self):
        for kwargs in (dict(drawCount=2, stride=16), dict(drawCount=1, stride=8),
                       dict(drawCount=1, stride=16, offset=60)):
            with self.subTest(kwargs=kwargs):
                case = DrawTests()
                case.setUp()
                case.g.pipeline()
                case.begin_pass()
                case.viewport()
                case.scissor()
                case.bind_pipeline()
                case.draw('vkCmdDrawIndirect', buffer=case.XB, **kwargs)
                case.f.command('vkCmdEndRenderPass', commandBuffer=case.f.CB)
                case.f.end()
                with self.assertRaises(ValueError):
                    case.state()

    def test_draw_replays_through_bounded_draw_execution(self):
        # the trivial stage_program shaders emit a degenerate off-screen
        # triangle: the draw replays but produces zero fragments
        self.prepared()
        job = self.e.replay.enqueue(1, [self.f.CB], compute=True)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        stats = job.drawexec_stats[job.operation - 1]
        self.assertEqual((stats['triangles'], stats['records']), (1, 0))
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_records_must_be_consumed_in_order(self):
        self.prepared()
        recs = self.f.front.cbd[self.f.front.idmap[self.f.CB]]['recs']
        snap = next(rec['native_graphics_dynamic'] for rec in recs
                    if 'native_graphics_dynamic' in rec)
        state = GraphicsDraws(self.e, 1, snap)
        with self.assertRaisesRegex(ValueError, 'recording order'):
            state.replay(self.e.names[recs[1]['ctype']], recs[1])


if __name__ == '__main__':
    unittest.main()
