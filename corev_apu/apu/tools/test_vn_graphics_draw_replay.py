# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""vkCmdDraw* replay: DrawPlan -> DrawExec -> framebuffer writeback."""
import struct
import unittest

import test_vn_graphics_resources as resource_fixture
import vn_golden
from test_vn_graphics_pshade import (fs_dref_gather_program, fs_dref_program,
                                     fs_gather_program,
                                     fs_image_program, fs_image_store_program,
                                     fs_program, fs_program2, fs_kill_program,
                                     fs_deriv_program,
                                     fs_proj_sample_program,
                                     fs_sample_program, fs_separate_sample_program)
from test_vn_graphics_shade import (vs_inst_program, vs_program,
                                    vs_rate_program)
from vn_graphics_writeback import (_BLEND_K255, _blend_factor, _blend_op,
                                   _f32, _lop)
from vn_native_execution import StreamFault


class DrawReplayTests(unittest.TestCase):
    VB, VS2, FS2, PIPE2, IB, XB, VS3, VB2 = (0x790000001000 + i
                                            for i in range(8))
    POOL, DSET, UBO, IMAGE, VIEW = (0x7A0000001000 + i for i in range(5))
    SAMPLER = 0x7A0000002000
    DIMAGE, DVIEW, DRP, DFB = (0x7B0000001000 + i for i in range(4))
    BIMAGE, BVIEW, BRP, BFB = (0x7C0000001000 + i for i in range(4))

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
        # index buffer for vkCmdDrawIndexed coverage: usage=0x40
        # (INDEX_BUFFER), parked at offset 512 right after the 512-byte VB.
        self.f.command('vkCreateBuffer', device=self.w.DEVICE, pBuffer=self.IB,
            pCreateInfo=self.w.structure('VkBufferCreateInfo', pNext=[], flags=0,
                size=128, usage=0x40, sharingMode=0, queueFamilyIndexCount=0,
                pQueueFamilyIndices=[]))
        self.f.command('vkBindBufferMemory', device=self.w.DEVICE, buffer=self.IB,
                       memory=self.w.MEMORY, memoryOffset=512)
        # indirect-args buffer for vkCmdDrawIndirect/vkCmdDrawIndexedIndirect:
        # usage=0x100 (INDIRECT_BUFFER), parked at offset 1024.
        self.f.command('vkCreateBuffer', device=self.w.DEVICE, pBuffer=self.XB,
            pCreateInfo=self.w.structure('VkBufferCreateInfo', pNext=[], flags=0,
                size=64, usage=0x100, sharingMode=0, queueFamilyIndexCount=0,
                pQueueFamilyIndices=[]))
        self.f.command('vkBindBufferMemory', device=self.w.DEVICE, buffer=self.XB,
                       memory=self.w.MEMORY, memoryOffset=1024)
        # second vertex buffer for the inputRate=1 (per-instance) attribute:
        # usage=0x80 (VERTEX_BUFFER), parked at offset 1088 right after XB.
        self.f.command('vkCreateBuffer', device=self.w.DEVICE, pBuffer=self.VB2,
            pCreateInfo=self.w.structure('VkBufferCreateInfo', pNext=[], flags=0,
                size=64, usage=0x80, sharingMode=0, queueFamilyIndexCount=0,
                pQueueFamilyIndices=[]))
        self.f.command('vkBindBufferMemory', device=self.w.DEVICE, buffer=self.VB2,
                       memory=self.w.MEMORY, memoryOffset=1088)
        self.module(self.VS2, vs_program())
        self.module(self.FS2, fs_program('fc'))
        self.f.begin()

    def module(self, handle, code):
        self.f.command('vkCreateShaderModule', device=self.w.DEVICE,
            pShaderModule=handle,
            pCreateInfo=self.w.structure('VkShaderModuleCreateInfo', pNext=[],
                flags=0, codeSize=len(code) * 4, pCode=list(code)))

    def pipeline(self, rp=None, subpass=0, blend=None, blend_constants=None,
                 logic_op=None, raster_discard=0, poly_mode=0, topology=3,
                 attachments=None, cull=0, front=0, restart=0, vs=None,
                 rate1=False):
        s = self.w.structure
        # rate1 adds a second vertex binding (binding1, inputRate=1,
        # stride=4) carrying a per-instance scalar float at location 2 —
        # exercises the rate-1 fetch path (inst_index addressing).
        vbinds = [s('VkVertexInputBindingDescription',
                    binding=0, stride=24, inputRate=0)]
        vattrs = [s('VkVertexInputAttributeDescription', location=0,
                    binding=0, format=103, offset=0),
                  s('VkVertexInputAttributeDescription', location=1,
                    binding=0, format=109, offset=8)]
        if rate1:
            vbinds.append(s('VkVertexInputBindingDescription',
                            binding=1, stride=4, inputRate=1))
            vattrs.append(s('VkVertexInputAttributeDescription',
                            location=2, binding=1, format=100, offset=0))
        att = dict(blendEnable=0, srcColorBlendFactor=1,
                   dstColorBlendFactor=0, colorBlendOp=0,
                   srcAlphaBlendFactor=1, dstAlphaBlendFactor=0,
                   alphaBlendOp=0, colorWriteMask=15)
        att.update(blend or {})
        atts = ([dict(a) for a in attachments] if attachments is not None
                else [att])
        for a in atts:
            a.setdefault('blendEnable', 0)
            a.setdefault('srcColorBlendFactor', 1)
            a.setdefault('dstColorBlendFactor', 0)
            a.setdefault('colorBlendOp', 0)
            a.setdefault('srcAlphaBlendFactor', 1)
            a.setdefault('dstAlphaBlendFactor', 0)
            a.setdefault('alphaBlendOp', 0)
            a.setdefault('colorWriteMask', 15)
        self.f.command('vkCreateGraphicsPipelines', device=self.w.DEVICE,
            pipelineCache=0, createInfoCount=1, pPipelines=[self.PIPE2],
            pCreateInfos=[s('VkGraphicsPipelineCreateInfo', pNext=[], flags=0,
                stageCount=2, pStages=[
                    s('VkPipelineShaderStageCreateInfo', pNext=[], flags=0,
                        stage=1, module=vs or self.VS2, pName='main',
                        pSpecializationInfo=None),
                    s('VkPipelineShaderStageCreateInfo', pNext=[], flags=0,
                        stage=0x10, module=self.FS2, pName='main',
                        pSpecializationInfo=None)],
                pVertexInputState=s('VkPipelineVertexInputStateCreateInfo',
                    pNext=[], flags=0,
                    vertexBindingDescriptionCount=len(vbinds),
                    pVertexBindingDescriptions=vbinds,
                    vertexAttributeDescriptionCount=len(vattrs),
                    pVertexAttributeDescriptions=vattrs),
                pInputAssemblyState=s('VkPipelineInputAssemblyStateCreateInfo',
                    pNext=[], flags=0, topology=topology,
                    primitiveRestartEnable=restart),
                pTessellationState=None,
                pViewportState=s('VkPipelineViewportStateCreateInfo', pNext=[],
                    flags=0, viewportCount=1, pViewports=[], scissorCount=1,
                    pScissors=[]),
                pRasterizationState=s('VkPipelineRasterizationStateCreateInfo',
                    pNext=[], flags=0, depthClampEnable=0,
                    rasterizerDiscardEnable=raster_discard, polygonMode=poly_mode,
                    cullMode=cull, frontFace=front, depthBiasEnable=0,
                    depthBiasConstantFactor=0, depthBiasClamp=0,
                    depthBiasSlopeFactor=0, lineWidth=0x3F800000),
                pMultisampleState=s('VkPipelineMultisampleStateCreateInfo',
                    pNext=[], flags=0, rasterizationSamples=1,
                    sampleShadingEnable=0, minSampleShading=0, pSampleMask=[],
                    alphaToCoverageEnable=0, alphaToOneEnable=0),
                pDepthStencilState=None,
                pColorBlendState=s('VkPipelineColorBlendStateCreateInfo',
                    pNext=[], flags=0,
                    logicOpEnable=1 if logic_op is not None else 0,
                    logicOp=logic_op if logic_op is not None else 0,
                    attachmentCount=len(atts),
                    pAttachments=[s('VkPipelineColorBlendAttachmentState',
                                    **a) for a in atts],
                    blendConstants=blend_constants or [0, 0, 0, 0]),
                pDynamicState=s('VkPipelineDynamicStateCreateInfo', pNext=[],
                    flags=0, dynamicStateCount=2, pDynamicStates=[0, 1]),
                layout=self.g.PL, renderPass=rp or self.g.r.RP,
                subpass=subpass, basePipelineHandle=0, basePipelineIndex=-1)])

    def begin_pass(self, clear=None, rp=None, fb=None, clears=None):
        # `clears` is a list of per-attachment [r,g,b,a] uint32 clears (MRT);
        # `clear` is the single-attachment shorthand.
        values = clears if clears is not None else [clear or [0, 0, 0, 0x3F800000]]
        self.f.command('vkCmdBeginRenderPass', commandBuffer=self.f.CB,
            contents=0, pRenderPassBegin=self.w.structure('VkRenderPassBeginInfo',
                pNext=[], renderPass=rp or self.g.r.RP,
                framebuffer=fb or self.g.r.FB,
                renderArea=self.w.structure('VkRect2D',
                    offset=self.w.structure('VkOffset2D', x=0, y=0),
                    extent=self.w.structure('VkExtent2D', width=8, height=4)),
                clearValueCount=len(values), pClearValues=[self.w.structure(
                    'VkClearValue', color=self.w.structure('VkClearColorValue',
                        uint32=c)) for c in values]))

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

    def fs_triangle(self):
        # fullscreen triangle (-1,-1),(3,-1),(-1,3): every 8x4 pixel
        # centre satisfies x+y<2 so the whole viewport is covered.
        return [((-1.0, -1.0), (0.0, 0.0, 0.0, 1.0)),
                ((3.0, -1.0), (0.0, 0.0, 0.0, 1.0)),
                ((-1.0, 3.0), (0.0, 0.0, 0.0, 1.0))]

    def color_triangle(self):
        # distinct per-vertex colors so flat vs smooth interpolation differ:
        # v0 red, v1 green, v2 blue (provoking vertex is v0)
        return [((-1.0, -1.0), (1.0, 0.0, 0.0, 1.0)),
                ((1.0, -1.0), (0.0, 1.0, 0.0, 1.0)),
                ((-1.0, 1.0), (0.0, 0.0, 1.0, 1.0))]

    def prepared(self, **draw_kw):
        self.pipeline()
        self.begin_pass()
        self.viewport()
        self.scissor()
        self.bind()
        self.draw(**draw_kw)
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.f.end()

    def poly_prepared(self, poly_mode, **draw_kw):
        self.pipeline(poly_mode=poly_mode)
        self.begin_pass()
        self.viewport()
        self.scissor()
        self.bind()
        self.draw(**draw_kw)
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.f.end()

    # clip-space vertices the draw's vs_program emits for ndc_triangle:
    # Position=vec4(pos.xy,0.5,1) -> (-1,-1),(1,-1),(-1,1) at z=0.5,w=1.
    NDG_CLIP = [(-1.0, -1.0, 0.5, 1.0), (1.0, -1.0, 0.5, 1.0),
                (-1.0, 1.0, 0.5, 1.0)]

    def poly_coverage(self, poly_mode):
        # expected covered framebuffer pixels for polygonMode via the
        # golden line oracle: LINE unions the three edge Bresenhams,
        # POINT the three degenerate vertex pixels.
        vp, sc, cw, ch = ((0.0, 0.0, 8.0, 4.0, 0.0, 1.0),
                          (0, 0, 8, 4), 8, 4)
        cov = set()
        for i in range(3):
            if poly_mode == 2:
                cov |= vn_golden.gfx_line_coverage(
                    [self.NDG_CLIP[i], self.NDG_CLIP[i]], vp, sc, cw, ch)
            else:
                cov |= vn_golden.gfx_line_coverage(
                    [self.NDG_CLIP[i], self.NDG_CLIP[(i + 1) % 3]],
                    vp, sc, cw, ch)
        return cov

    def line_prepared(self, topology, vertex_count, **draw_kw):
        self.pipeline(topology=topology)
        self.begin_pass()
        self.viewport()
        self.scissor()
        self.bind()
        self.draw(vertexCount=vertex_count, **draw_kw)
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.f.end()

    # clip-space endpoints the draw's vs_program emits for the uploaded
    # 2-D positions: Position=vec4(pos.xy,0.5,1) -> (x,y,0.5,1).
    LINE_SEGS = [[(-1.0, -1.0, 0.5, 1.0), (1.0, 1.0, 0.5, 1.0)],
                 [(1.0, -1.0, 0.5, 1.0), (-1.0, 1.0, 0.5, 1.0)]]

    def line_verts(self):
        # LINE_LIST vertex order: v0,v1 = segment 0; v2,v3 = segment 1.
        # Each vertex carries a constant colour (fragcoord FS ignores it).
        return [((-1.0, -1.0), (0.25, 0.5, 0.75, 1.0)),
                ((1.0, 1.0), (0.25, 0.5, 0.75, 1.0)),
                ((1.0, -1.0), (0.25, 0.5, 0.75, 1.0)),
                ((-1.0, 1.0), (0.25, 0.5, 0.75, 1.0))]

    def line_coverage(self):
        # expected covered framebuffer pixels for LINE_LIST via the golden
        # line oracle, unioned over both segments.
        vp, sc, cw, ch = ((0.0, 0.0, 8.0, 4.0, 0.0, 1.0),
                          (0, 0, 8, 4), 8, 4)
        cov = set()
        for seg in self.LINE_SEGS:
            cov |= vn_golden.gfx_line_coverage(seg, vp, sc, cw, ch)
        return cov

    # ---- bounded UNORM8 RGBA blend end-to-end ----
    # blendEnable=1 on the single colour output: pipeline retains the blend
    # tuple, draw_replay forwards it, writeback reads the stored dst texel
    # (u8*K255), applies the factors/op and the writeMask.
    def blend_prepared(self, blend, clear, blend_constants=None, **draw_kw):
        self.pipeline(blend=blend, blend_constants=blend_constants)
        self.begin_pass(clear=clear)
        self.viewport()
        self.scissor()
        self.bind()
        self.draw(**draw_kw)
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.f.end()

    def blend_clear_texel(self, clear):
        did = self.e.golden.img_fmt_id(self.e.model, 37)
        return self.e.golden.img_clear_texel(self.e.model, did, tuple(clear))

    def blend_fc_texel(self, x, y, clear, *, sf, df, cop, saf, daf, aop,
                       mask, konst=(0.0, 0.0, 0.0, 0.0)):
        # oracle-mirror of Writeback._blend_write for the fragcoord FS:
        # src=(x+0.5,y+0.5,0,1), dst = the clear texel dequantized u8*K255.
        did = self.e.golden.img_fmt_id(self.e.model, 37)
        dst = list(self.e.golden.img_clear_texel(
            self.e.model, did, tuple(clear)))
        dv = [_f32(dst[c] * _BLEND_K255) for c in range(4)]
        sv = [x + 0.5, y + 0.5, 0.0, 1.0]
        out = bytearray(4)
        for c in range(4):
            s_f, d_f, bop = (sf, df, cop) if c < 3 else (saf, daf, aop)
            sfv = _blend_factor(s_f, c, sv, dv, konst)
            dfv = _blend_factor(d_f, c, sv, dv, konst)
            res = _blend_op(bop, _f32(sv[c] * sfv), _f32(dv[c] * dfv))
            if (mask >> c) & 1:
                out[c] = vn_golden.cl_f32_u8(
                    struct.unpack('<I', struct.pack('<f', res))[0])
            else:
                out[c] = dst[c]
        return bytes(out)

    def test_blend_writes_blended_texels_to_attachment(self):
        self.upload(self.ndc_triangle())
        # ONE/ONE ADD colour + ONE/ZERO alpha over a 0.25-gray clear
        blend = dict(blendEnable=1, srcColorBlendFactor=1,
                     dstColorBlendFactor=1, colorBlendOp=0,
                     srcAlphaBlendFactor=1, dstAlphaBlendFactor=0,
                     alphaBlendOp=0, colorWriteMask=15)
        clear = [0x3E800000, 0x3E800000, 0, 0x3F800000]
        self.blend_prepared(blend, clear)
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        self.assertGreater(job.drawexec_stats[job.operation - 1]['records'], 0)
        kw = dict(sf=1, df=1, cop=0, saf=1, daf=0, aop=0, mask=15)
        for x, y in ((0, 0), (1, 1), (2, 0), (0, 2), (4, 1)):
            self.assertEqual(self.read_texel(x, y),
                             self.blend_fc_texel(x, y, clear, **kw))
        # uncovered corner keeps the clear texel (no blend applied)
        self.assertEqual(self.read_texel(7, 3), self.blend_clear_texel(clear))
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_blend_constant_factors_use_blend_constants(self):
        self.upload(self.ndc_triangle())
        # CONSTANT_COLOR/1M_CONSTANT_COLOR colour + ONE/ZERO alpha; the four
        # fp32 blendConstants ride the wire blob into the retained tuple.
        blend = dict(blendEnable=1, srcColorBlendFactor=10,
                     dstColorBlendFactor=11, colorBlendOp=0,
                     srcAlphaBlendFactor=1, dstAlphaBlendFactor=0,
                     alphaBlendOp=0, colorWriteMask=15)
        clear = [0x3E800000, 0x3E800000, 0, 0x3F800000]
        # blendConstants are fp32 bit patterns on the wire: 0.5f,0.5f,0.5f,1.0f
        self.blend_prepared(blend, clear,
                            blend_constants=[0x3F000000] * 3 + [0x3F800000])
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        self.assertGreater(job.drawexec_stats[job.operation - 1]['records'], 0)
        kw = dict(sf=10, df=11, cop=0, saf=1, daf=0, aop=0, mask=15,
                  konst=(0.5, 0.5, 0.5, 1.0))
        for x, y in ((0, 0), (1, 1), (2, 0), (0, 2), (4, 1)):
            self.assertEqual(self.read_texel(x, y),
                             self.blend_fc_texel(x, y, clear, **kw))
        self.assertEqual(self.read_texel(7, 3), self.blend_clear_texel(clear))
        self.assertEqual(self.f.owner.work_refs, 0)

    # ---- standalone colourWriteMask (blendEnable=0) end-to-end ----
    # the mask is retained per-attachment and forwarded to writeback, which
    # merges the packed src texel with the stored dst on clear mask bits.
    def masked_texel(self, x, y, clear, mask):
        # oracle-mirror of Writeback._mask_merge on the RGBA (fmt 2,
        # cmap=identity) attachment: src fragcoord texel gated per channel.
        did = self.e.golden.img_fmt_id(self.e.model, 37)
        src = list(self.e.golden.img_clear_texel(
            self.e.model, did, struct.unpack('<4I', struct.pack(
                '<4f', x + 0.5, y + 0.5, 0.0, 1.0))))
        dst = list(self.e.golden.img_clear_texel(
            self.e.model, did, tuple(clear)))
        return bytes(src[c] if (mask >> c) & 1 else dst[c] for c in range(4))

    def test_write_mask_gates_unblended_channels(self):
        self.upload(self.ndc_triangle())
        # blendEnable=0 (default) + colourWriteMask=7: RGB channels write
        # the fragcoord src, the alpha channel keeps the dst clear byte.
        self.pipeline(blend={'colorWriteMask': 7})
        clear = [0, 0, 0, 0x3F000000]      # alpha 0.5 -> dst byte 128
        self.begin_pass(clear=clear)
        self.viewport()
        self.scissor()
        self.bind()
        self.draw()
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.f.end()
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        self.assertGreater(job.drawexec_stats[job.operation - 1]['records'], 0)
        for x, y in ((0, 0), (1, 1), (2, 0), (0, 2), (4, 1)):
            self.assertEqual(self.read_texel(x, y),
                             self.masked_texel(x, y, clear, 7))
        # uncovered corner is never shaded: keeps the raw clear texel
        self.assertEqual(self.read_texel(7, 3),
                         self.e.golden.img_clear_texel(
                             self.e.model,
                             self.e.golden.img_fmt_id(self.e.model, 37),
                             tuple(clear)))
        self.assertEqual(self.f.owner.work_refs, 0)

    # ---- bounded logicOp (VkLogicOp) end-to-end ----
    # logicOpEnable=1 with blendEnable=0: writeback applies the per-channel
    # f_lop byte table on the UNORM8 src/dst encodings (cmap for BGRA).
    def logic_prepared(self, lop, clear, **draw_kw):
        self.pipeline(logic_op=lop)
        self.begin_pass(clear=clear)
        self.viewport()
        self.scissor()
        self.bind()
        self.draw(**draw_kw)
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.f.end()

    def logic_fc_texel(self, x, y, clear, lop, mask=15):
        # oracle-mirror of Writeback._logic_write on the RGBA (fmt 2,
        # cmap=identity) attachment: src fragcoord -> UNORM8 byte, f_lop
        # vs the clear dst byte, writeMask keeps dst on clear bits.
        did = self.e.golden.img_fmt_id(self.e.model, 37)
        src = struct.unpack('<4I', struct.pack('<4f',
                                               x + 0.5, y + 0.5, 0.0, 1.0))
        dst = list(self.e.golden.img_clear_texel(
            self.e.model, did, tuple(clear)))
        out = bytearray(4)
        for c in range(4):
            if (mask >> c) & 1:
                out[c] = _lop(lop, vn_golden.cl_f32_u8(src[c]), dst[c])
            else:
                out[c] = dst[c]
        return bytes(out)

    def test_logicop_xor_writes_framebuffer(self):
        self.upload(self.ndc_triangle())
        # logicOp XOR(6) over a 0.25-gray clear; blendEnable stays 0.
        clear = [0x3E800000, 0x3E800000, 0, 0x3F800000]
        self.logic_prepared(6, clear)
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        self.assertGreater(job.drawexec_stats[job.operation - 1]['records'], 0)
        for x, y in ((0, 0), (1, 1), (2, 0), (0, 2), (4, 1)):
            self.assertEqual(self.read_texel(x, y),
                             self.logic_fc_texel(x, y, clear, 6))
        self.assertEqual(self.read_texel(7, 3), self.blend_clear_texel(clear))
        self.assertEqual(self.f.owner.work_refs, 0)

    # ---- bounded rasterizerDiscardEnable end-to-end ----
    # rasterizerDiscardEnable=1: vertex fetch+shade still run, but raster
    # emits zero fragment records so writeback never fires — every
    # framebuffer texel keeps the attachment clear.
    def test_rasterizer_discard_keeps_framebuffer_clear(self):
        self.upload(self.ndc_triangle())
        clear = [0x3E800000, 0x3E800000, 0, 0x3F800000]
        self.pipeline(raster_discard=1)
        self.begin_pass(clear=clear)
        self.viewport()
        self.scissor()
        self.bind()
        self.draw()
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.f.end()
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        # zero fragment records reach writeback
        self.assertEqual(
            job.drawexec_stats[job.operation - 1]['records'], 0)
        clear_texel = self.e.golden.img_clear_texel(
            self.e.model,
            self.e.golden.img_fmt_id(self.e.model, 37),
            tuple(clear))
        # every texel — covered and uncovered — keeps the clear value
        for x in range(8):
            for y in range(4):
                self.assertEqual(self.read_texel(x, y), clear_texel)
        self.assertEqual(self.f.owner.work_refs, 0)

    # ---- bounded late-z depth end-to-end ----
    # D32_SFLOAT (VkFormat 126 -> device fmt 12) depth attachment beside the
    # colour one: render pass admits pDepthStencilAttachment, the framebuffer
    # resolves the depth view, the pipeline carries a plain depth test, and
    # draw_replay forwards (owner, offset, pitch, compareOp, writeEnable).
    DEPTH_OFF = 4608          # after the colour image (4096..4352), in 5001B mem

    def depth_resources(self, load=1, depth_load=0, fmt=126):
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
                    baseMipLevel=0, levelCount=1, baseArrayLayer=0, layerCount=1)))
        self.f.command('vkCreateRenderPass', device=self.w.DEVICE,
            pRenderPass=self.DRP,
            pCreateInfo=s('VkRenderPassCreateInfo', pNext=[], flags=0,
                attachmentCount=2,
                pAttachments=[
                    s('VkAttachmentDescription', flags=0, format=37, samples=1,
                        loadOp=load, storeOp=0, stencilLoadOp=2, stencilStoreOp=1,
                        initialLayout=0, finalLayout=1),
                    s('VkAttachmentDescription', flags=0, format=fmt, samples=1,
                        loadOp=depth_load, storeOp=1, stencilLoadOp=2,
                        stencilStoreOp=1, initialLayout=0, finalLayout=5)],
                subpassCount=1,
                pSubpasses=[s('VkSubpassDescription', flags=0,
                    pipelineBindPoint=0, inputAttachmentCount=0,
                    pInputAttachments=[], colorAttachmentCount=1,
                    pColorAttachments=[s('VkAttachmentReference',
                        attachment=0, layout=2)],
                    pResolveAttachments=[],
                    pDepthStencilAttachment=s('VkAttachmentReference',
                        attachment=1, layout=3),
                    preserveAttachmentCount=0, pPreserveAttachments=[])],
                dependencyCount=0, pDependencies=[]))
        self.f.command('vkCreateFramebuffer', device=self.w.DEVICE,
            pFramebuffer=self.DFB,
            pCreateInfo=s('VkFramebufferCreateInfo', pNext=[], flags=0,
                renderPass=self.DRP, attachmentCount=2,
                pAttachments=[self.g.r.VIEW, self.DVIEW],
                width=8, height=4, layers=1))

    def depth_pipeline(self, compare=1, write=1, blend=None, depth_test=1,
                       bounds=None, bias=None, depth_clamp=0, stencil=None):
        s = self.w.structure
        att = dict(blendEnable=0, srcColorBlendFactor=1,
                   dstColorBlendFactor=0, colorBlendOp=0,
                   srcAlphaBlendFactor=1, dstAlphaBlendFactor=0,
                   alphaBlendOp=0, colorWriteMask=15)
        att.update(blend or {})
        bmin = (struct.unpack('<I', struct.pack('<f', bounds[0]))[0]
                if bounds is not None else 0)
        bmax = (struct.unpack('<I', struct.pack('<f', bounds[1]))[0]
                if bounds is not None else 0x3F800000)
        # bias=(constantFactor, clamp, slopeFactor) fp32 -> wire uint32 bits;
        # the z_ndc is constant across the draw triangle so only the
        # constant term contributes (slope term needs a depth gradient).
        if bias is not None:
            ben = 1
            bcf = struct.unpack('<I', struct.pack('<f', bias[0]))[0]
            bcl = struct.unpack('<I', struct.pack('<f', bias[1]))[0]
            bsf = struct.unpack('<I', struct.pack('<f', bias[2]))[0]
        else:
            ben, bcf, bcl, bsf = 0, 0, 0, 0
        # stencil=(front_ops, back_ops); each ops dict carries the
        # VkStencilOpState fields (failOp/passOp/depthFailOp/compareOp/
        # compareMask/writeMask/reference).  None keeps stencilTestEnable=0.
        if stencil is None:
            front = back = dict(failOp=0, passOp=0, depthFailOp=0,
                                compareOp=0, compareMask=0, writeMask=0,
                                reference=0)
            sten = 0
        else:
            front = dict(stencil[0])
            back = dict(stencil[1])
            sten = 1
        ds = s('VkPipelineDepthStencilStateCreateInfo', pNext=[], flags=0,
            depthTestEnable=depth_test, depthWriteEnable=write,
            depthCompareOp=compare,
            depthBoundsTestEnable=1 if bounds is not None else 0,
            stencilTestEnable=sten,
            front=s('VkStencilOpState', **front),
            back=s('VkStencilOpState', **back),
            minDepthBounds=bmin, maxDepthBounds=bmax)
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
                    pVertexBindingDescriptions=[s(
                        'VkVertexInputBindingDescription', binding=0, stride=24,
                        inputRate=0)],
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
                    pNext=[], flags=0, depthClampEnable=depth_clamp,
                    rasterizerDiscardEnable=0, polygonMode=0, cullMode=0,
                    frontFace=0, depthBiasEnable=ben,
                    depthBiasConstantFactor=bcf, depthBiasClamp=bcl,
                    depthBiasSlopeFactor=bsf, lineWidth=0x3F800000),
                pMultisampleState=s('VkPipelineMultisampleStateCreateInfo',
                    pNext=[], flags=0, rasterizationSamples=1,
                    sampleShadingEnable=0, minSampleShading=0, pSampleMask=[],
                    alphaToCoverageEnable=0, alphaToOneEnable=0),
                pDepthStencilState=ds,
                pColorBlendState=s('VkPipelineColorBlendStateCreateInfo',
                    pNext=[], flags=0, logicOpEnable=0, logicOp=0,
                    attachmentCount=1, pAttachments=[s(
                        'VkPipelineColorBlendAttachmentState', **att)],
                    blendConstants=[0, 0, 0, 0]),
                pDynamicState=s('VkPipelineDynamicStateCreateInfo', pNext=[],
                    flags=0, dynamicStateCount=2, pDynamicStates=[0, 1]),
                layout=self.g.PL, renderPass=self.DRP, subpass=0,
                basePipelineHandle=0, basePipelineIndex=-1)])

    def depth_begin_pass(self, depth_clear=None, color_clear=None,
                         stencil_clear=None):
        # the wire VkClearValue union has no depthStencil arm: a depth
        # attachment's clear rides the colour uint32[0] slot as the float32
        # depth bits (img_clear_texel fmt12 consumes cw[0] verbatim); for
        # D24S8 (fmt14) uint32[1][7:0] carries the stencil byte.
        color_clear = color_clear or [0, 0, 0, 0x3F800000]
        clears = [self.w.structure('VkClearValue',
            color=self.w.structure('VkClearColorValue',
                uint32=color_clear))]
        if depth_clear is not None or stencil_clear is not None:
            dbits = (struct.unpack('<I', struct.pack('<f', depth_clear))[0]
                     if depth_clear is not None else 0)
            clears.append(self.w.structure('VkClearValue',
                color=self.w.structure('VkClearColorValue',
                    uint32=[dbits, stencil_clear or 0, 0, 0])))
        self.f.command('vkCmdBeginRenderPass', commandBuffer=self.f.CB,
            contents=0, pRenderPassBegin=self.w.structure('VkRenderPassBeginInfo',
                pNext=[], renderPass=self.DRP, framebuffer=self.DFB,
                renderArea=self.w.structure('VkRect2D',
                    offset=self.w.structure('VkOffset2D', x=0, y=0),
                    extent=self.w.structure('VkExtent2D', width=8, height=4)),
                clearValueCount=len(clears), pClearValues=clears))

    def depth_prepared(self, compare=1, write=1, depth_load=0,
                       depth_clear=None, blend=None, color_clear=None,
                       depth_test=1, bounds=None, bias=None, depth_clamp=0,
                       **draw_kw):
        self.depth_resources(depth_load=depth_load)
        self.depth_pipeline(compare=compare, write=write, blend=blend,
                            depth_test=depth_test, bounds=bounds, bias=bias,
                            depth_clamp=depth_clamp)
        self.depth_begin_pass(depth_clear=depth_clear,
                              color_clear=color_clear)
        self.viewport()
        self.scissor()
        self.bind()
        self.draw(**draw_kw)
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.f.end()

    def seed_depth(self, value):
        # float32 depth grid: pitch 64 (img_mpitch for fmt 12, width 8), 4 rows;
        # each row holds 8 texels (32B) plus 32B pitch padding
        row = struct.pack('<8f', *([value] * 8))
        buf = b''.join(row + b'\0' * 32 for _ in range(4))
        self.f.state.aperture.write(self.f.owner.base + self.DEPTH_OFF, buf)

    def read_depth(self, x, y):
        return struct.unpack('<f', self.f.state.aperture.read(
            self.f.owner.base + self.DEPTH_OFF + y * 64 + x * 4, 4))[0]

    def read_ds(self, x, y):
        # D24S8 packed word {stencil[31:24], depth_unorm24[23:0]}
        return int.from_bytes(self.f.state.aperture.read(
            self.f.owner.base + self.DEPTH_OFF + y * 64 + x * 4, 4),
            'little')

    def stencil_prepared(self, stencil, compare=7, write=1, depth_test=1,
                         depth_clear=1.0, stencil_clear=0, **draw_kw):
        self.depth_resources(depth_load=1, fmt=129)
        self.depth_pipeline(compare=compare, write=write,
                            depth_test=depth_test, stencil=stencil)
        self.depth_begin_pass(depth_clear=depth_clear,
                              stencil_clear=stencil_clear)
        self.viewport()
        self.scissor()
        self.bind()
        self.draw(**draw_kw)
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.f.end()

    def st_ops(self, fail=0, pas=0, dfail=0, cmpop=7, cmask=0xFF,
               wmask=0xFF, ref=0):
        return dict(failOp=fail, passOp=pas, depthFailOp=dfail,
                    compareOp=cmpop, compareMask=cmask, writeMask=wmask,
                    reference=ref)

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

    # ---- bounded BGRA (device fmt 4) blend end-to-end ----
    # VK_FORMAT_B8G8R8A8_UNORM stores bytes [B,G,R,A]; the writeback cmap
    # permutes logical components through it.  Single colour attachment.
    def bgr_resources(self, load=1):
        s = self.w.structure
        self.f.command('vkCreateImage', device=self.w.DEVICE, pImage=self.BIMAGE,
            pCreateInfo=s('VkImageCreateInfo', pNext=[], flags=0, imageType=1,
                format=44,
                extent=s('VkExtent3D', width=8, height=4, depth=1),
                mipLevels=1, arrayLayers=1, samples=1, tiling=0, usage=0x12,
                sharingMode=0, queueFamilyIndexCount=0, pQueueFamilyIndices=[],
                initialLayout=0))
        self.f.command('vkBindImageMemory', device=self.w.DEVICE,
            image=self.BIMAGE, memory=self.w.MEMORY, memoryOffset=4096)
        self.f.command('vkCreateImageView', device=self.w.DEVICE, pView=self.BVIEW,
            pCreateInfo=s('VkImageViewCreateInfo', pNext=[], flags=0,
                image=self.BIMAGE, viewType=1, format=44,
                components=s('VkComponentMapping', r=0, g=0, b=0, a=0),
                subresourceRange=s('VkImageSubresourceRange', aspectMask=1,
                    baseMipLevel=0, levelCount=1, baseArrayLayer=0, layerCount=1)))
        self.f.command('vkCreateRenderPass', device=self.w.DEVICE,
            pRenderPass=self.BRP,
            pCreateInfo=s('VkRenderPassCreateInfo', pNext=[], flags=0,
                attachmentCount=1,
                pAttachments=[s('VkAttachmentDescription', flags=0, format=44,
                    samples=1, loadOp=load, storeOp=0, stencilLoadOp=2,
                    stencilStoreOp=1, initialLayout=0, finalLayout=1)],
                subpassCount=1,
                pSubpasses=[s('VkSubpassDescription', flags=0,
                    pipelineBindPoint=0, inputAttachmentCount=0,
                    pInputAttachments=[], colorAttachmentCount=1,
                    pColorAttachments=[s('VkAttachmentReference',
                        attachment=0, layout=2)],
                    pResolveAttachments=[], pDepthStencilAttachment=None,
                    preserveAttachmentCount=0, pPreserveAttachments=[])],
                dependencyCount=0, pDependencies=[]))
        self.f.command('vkCreateFramebuffer', device=self.w.DEVICE,
            pFramebuffer=self.BFB,
            pCreateInfo=s('VkFramebufferCreateInfo', pNext=[], flags=0,
                renderPass=self.BRP, attachmentCount=1,
                pAttachments=[self.BVIEW], width=8, height=4, layers=1))

    def bgr_begin_pass(self, clear):
        self.f.command('vkCmdBeginRenderPass', commandBuffer=self.f.CB,
            contents=0, pRenderPassBegin=self.w.structure('VkRenderPassBeginInfo',
                pNext=[], renderPass=self.BRP, framebuffer=self.BFB,
                renderArea=self.w.structure('VkRect2D',
                    offset=self.w.structure('VkOffset2D', x=0, y=0),
                    extent=self.w.structure('VkExtent2D', width=8, height=4)),
                clearValueCount=1, pClearValues=[self.w.structure('VkClearValue',
                    color=self.w.structure('VkClearColorValue',
                        uint32=clear))]))

    def bgr_clear_texel(self, clear):
        did = self.e.golden.img_fmt_id(self.e.model, 44)
        return self.e.golden.img_clear_texel(self.e.model, did, tuple(clear))

    def bgr_prepared(self, blend, clear, **draw_kw):
        self.bgr_resources()
        self.pipeline(rp=self.BRP, blend=blend)
        self.bgr_begin_pass(clear)
        self.viewport()
        self.scissor()
        self.bind()
        self.draw(**draw_kw)
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.f.end()

    def read_bgr_texel(self, x, y):
        return self.f.state.aperture.read(
            self.f.owner.base + 4096 + y * 64 + x * 4, 4)

    def bgr_fc_texel(self, x, y, clear, *, sf, df, cop, saf, daf, aop,
                     mask, konst=(0.0, 0.0, 0.0, 0.0)):
        # oracle-mirror of Writeback._blend_write for BGRA: logical component
        # c decodes from dst byte cmap[c] (cmap=[2,1,0,3]) and the result
        # re-encodes to byte cmap[c], so the texel stays [B,G,R,A] ordered.
        cmap = (2, 1, 0, 3)
        did = self.e.golden.img_fmt_id(self.e.model, 44)
        dst = list(self.e.golden.img_clear_texel(
            self.e.model, did, tuple(clear)))
        dv = [_f32(dst[cmap[c]] * _BLEND_K255) for c in range(4)]
        sv = [x + 0.5, y + 0.5, 0.0, 1.0]
        out = bytearray(4)
        for c in range(4):
            s_f, d_f, bop = (sf, df, cop) if c < 3 else (saf, daf, aop)
            sfv = _blend_factor(s_f, c, sv, dv, konst)
            dfv = _blend_factor(d_f, c, sv, dv, konst)
            res = _blend_op(bop, _f32(sv[c] * sfv), _f32(dv[c] * dfv))
            p = cmap[c]
            if (mask >> c) & 1:
                out[p] = vn_golden.cl_f32_u8(
                    struct.unpack('<I', struct.pack('<f', res))[0])
            else:
                out[p] = dst[p]
        return bytes(out)

    def test_blend_bgra_writes_permuted_texels(self):
        self.upload(self.ndc_triangle())
        # ONE/ONE ADD colour + ONE/ZERO alpha over a BGRA clear; the dst
        # decode and result encode must permute through the BGRA cmap.
        blend = dict(blendEnable=1, srcColorBlendFactor=1,
                     dstColorBlendFactor=1, colorBlendOp=0,
                     srcAlphaBlendFactor=1, dstAlphaBlendFactor=0,
                     alphaBlendOp=0, colorWriteMask=15)
        clear = [0x3E800000, 0x3E800000, 0, 0x3F800000]
        self.bgr_prepared(blend, clear)
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        self.assertGreater(job.drawexec_stats[job.operation - 1]['records'], 0)
        kw = dict(sf=1, df=1, cop=0, saf=1, daf=0, aop=0, mask=15)
        for x, y in ((0, 0), (1, 1), (2, 0), (0, 2), (4, 1)):
            self.assertEqual(self.read_bgr_texel(x, y),
                             self.bgr_fc_texel(x, y, clear, **kw))
        # uncovered corner keeps the BGRA clear texel
        self.assertEqual(self.read_bgr_texel(7, 3),
                         self.bgr_clear_texel(clear))
        self.assertEqual(self.f.owner.work_refs, 0)

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

    def test_fs_kill_discards_fragments_per_pixel(self):
        # fs_kill_program OpKills every fragment with FragCoord.x < 4.0
        # (columns 0-3) and writes vec4(0,1,0,1) elsewhere.  The fullscreen
        # triangle covers all 32 pixels, so columns 0-3 keep the pass
        # clear while columns 4-7 take the green write — per-fragment
        # conditional discard through the real vkCmdDraw path.
        self.f.command('vkDestroyShaderModule', device=self.w.DEVICE,
                       shaderModule=self.FS2)
        self.module(self.FS2, fs_kill_program())
        self.upload(self.fs_triangle())
        self.prepared()
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        stats = job.drawexec_stats[job.operation - 1]
        self.assertGreater(stats['records'], 0)
        did = self.e.golden.img_fmt_id(self.e.model, 37)
        green = self.e.golden.img_clear_texel(
            self.e.model, did,
            struct.unpack('<4I', struct.pack('<4f', 0.0, 1.0, 0.0, 1.0)))
        for x in range(8):
            for y in range(4):
                want = green if x >= 4 else self.clear_texel()
                self.assertEqual(self.read_texel(x, y), want,
                                 'texel (%d,%d)' % (x, y))
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_fs_derivatives_read_quad_neighbours(self):
        # fs_deriv_program outputs vec4(dFdx(vcol.x), dFdy(vcol.y),
        # fwidth(vcol.z), dFdxFine(vcol.x)).  Quad derivatives read the
        # 2x2 screen-neighbour lanes, so the FS-in records must reach the
        # model in quad lane order (TL,TR,BL,BR per four).  Expected
        # values come from the golden smooth-interp map: coarse dFdx is
        # TR-TL broadcast quad-wide, coarse dFdy is BL-TL, coarse
        # fwidth is |dx|+|dy|, and fine dFdx is the per-row horizontal
        # neighbour diff (TR-TL on the top row, BR-BL on the bottom).
        self.f.command('vkDestroyShaderModule', device=self.w.DEVICE,
                       shaderModule=self.FS2)
        self.module(self.FS2, fs_deriv_program())
        pos = [(-1.0, -1.0), (3.0, -1.0), (-1.0, 3.0)]
        col = [(0.0, 0.0, 0.0, 1.0), (1.0, 0.5, 0.25, 1.0),
               (0.0, 1.0, 0.75, 1.0)]
        self.upload(list(zip(pos, col)))
        self.prepared()
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        stats = job.drawexec_stats[job.operation - 1]
        self.assertGreater(stats['records'], 0)
        verts = [(x, y, 0.5, 1.0) for x, y in pos]
        vc = vn_golden.gfx_grad_pixels(
            verts, col, (0.0, 0.0, 8.0, 4.0, 0.0, 1.0), (0, 0, 8, 4),
            8, 4, True, 0)
        did = self.e.golden.img_fmt_id(self.e.model, 37)

        def fsub(a, b):
            return vn_golden._f32(a - b)

        for py in range(4):
            for px in range(8):
                qx, qy = px & ~1, py & ~1
                vtl, vtr = vc[(qx, qy)], vc[(qx + 1, qy)]
                vbl, vbr = vc[(qx, qy + 1)], vc[(qx + 1, qy + 1)]
                dx = fsub(vtr[0], vtl[0])              # coarse dFdx comp0
                dy = fsub(vbl[1], vtl[1])              # coarse dFdy comp1
                fw = vn_golden._f32(abs(fsub(vtr[2], vtl[2])) +
                                    abs(fsub(vbl[2], vtl[2])))
                # fine dFdx: top quad row reads TR-TL, bottom BR-BL.
                if py & 1:
                    dxf = fsub(vbr[0], vbl[0])
                else:
                    dxf = dx
                words = struct.unpack('<4I', struct.pack(
                    '<4f', dx, dy, fw, dxf))
                want = self.e.golden.img_clear_texel(
                    self.e.model, did, words)
                self.assertEqual(self.read_texel(px, py), want,
                                 'texel (%d,%d)' % (px, py))
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_depth_test_writes_color_and_depth(self):
        # z_win is a constant 0.5 (vs_program emits Position.z=0.5); seeding
        # the D32 attachment to 1.0 makes every covered fragment pass LESS
        # and store 0.5, while the uncovered corner keeps 1.0.
        self.upload(self.ndc_triangle())
        self.seed_depth(1.0)
        self.depth_prepared(compare=1, write=1)
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        self.assertGreater(job.drawexec_stats[job.operation - 1]['records'], 0)
        for x, y in ((0, 0), (1, 1), (2, 0), (0, 2), (4, 1)):
            self.assertEqual(self.read_texel(x, y), self.fc_texel(x, y))
            self.assertAlmostEqual(self.read_depth(x, y), 0.5, places=6)
        # uncovered corner: colour keeps the clear value, depth keeps 1.0
        self.assertEqual(self.read_texel(7, 3), self.clear_texel())
        self.assertAlmostEqual(self.read_depth(7, 3), 1.0, places=6)
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_depth_fail_drops_color_and_depth(self):
        # seed depth to 0.0 so every fragment (z_win 0.5) fails LESS: no
        # colour and no depth write anywhere.
        self.upload(self.ndc_triangle())
        self.seed_depth(0.0)
        self.depth_prepared(compare=1, write=1)
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        self.assertEqual(self.read_texel(0, 0), self.clear_texel())
        self.assertAlmostEqual(self.read_depth(0, 0), 0.0, places=6)
        self.assertAlmostEqual(self.read_depth(4, 1), 0.0, places=6)
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_stencil_pass_replace_writes_stencil_and_depth(self):
        # D24S8 packed path: stencilTestEnable + passOp=REPLACE(ref 0x5A)
        # under compareOp=ALWAYS writes the stencil byte on every covered
        # fragment while depth (z_win 0.5 -> u24 0x800000) commits; the
        # uncovered corner keeps the {stencil=0, depth=u24(1.0)} clear.
        self.upload(self.ndc_triangle())
        ops = (self.st_ops(pas=2, ref=0x5A), self.st_ops(pas=2, ref=0x5A))
        self.stencil_prepared(ops, compare=7, write=1, depth_test=1,
                              depth_clear=1.0, stencil_clear=0)
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        for x, y in ((0, 0), (1, 1), (2, 0), (0, 2), (4, 1)):
            w = self.read_ds(x, y)
            self.assertEqual(w >> 24, 0x5A)
            self.assertEqual(w & 0xFFFFFF, 0x800000)
        # uncovered corner keeps the clear {stencil=0, depth=u24(1.0)}
        w = self.read_ds(7, 3)
        self.assertEqual(w >> 24, 0)
        self.assertEqual(w & 0xFFFFFF, 0xFFFFFF)
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_stencil_fail_applies_failop_and_discards(self):
        # stencil compareOp=EQUAL(ref 0xC3) vs cleared stencil 0 fails ->
        # failOp=REPLACE writes 0xC3 to the stencil byte but the fragment
        # is discarded: no colour and the stored depth stays at the clear.
        self.upload(self.ndc_triangle())
        ops = (self.st_ops(fail=2, ref=0xC3, cmpop=2),
               self.st_ops(fail=2, ref=0xC3, cmpop=2))
        self.stencil_prepared(ops, compare=7, write=1, depth_test=1,
                              depth_clear=1.0, stencil_clear=0)
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        for x, y in ((0, 0), (4, 1)):
            self.assertEqual(self.read_texel(x, y), self.clear_texel())
            w = self.read_ds(x, y)
            self.assertEqual(w >> 24, 0xC3)          # failOp REPLACE
            self.assertEqual(w & 0xFFFFFF, 0xFFFFFF)  # depth kept at clear
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_stencil_depth_fail_applies_depthfailop(self):
        # stencil compare ALWAYS passes; depthCompareOp=NEVER fails depth
        # -> depthFailOp=REPLACE(ref 0xA5) writes the stencil byte, depth
        # is never written, and the fragment is discarded.
        self.upload(self.ndc_triangle())
        ops = (self.st_ops(dfail=2, ref=0xA5, cmpop=7),
               self.st_ops(dfail=2, ref=0xA5, cmpop=7))
        self.stencil_prepared(ops, compare=0, write=1, depth_test=1,
                              depth_clear=1.0, stencil_clear=0)
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        for x, y in ((0, 0), (4, 1)):
            self.assertEqual(self.read_texel(x, y), self.clear_texel())
            w = self.read_ds(x, y)
            self.assertEqual(w >> 24, 0xA5)          # depthFailOp REPLACE
            self.assertEqual(w & 0xFFFFFF, 0xFFFFFF)  # depth kept at clear
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_stencil_invert_op(self):
        # oracle stencil_inv: passOp=INVERT on the cleared stencil 0 ->
        # ~0 = 0xFF; the pass branch also writes frag depth u24(0.5).
        self.upload(self.ndc_triangle())
        ops = (self.st_ops(pas=5, ref=0), self.st_ops(pas=5, ref=0))
        self.stencil_prepared(ops, compare=7, write=1, depth_test=1,
                              depth_clear=1.0, stencil_clear=0)
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        for x, y in ((0, 0), (4, 1)):
            w = self.read_ds(x, y)
            self.assertEqual(w >> 24, 0xFF)          # ~0 INVERT
            self.assertEqual(w & 0xFFFFFF, 0x800000)  # depth u24(0.5)
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_stencil_incr_sat_nonzero_clear(self):
        # oracle stencil_clr: clear stencil 0x33, compareOp=EQUAL ref 0x33
        # passes -> passOp=INCR_SAT saturating-increments to 0x34.
        self.upload(self.ndc_triangle())
        ops = (self.st_ops(pas=3, cmpop=2, ref=0x33),
               self.st_ops(pas=3, cmpop=2, ref=0x33))
        self.stencil_prepared(ops, compare=7, write=1, depth_test=1,
                              depth_clear=1.0, stencil_clear=0x33)
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        for x, y in ((0, 0), (4, 1)):
            w = self.read_ds(x, y)
            self.assertEqual(w >> 24, 0x34)          # 0x33 INCR_SAT
            self.assertEqual(w & 0xFFFFFF, 0x800000)
        # uncovered keeps the nonzero {0x33, u24(1.0)} clear
        w = self.read_ds(7, 3)
        self.assertEqual(w >> 24, 0x33)
        self.assertEqual(w & 0xFFFFFF, 0xFFFFFF)
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_stencil_write_mask_gates_result(self):
        # oracle stencil_msk: passOp=REPLACE ref 0xFF under writeMask 0xF0
        # on cleared stencil 0 -> only the masked high nibble takes ref:
        # (0 & ~0xF0) | (0xFF & 0xF0) = 0xF0.
        self.upload(self.ndc_triangle())
        ops = (self.st_ops(pas=2, ref=0xFF, wmask=0xF0),
               self.st_ops(pas=2, ref=0xFF, wmask=0xF0))
        self.stencil_prepared(ops, compare=7, write=1, depth_test=1,
                              depth_clear=1.0, stencil_clear=0)
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        for x, y in ((0, 0), (4, 1)):
            w = self.read_ds(x, y)
            self.assertEqual(w >> 24, 0xF0)          # masked REPLACE
            self.assertEqual(w & 0xFFFFFF, 0x800000)
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_depth_write_disabled_is_read_only(self):
        # depthWriteEnable=0: the compare still gates colour but the stored
        # depth is left untouched.
        self.upload(self.ndc_triangle())
        self.seed_depth(1.0)
        self.depth_prepared(compare=1, write=0)
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        self.assertEqual(self.read_texel(0, 0), self.fc_texel(0, 0))
        self.assertAlmostEqual(self.read_depth(0, 0), 1.0, places=6)
        self.assertAlmostEqual(self.read_depth(7, 3), 1.0, places=6)
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_depth_clear_initializes_attachment(self):
        # depth loadOp=CLEAR: vkCmdBeginRenderPass writes the clear value
        # (riding colour uint32[0] as float32 bits) across the whole D32
        # attachment before any draw.  Seed 0.9 so a passing read of 0.25
        # proves the clear ran; GREATER lets z_win=0.5 pass and store.
        self.upload(self.ndc_triangle())
        self.seed_depth(0.9)
        self.depth_prepared(compare=4, write=1, depth_load=1, depth_clear=0.25)
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        # covered fragments pass GREATER (0.5 > 0.25) and store z_win
        self.assertAlmostEqual(self.read_depth(0, 0), 0.5, places=6)
        self.assertAlmostEqual(self.read_depth(4, 1), 0.5, places=6)
        # uncovered corner keeps the cleared 0.25 (not the 0.9 seed)
        self.assertAlmostEqual(self.read_depth(7, 3), 0.25, places=6)
        self.assertEqual(self.read_texel(7, 3), self.clear_texel())
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_occlusion_query_counts_post_depth_fragments(self):
        # an occlusion query around a late-z draw must publish the samples
        # that PASS the depth test, not the pre-test raster records: with
        # the attachment cleared to 0.0 every z_win=0.5 fragment fails LESS
        # and the count is 0 even though the raster produced fragments.
        pool = 0x7A0000008000
        self.f.command('vkCreateQueryPool', device=self.w.DEVICE,
            pQueryPool=pool,
            pCreateInfo=self.w.structure('VkQueryPoolCreateInfo', pNext=[],
                flags=0, queryType=0, queryCount=1,
                pipelineStatistics=0, checksum=0))
        self.upload(self.ndc_triangle())
        self.depth_resources(depth_load=1)
        self.depth_pipeline(compare=1, write=1)
        self.f.command('vkCmdBeginQuery', commandBuffer=self.f.CB,
            queryPool=pool, query=0, flags=1)
        self.depth_begin_pass(depth_clear=0.0)
        self.viewport()
        self.scissor()
        self.bind()
        self.draw()
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.f.command('vkCmdEndQuery', commandBuffer=self.f.CB,
            queryPool=pool, query=0)
        self.f.end()
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        stats = list(job.drawexec_stats.values())[0]
        # non-degenerate: the raster really did cover fragments, all of
        # which the depth test then rejected
        self.assertGreater(stats['fragments'], 0)
        self.assertEqual(stats['records'], 0)
        self.assertEqual(self.f.entry(pool)['qslots'], [0])
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_depth_and_blend_compose(self):
        # late-z gates the blended write: z_win=0.5 passes LESS against a
        # 1.0-seeded D32 attachment, so covered texels get the ONE/ONE-ADD
        # blend over the 0.25-gray clear and depth stores 0.5.
        self.upload(self.ndc_triangle())
        self.seed_depth(1.0)
        blend = dict(blendEnable=1, srcColorBlendFactor=1,
                     dstColorBlendFactor=1, colorBlendOp=0,
                     srcAlphaBlendFactor=1, dstAlphaBlendFactor=0,
                     alphaBlendOp=0, colorWriteMask=15)
        clear = [0x3E800000, 0x3E800000, 0, 0x3F800000]
        self.depth_prepared(compare=1, write=1, blend=blend,
                            color_clear=clear)
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        self.assertGreater(job.drawexec_stats[job.operation - 1]['records'], 0)
        kw = dict(sf=1, df=1, cop=0, saf=1, daf=0, aop=0, mask=15)
        for x, y in ((0, 0), (1, 1), (2, 0), (0, 2), (4, 1)):
            self.assertEqual(self.read_texel(x, y),
                             self.blend_fc_texel(x, y, clear, **kw))
            self.assertAlmostEqual(self.read_depth(x, y), 0.5, places=6)
        self.assertEqual(self.read_texel(7, 3), self.blend_clear_texel(clear))
        self.assertEqual(self.read_depth(7, 3), 1.0)
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_depth_fail_drops_blend_write(self):
        # stored depth 0.0 -> z_win 0.5 fails LESS everywhere: blend must
        # NOT write, so colour keeps the clear texel and depth stays 0.0.
        self.upload(self.ndc_triangle())
        self.seed_depth(0.0)
        blend = dict(blendEnable=1, srcColorBlendFactor=1,
                     dstColorBlendFactor=1, colorBlendOp=0,
                     srcAlphaBlendFactor=1, dstAlphaBlendFactor=0,
                     alphaBlendOp=0, colorWriteMask=15)
        clear = [0x3E800000, 0x3E800000, 0, 0x3F800000]
        self.depth_prepared(compare=1, write=1, blend=blend,
                            color_clear=clear)
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        stats = job.drawexec_stats[job.operation - 1]
        # every covered fragment failed the depth test: nothing written
        self.assertGreater(stats['fragments'], 0)
        self.assertEqual(stats['records'], 0)
        for x, y in ((0, 0), (1, 1), (2, 0), (0, 2), (4, 1), (7, 3)):
            self.assertEqual(self.read_texel(x, y),
                             self.blend_clear_texel(clear))
            self.assertAlmostEqual(self.read_depth(x, y), 0.0, places=6)
        self.assertEqual(self.f.owner.work_refs, 0)

    # ---- bounded depthBoundsTestEnable end-to-end ----
    # depthBoundsTestEnable=1 gates fragments by the [min,max] window on
    # window-space z_win, independent of the depth compare.  z_win=0.5
    # for the whole triangle, so a window either keeps every covered
    # fragment or drops them all.
    def test_depth_bounds_rejects_out_of_window(self):
        # bounds=[0.6,1.0] sits above z_win=0.5 with depthTestEnable=0:
        # every covered fragment fails the window -> colour keeps the
        # clear and the depth attachment keeps its 0.25 clear.
        self.upload(self.ndc_triangle())
        clear = [0x3E800000, 0x3E800000, 0, 0x3F800000]
        self.depth_prepared(depth_test=0, write=1, bounds=(0.6, 1.0),
                            depth_load=1, depth_clear=0.25,
                            color_clear=clear)
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        stats = job.drawexec_stats[job.operation - 1]
        # fragments were produced but every one failed the bounds window
        self.assertGreater(stats['fragments'], 0)
        self.assertEqual(stats['records'], 0)
        for x, y in ((0, 0), (1, 1), (2, 0), (0, 2), (4, 1), (7, 3)):
            self.assertEqual(self.read_texel(x, y),
                             self.blend_clear_texel(clear))
            self.assertAlmostEqual(self.read_depth(x, y), 0.25, places=6)
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_depth_bounds_admits_and_writes_depth(self):
        # bounds=[0.0,0.6] includes z_win=0.5 with depthTestEnable=0 and
        # depthWriteEnable=1: the window passes every covered fragment
        # and the lone depth write commits 0.5 — proving the depth
        # attachment path stays live without a depth compare.
        self.upload(self.ndc_triangle())
        clear = [0x3E800000, 0x3E800000, 0, 0x3F800000]
        self.depth_prepared(depth_test=0, write=1, bounds=(0.0, 0.6),
                            depth_load=1, depth_clear=1.0,
                            color_clear=clear)
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        self.assertGreater(job.drawexec_stats[job.operation - 1]['records'], 0)
        for x, y in ((0, 0), (1, 1), (2, 0), (0, 2), (4, 1)):
            self.assertEqual(self.read_texel(x, y), self.fc_texel(x, y))
            self.assertAlmostEqual(self.read_depth(x, y), 0.5, places=6)
        # uncovered corner keeps the colour clear and the 1.0 depth clear
        self.assertEqual(self.read_texel(7, 3),
                         self.blend_clear_texel(clear))
        self.assertAlmostEqual(self.read_depth(7, 3), 1.0, places=6)
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_depth_bias_shifts_stored_depth(self):
        # depthBiasEnable constantFactor=0.25 (slope=0, no clamp): the draw
        # triangle's z_win=0.5 is biased to 0.75 in raster, so the LESS
        # compare still passes against the 1.0 seed and the *biased* 0.75
        # — not 0.5 — is what the late-z write commits.
        self.upload(self.ndc_triangle())
        self.seed_depth(1.0)
        self.depth_prepared(compare=1, write=1, bias=(0.25, 0.0, 0.0))
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        self.assertGreater(job.drawexec_stats[job.operation - 1]['records'], 0)
        for x, y in ((0, 0), (1, 1), (2, 0), (0, 2), (4, 1)):
            self.assertEqual(self.read_texel(x, y), self.fc_texel(x, y))
            self.assertAlmostEqual(self.read_depth(x, y), 0.75, places=6)
        self.assertAlmostEqual(self.read_depth(7, 3), 1.0, places=6)
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_depth_bias_flips_compare_result(self):
        # seed depth to 0.6: unbiased z_win=0.5 would pass LESS and store,
        # but the +0.25 bias lifts it to 0.75 which now fails — no colour
        # and no depth write anywhere, proving the bias reached the
        # late-z compare (not just the write).
        self.upload(self.ndc_triangle())
        self.seed_depth(0.6)
        self.depth_prepared(compare=1, write=1, bias=(0.25, 0.0, 0.0))
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        self.assertEqual(self.read_texel(0, 0), self.clear_texel())
        self.assertAlmostEqual(self.read_depth(0, 0), 0.6, places=6)
        self.assertAlmostEqual(self.read_depth(4, 1), 0.6, places=6)
        self.assertEqual(self.f.owner.work_refs, 0)

    def _z2_vertex_shader(self):
        # rebuild VS2 emitting Position.z=2.0 (NDC depth beyond far) so
        # the draw exercises the depthClamp clip/clamp path.
        self.f.command('vkDestroyShaderModule', device=self.w.DEVICE,
                       shaderModule=self.VS2)
        self.module(self.VS2, vs_program(z=2.0))

    def test_depth_clamp_off_clips_out_of_range_geometry(self):
        # vs_program(z=2.0) -> ndc z=2.0 beyond far: depthClampEnable=0
        # near/far-clips every fragment -> no records -> colour keeps the
        # clear and depth keeps the 0.25 clear (the dclampoff oracle).
        self._z2_vertex_shader()
        self.upload(self.ndc_triangle())
        clear = [0x3E800000, 0x3E800000, 0, 0x3F800000]
        self.depth_prepared(depth_test=0, write=1, depth_clamp=0,
                            depth_load=1, depth_clear=0.25,
                            color_clear=clear)
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        self.assertEqual(job.drawexec_stats[job.operation - 1]['records'], 0)
        self.assertEqual(self.read_texel(0, 0),
                         self.blend_clear_texel(clear))
        self.assertAlmostEqual(self.read_depth(0, 0), 0.25, places=6)
        self.assertAlmostEqual(self.read_depth(4, 1), 0.25, places=6)
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_depth_clamp_on_rasterizes_and_clamps_depth(self):
        # same z=2.0 geometry with depthClampEnable=1: the near/far clip
        # is skipped so the triangle rasterizes, and each fragment's
        # window depth is clamped into [0,1] — the covered texels get the
        # fragcoord colour and store the *clamped* depth 1.0 (unclamped
        # would be 2.0), while the uncovered corner keeps the 0.25 clear.
        self._z2_vertex_shader()
        self.upload(self.ndc_triangle())
        clear = [0x3E800000, 0x3E800000, 0, 0x3F800000]
        self.depth_prepared(depth_test=0, write=1, depth_clamp=1,
                            depth_load=1, depth_clear=0.25,
                            color_clear=clear)
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        self.assertGreater(job.drawexec_stats[job.operation - 1]['records'], 0)
        for x, y in ((0, 0), (1, 1), (2, 0), (0, 2), (4, 1)):
            self.assertEqual(self.read_texel(x, y), self.fc_texel(x, y))
            self.assertAlmostEqual(self.read_depth(x, y), 1.0, places=6)
        self.assertEqual(self.read_texel(7, 3),
                         self.blend_clear_texel(clear))
        self.assertAlmostEqual(self.read_depth(7, 3), 0.25, places=6)
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_polygon_mode_line_writes_edge_coverage(self):
        # polygonMode=LINE over real vkCmdDraw: only the triangle's three
        # edges are covered — every covered texel gets fragcoord colour,
        # interior and exterior keep the clear (polyln oracle coverage).
        self.upload(self.ndc_triangle())
        self.poly_prepared(1)
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        cov = self.poly_coverage(1)
        self.assertTrue(cov)
        for x in range(8):
            for y in range(4):
                want = self.fc_texel(x, y) if (x, y) in cov \
                    else self.clear_texel()
                self.assertEqual(self.read_texel(x, y), want,
                                 'texel (%d,%d)' % (x, y))
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_polygon_mode_point_writes_vertex_pixels(self):
        # polygonMode=POINT over real vkCmdDraw: only the three vertex
        # pixels are covered — sparse fragcoord colour, rest clear
        # (polypnt oracle coverage).
        self.upload(self.ndc_triangle())
        self.poly_prepared(2)
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        cov = self.poly_coverage(2)
        self.assertTrue(0 < len(cov) <= 3)
        for x in range(8):
            for y in range(4):
                want = self.fc_texel(x, y) if (x, y) in cov \
                    else self.clear_texel()
                self.assertEqual(self.read_texel(x, y), want,
                                 'texel (%d,%d)' % (x, y))
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_line_list_topology_writes_segment_coverage(self):
        # topology=LINE_LIST over real vkCmdDraw: the four uploaded
        # vertices form two independent segments rasterized as Bresenham
        # coverage (the line oracle); covered texels get fragcoord colour,
        # the rest keep the clear.
        self.upload(self.line_verts())
        self.line_prepared(1, 4)
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        cov = self.line_coverage()
        self.assertTrue(cov)
        for x in range(8):
            for y in range(4):
                want = self.fc_texel(x, y) if (x, y) in cov \
                    else self.clear_texel()
                self.assertEqual(self.read_texel(x, y), want,
                                 'texel (%d,%d)' % (x, y))
        self.assertEqual(self.f.owner.work_refs, 0)

    def check_fb_coverage(self, cov):
        self.assertTrue(cov)
        for x in range(8):
            for y in range(4):
                want = self.fc_texel(x, y) if (x, y) in cov \
                    else self.clear_texel()
                self.assertEqual(self.read_texel(x, y), want,
                                 'texel (%d,%d)' % (x, y))
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_line_strip_topology_writes_chained_coverage(self):
        # topology=LINE_STRIP over real vkCmdDraw: three vertices form two
        # chained segments sharing the middle vertex (the lstrip oracle).
        col = (0.25, 0.5, 0.75, 1.0)
        self.upload([((-1.0, -1.0), col), ((1.0, -1.0), col),
                     ((-1.0, 1.0), col)])
        self.line_prepared(2, 3)
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        vp, sc, cw, ch = ((0.0, 0.0, 8.0, 4.0, 0.0, 1.0),
                          (0, 0, 8, 4), 8, 4)
        pts = [(-1.0, -1.0, 0.5, 1.0), (1.0, -1.0, 0.5, 1.0),
               (-1.0, 1.0, 0.5, 1.0)]
        cov = set()
        for i in range(2):
            cov |= vn_golden.gfx_line_coverage([pts[i], pts[i + 1]],
                                               vp, sc, cw, ch)
        self.check_fb_coverage(cov)

    def test_point_list_topology_writes_vertex_pixels(self):
        # topology=POINT_LIST over real vkCmdDraw: each of the three
        # vertices emits its single pixel (the polypnt oracle per-vertex).
        col = (0.25, 0.5, 0.75, 1.0)
        self.upload([((-1.0, -1.0), col), ((1.0, -1.0), col),
                     ((-1.0, 1.0), col)])
        self.line_prepared(0, 3)
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        vp, sc, cw, ch = ((0.0, 0.0, 8.0, 4.0, 0.0, 1.0),
                          (0, 0, 8, 4), 8, 4)
        cov = set()
        for p in [(-1.0, -1.0, 0.5, 1.0), (1.0, -1.0, 0.5, 1.0),
                  (-1.0, 1.0, 0.5, 1.0)]:
            cov |= vn_golden.gfx_line_coverage([p, p], vp, sc, cw, ch)
        self.check_fb_coverage(cov)

    def tri_strip_fan_prepared(self, topology, vertex_count, cull=0,
                               front=0, **draw_kw):
        self.pipeline(topology=topology, cull=cull, front=front)
        self.begin_pass()
        self.viewport()
        self.scissor()
        self.bind()
        self.draw(vertexCount=vertex_count, **draw_kw)
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.f.end()

    def test_triangle_strip_topology_writes_sliding_coverage(self):
        # topology=TRIANGLE_STRIP over real vkCmdDraw: five vertices give
        # three sliding-window triangles (v0v1v2, v1v3v2, v2v3v4) — the odd
        # primitive's slot 1/2 swap keeps one winding.  Coverage is the
        # strip oracle's union; a wrong vertex index would shift a whole
        # triangle and change the covered texels.
        col = (0.25, 0.5, 0.75, 1.0)
        self.upload([((-1.0, -1.0), col), ((-1.0, 1.0), col),
                     ((0.5, -1.0), col), ((1.0, 0.0), col),
                     ((1.0, 1.0), col)])
        self.tri_strip_fan_prepared(4, 5)
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        vp, sc, cw, ch = ((0.0, 0.0, 8.0, 4.0, 0.0, 1.0),
                          (0, 0, 8, 4), 8, 4)
        pts = [(-1.0, -1.0, 0.5, 1.0), (-1.0, 1.0, 0.5, 1.0),
               (0.5, -1.0, 0.5, 1.0), (1.0, 0.0, 0.5, 1.0),
               (1.0, 1.0, 0.5, 1.0)]
        cov = vn_golden.gfx_strip_coverage(pts, vp, sc, cw, ch, True, 0)
        self.check_fb_coverage(cov)

    def test_triangle_fan_topology_writes_anchored_coverage(self):
        # topology=TRIANGLE_FAN over real vkCmdDraw: five vertices give
        # three triangles all anchored at v0 — (v0,v1,v2), (v0,v2,v3),
        # (v0,v3,v4) — the fan oracle's sliding pair.
        col = (0.25, 0.5, 0.75, 1.0)
        self.upload([((-1.0, -1.0), col), ((-1.0, 1.0), col),
                     ((0.0, 0.5), col), ((1.0, 1.0), col),
                     ((1.0, -1.0), col)])
        self.tri_strip_fan_prepared(5, 5)
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        vp, sc, cw, ch = ((0.0, 0.0, 8.0, 4.0, 0.0, 1.0),
                          (0, 0, 8, 4), 8, 4)
        pts = [(-1.0, -1.0, 0.5, 1.0), (-1.0, 1.0, 0.5, 1.0),
               (0.0, 0.5, 0.5, 1.0), (1.0, 1.0, 0.5, 1.0),
               (1.0, -1.0, 0.5, 1.0)]
        cov = vn_golden.gfx_fan_coverage(pts, vp, sc, cw, ch, True, 0)
        self.check_fb_coverage(cov)

    def inst_prepared(self, topology, vertex_count, instance_count, step=0.4,
                      **draw_kw):
        # vs_inst_program offsets Position.x by InstanceIndex*step, so each
        # instance lands in a distinct column — exercises the BuiltIn
        # InstanceIndex record-slot-8 feed plus per-instance primitive
        # assembly.  Distinct VS3 handle: VS2 already owns vs_program.
        self.module(self.VS3, vs_inst_program(step))
        self.pipeline(topology=topology, vs=self.VS3)
        self.begin_pass()
        self.viewport()
        self.scissor()
        self.bind()
        self.draw(vertexCount=vertex_count, instanceCount=instance_count,
                  **draw_kw)
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.f.end()

    def test_instanced_draw_offsets_each_instance(self):
        # instanceCount=4 TRIANGLE_LIST with vs_inst_program(step=0.4):
        # instance i's clip-x shifts by 0.4*i, landing four triangles in
        # distinct columns.  Coverage is the per-instance oracle union — a
        # single-instance or instance-boundary-blind replay cannot reproduce
        # the spread.
        col = (0.25, 0.5, 0.75, 1.0)
        # narrow triangle centred at clip-x=-0.6 so instances 0..3 land at
        # -0.6,-0.2,+0.2,+0.6 (all inside the viewport).
        base = [(-0.75, -1.0), (-0.45, -1.0), (-0.6, 1.0)]
        self.upload([(p, col) for p in base])
        self.inst_prepared(3, 3, 4)
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        vp, sc, cw, ch = ((0.0, 0.0, 8.0, 4.0, 0.0, 1.0),
                          (0, 0, 8, 4), 8, 4)
        cov = set()
        for i in range(4):
            dx = 0.4 * i
            cov |= vn_golden.gfx_tri_coverage(
                [(x + dx, y, 0.5, 1.0) for (x, y) in base],
                vp, sc, cw, ch, True, 0)
        self.check_fb_coverage(cov)

    def test_instanced_strip_resets_assembly_per_instance(self):
        # instanceCount=2 TRIANGLE_STRIP with vs_inst_program(step=0.4):
        # four vertices per instance form two sliding-window triangles
        # each.  Without per-instance primitive assembly the strip window
        # crosses the instance boundary and emits spurious cross-instance
        # triangles — coverage would diverge from the two independent strip
        # oracles.
        col = (0.25, 0.5, 0.75, 1.0)
        # strip quad centred near clip-x=-0.2 so instance0 ~-0.2 and
        # instance1 ~+0.2 land in separate columns.
        base = [(-0.4, -1.0), (-0.4, 0.5), (0.0, -1.0), (0.0, 0.5)]
        self.upload([(p, col) for p in base])
        self.inst_prepared(4, 4, 2)
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        vp, sc, cw, ch = ((0.0, 0.0, 8.0, 4.0, 0.0, 1.0),
                          (0, 0, 8, 4), 8, 4)
        cov = set()
        for i in range(2):
            dx = 0.4 * i
            cov |= vn_golden.gfx_strip_coverage(
                [(x + dx, y, 0.5, 1.0) for (x, y) in base],
                vp, sc, cw, ch, True, 0)
        self.check_fb_coverage(cov)

    def test_instanced_draw_first_instance_offsets_index(self):
        # firstInstance shifts the InstanceIndex builtin: with
        # firstInstance=1 and instanceCount=2 the shader sees indices 1,2
        # -> clip-x offsets 0.4,0.8 (not 0,0.4).  Coverage diverges if the
        # base instance index is dropped.
        col = (0.25, 0.5, 0.75, 1.0)
        base = [(-0.75, -1.0), (-0.45, -1.0), (-0.6, 1.0)]
        self.upload([(p, col) for p in base])
        self.inst_prepared(3, 3, 2, step=0.4, firstInstance=1)
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        vp, sc, cw, ch = ((0.0, 0.0, 8.0, 4.0, 0.0, 1.0),
                          (0, 0, 8, 4), 8, 4)
        cov = set()
        for i in range(2):
            # effective InstanceIndex = firstInstance(1) + instance(i)
            dx = 0.4 * (1 + i)
            cov |= vn_golden.gfx_tri_coverage(
                [(x + dx, y, 0.5, 1.0) for (x, y) in base],
                vp, sc, cw, ch, True, 0)
        self.check_fb_coverage(cov)

    def test_instanced_indexed_restart_offsets_each_instance(self):
        # vkCmdDrawIndexed + primitiveRestartEnable + instanceCount=2 with
        # vs_inst_program: every instance replays the SAME restart-delimited
        # index stream (a u16 sentinel splits two triangles) shifted by
        # InstanceIndex*step.  Exercises fetch sentinel->breaks composes
        # with per-instance boundaries: each instance's run is independently
        # break-split, and no primitive straddles an instance edge.  A
        # boundary-blind raster would merge instance0's tail with
        # instance1's head into cross-instance triangles.
        col = (0.25, 0.5, 0.75, 1.0)
        # quad corners; indices select tri(0,1,2) and tri(2,3,0) split by
        # the 0xFFFF sentinel at index-position 3.
        pos = [(-0.7, -0.9), (-0.1, -0.9), (-0.7, 0.9), (-0.1, 0.9)]
        self.upload([(p, col) for p in pos])
        indices = [0, 1, 2, 0xFFFF, 2, 3, 0]
        self.upload_indices(indices, 0)
        self.module(self.VS3, vs_inst_program(0.4))
        self.indexed_prepared(0, len(indices), topology=3, restart=1,
                              instance_count=2, vs=self.VS3)
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        vp, sc, cw, ch = ((0.0, 0.0, 8.0, 4.0, 0.0, 1.0),
                          (0, 0, 8, 4), 8, 4)
        cov = set()
        for i in range(2):
            dx = 0.4 * i
            clip = [(x + dx, y, 0.5, 1.0) for x, y in pos]
            for tri in ([0, 1, 2], [2, 3, 0]):
                cov |= vn_golden.gfx_tri_coverage(
                    [clip[j] for j in tri], vp, sc, cw, ch, True, 0)
        self.check_fb_coverage(cov)

    def test_triangle_strip_winding_swap_holds_under_cull(self):
        # TRIANGLE_STRIP + cullMode=BACK over real vkCmdDraw: the odd-
        # primitive slot 1/2 swap keeps every triangle's winding
        # consistent, so front-facing culling resolves whole primitives
        # uniformly.  The raw (unswapped) order would alternate facing and
        # cull half the strip — coverage would diverge from the oracle.
        col = (0.25, 0.5, 0.75, 1.0)
        self.upload([((-1.0, -1.0), col), ((-1.0, 1.0), col),
                     ((0.5, -1.0), col), ((1.0, 0.0), col),
                     ((1.0, 1.0), col)])
        self.tri_strip_fan_prepared(4, 5, cull=2, front=0)
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        vp, sc, cw, ch = ((0.0, 0.0, 8.0, 4.0, 0.0, 1.0),
                          (0, 0, 8, 4), 8, 4)
        pts = [(-1.0, -1.0, 0.5, 1.0), (-1.0, 1.0, 0.5, 1.0),
               (0.5, -1.0, 0.5, 1.0), (1.0, 0.0, 0.5, 1.0),
               (1.0, 1.0, 0.5, 1.0)]
        cov = vn_golden.gfx_strip_coverage(pts, vp, sc, cw, ch, True, 2)
        self.check_fb_coverage(cov)

    # ---- bounded indexed draws (vkCmdDrawIndexed) end-to-end ----
    # The index buffer reorders/selects vertex records before shading;
    # coverage is the per-triple gfx_tri_coverage union over the indexed
    # vertex order.  Indices that skip or permute vertices make a broken
    # (index-ignoring) replay diverge from the oracle.
    IB_OFF = 512

    def upload_indices(self, indices, index_type):
        fmt = '<H' if index_type == 0 else '<I'
        data = b''.join(struct.pack(fmt, i) for i in indices)
        self.f.state.aperture.write(self.f.owner.base + self.IB_OFF, data)

    def indexed_prepared(self, index_type, index_count, first_index=0,
                         vertex_offset=0, topology=3, restart=0,
                         instance_count=1, first_instance=0, vs=None):
        self.pipeline(topology=topology, restart=restart, vs=vs)
        self.begin_pass()
        self.viewport()
        self.scissor()
        self.bind()
        self.f.command('vkCmdBindIndexBuffer', commandBuffer=self.f.CB,
                       buffer=self.IB, offset=0, indexType=index_type)
        self.f.command('vkCmdDrawIndexed', commandBuffer=self.f.CB,
                       indexCount=index_count, instanceCount=instance_count,
                       firstIndex=first_index, vertexOffset=vertex_offset,
                       firstInstance=first_instance)
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.f.end()

    def indexed_coverage(self, clip, indices):
        # clip = per-vertex clip positions; indices select/reorder them
        # into TRIANGLE_LIST triples for the golden coverage union.
        vp, sc, cw, ch = ((0.0, 0.0, 8.0, 4.0, 0.0, 1.0),
                          (0, 0, 8, 4), 8, 4)
        cov = set()
        for t in range(0, len(indices), 3):
            tri = [clip[indices[t + k]] for k in range(3)]
            cov |= vn_golden.gfx_tri_coverage(tri, vp, sc, cw, ch, True, 0)
        return cov

    def test_draw_indexed_uint16_reorders_vertices(self):
        # uint16 indices [0,1,2,1,3,2] draw two triangles over four
        # uploaded vertices — the second triangle reuses v1 and selects
        # v3, so ignoring the index buffer cannot reproduce the coverage.
        col = (0.25, 0.5, 0.75, 1.0)
        pos = [(-1.0, -1.0), (-1.0, 1.0), (0.5, -1.0), (1.0, 0.0)]
        self.upload([(p, col) for p in pos])
        indices = [0, 1, 2, 1, 3, 2]
        self.upload_indices(indices, 0)
        self.indexed_prepared(0, len(indices))
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        clip = [(x, y, 0.5, 1.0) for x, y in pos]
        self.check_fb_coverage(self.indexed_coverage(clip, indices))

    def test_draw_indexed_uint32_selects_subset(self):
        # uint32 indices select a 3-vertex subset out of order — v1 is a
        # decoy that would change coverage if the index buffer were
        # ignored; indices [2,0,3] draw tri(v2,v0,v3) only.
        col = (0.25, 0.5, 0.75, 1.0)
        pos = [(-1.0, -1.0), (1.0, 1.0), (-1.0, 1.0), (1.0, -1.0)]
        self.upload([(p, col) for p in pos])
        indices = [2, 0, 3]
        self.upload_indices(indices, 1)
        self.indexed_prepared(1, len(indices))
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        clip = [(x, y, 0.5, 1.0) for x, y in pos]
        self.check_fb_coverage(self.indexed_coverage(clip, indices))

    def test_draw_indexed_vertex_offset_selects_shifted_vertices(self):
        # vertexOffset is added to every fetched index: indices [0,1,2]
        # with vertexOffset=1 resolve to vertex records 1,2,3 — tri
        # (v1,v2,v3), not (v0,v1,v2).  Coverage diverges if the offset is
        # dropped.
        col = (0.25, 0.5, 0.75, 1.0)
        pos = [(-1.0, -1.0), (1.0, 1.0), (-1.0, 1.0), (1.0, -1.0)]
        self.upload([(p, col) for p in pos])
        indices = [0, 1, 2]
        self.upload_indices(indices, 0)
        self.indexed_prepared(0, len(indices), vertex_offset=1)
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        clip = [(x, y, 0.5, 1.0) for x, y in pos]
        eff = [i + 1 for i in indices]
        self.check_fb_coverage(self.indexed_coverage(clip, eff))

    def test_draw_indexed_first_index_offsets_index_buffer(self):
        # firstIndex selects where in the index buffer the draw starts:
        # leading pad indices [9,9] are skipped so indices[2:5]=[0,2,3]
        # draw tri(v0,v2,v3).  Reading from index 0 would fault on the
        # out-of-range 9s, so coverage proves the offset is honored.
        col = (0.25, 0.5, 0.75, 1.0)
        pos = [(-1.0, -1.0), (1.0, 1.0), (-1.0, 1.0), (1.0, -1.0)]
        self.upload([(p, col) for p in pos])
        indices = [9, 9, 0, 2, 3]
        self.upload_indices(indices, 0)
        self.indexed_prepared(0, 3, first_index=2)
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        clip = [(x, y, 0.5, 1.0) for x, y in pos]
        self.check_fb_coverage(self.indexed_coverage(clip, [0, 2, 3]))

    def restart_coverage(self, clip, indices, sentinel, topo):
        # primitive-restart oracle: map each index slot to its vertex clip
        # position, marking sentinel values as stream breaks, then union
        # the per-run topology coverage via gfx_restart_coverage.
        vp, sc, cw, ch = ((0.0, 0.0, 8.0, 4.0, 0.0, 1.0),
                          (0, 0, 8, 4), 8, 4)
        stream = [None if i == sentinel else clip[i] for i in indices]
        return vn_golden.gfx_restart_coverage(
            stream, topo, vp, sc, cw, ch, True, 0)

    def upload_rate(self, offsets):
        # per-instance scalar float offsets -> binding1 (inputRate=1,
        # stride=4, fmt100=R32_SFLOAT): instance i reads the float at
        # VB2[i*4].
        data = b''.join(struct.pack('<f', o) for o in offsets)
        self.f.state.aperture.write(self.f.owner.base + self.VB2_OFF, data)

    def rate_prepared(self, vertex_count, instance_count, **draw_kw):
        # vs_rate_program adds the binding1 per-instance float (Location 2)
        # to Position.x.  Distinct VS3 handle: VS2 already owns vs_program.
        # Binds both vertex buffers: binding0=VB (rate0), binding1=VB2 (rate1).
        self.module(self.VS3, vs_rate_program())
        self.pipeline(rate1=True, vs=self.VS3)
        self.begin_pass()
        self.viewport()
        self.scissor()
        self.f.command('vkCmdBindPipeline', commandBuffer=self.f.CB,
                       pipelineBindPoint=0, pipeline=self.PIPE2)
        self.f.command('vkCmdBindVertexBuffers', commandBuffer=self.f.CB,
            firstBinding=0, bindingCount=2, pBuffers=[self.VB, self.VB2],
            pOffsets=[0, 0])
        self.draw(vertexCount=vertex_count, instanceCount=instance_count,
                  **draw_kw)
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.f.end()

    def test_rate1_attribute_offsets_each_instance(self):
        # inputRate=1 per-instance attribute: binding1 carries one float per
        # instance (Location 2, R32_SFLOAT) that vs_rate_program adds to
        # Position.x.  instanceCount=4 -> instances read VB2[0..3] =
        # [0,0.4,0.8,1.2] and land in four separated columns.  A vertex-rate
        # or rate-ignoring replay reads a single offset for every record and
        # cannot reproduce the spread; a vertex-index-addressed read would
        # distort each triangle differently.
        col = (0.25, 0.5, 0.75, 1.0)
        # same proven base as the InstanceIndex test: narrow triangle centred
        # near clip-x=-0.6; per-instance offsets [0,0.4,0.8,1.2] reproduce the
        # four columns -0.6,-0.2,+0.2,+0.6 (all inside the viewport).
        base = [(-0.75, -1.0), (-0.45, -1.0), (-0.6, 1.0)]
        self.upload([(p, col) for p in base])
        offsets = [0.0, 0.4, 0.8, 1.2]
        self.upload_rate(offsets)
        self.rate_prepared(3, 4)
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        vp, sc, cw, ch = ((0.0, 0.0, 8.0, 4.0, 0.0, 1.0),
                          (0, 0, 8, 4), 8, 4)
        cov = set()
        for off in offsets:
            cov |= vn_golden.gfx_tri_coverage(
                [(x + off, y, 0.5, 1.0) for (x, y) in base],
                vp, sc, cw, ch, True, 0)
        self.check_fb_coverage(cov)

    def test_rate1_attribute_first_instance_selects_offset(self):
        # firstInstance composes with rate-1 addressing: inst_index =
        # firstInstance + instance, so firstInstance=1 + instanceCount=2
        # reads VB2[1],VB2[2] = offsets[1],offsets[2] = 0.4,0.8 -> centres
        # -0.2,+0.2 (NOT 0.0,0.4).  Diverges if the base instance index is
        # dropped from the rate-1 fetch index.
        col = (0.25, 0.5, 0.75, 1.0)
        base = [(-0.75, -1.0), (-0.45, -1.0), (-0.6, 1.0)]
        self.upload([(p, col) for p in base])
        offsets = [0.0, 0.4, 0.8, 1.2]
        self.upload_rate(offsets)
        self.rate_prepared(3, 2, firstInstance=1)
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        vp, sc, cw, ch = ((0.0, 0.0, 8.0, 4.0, 0.0, 1.0),
                          (0, 0, 8, 4), 8, 4)
        cov = set()
        for off in (offsets[1], offsets[2]):
            cov |= vn_golden.gfx_tri_coverage(
                [(x + off, y, 0.5, 1.0) for (x, y) in base],
                vp, sc, cw, ch, True, 0)
        self.check_fb_coverage(cov)

    def rate_indexed_prepared(self, index_type, index_count, instance_count,
                              first_instance=0, **draw_kw):
        # vkCmdDrawIndexed + inputRate=1 attribute: the rate-1 fetch uses
        # inst_index (firstInstance+instance), independent of the index
        # buffer — each instance still reads its own VB2 offset while the
        # index stream selects/reorders the rate-0 vertices.
        self.module(self.VS3, vs_rate_program())
        self.pipeline(rate1=True, vs=self.VS3)
        self.begin_pass()
        self.viewport()
        self.scissor()
        self.f.command('vkCmdBindPipeline', commandBuffer=self.f.CB,
                       pipelineBindPoint=0, pipeline=self.PIPE2)
        self.f.command('vkCmdBindVertexBuffers', commandBuffer=self.f.CB,
            firstBinding=0, bindingCount=2, pBuffers=[self.VB, self.VB2],
            pOffsets=[0, 0])
        self.f.command('vkCmdBindIndexBuffer', commandBuffer=self.f.CB,
                       buffer=self.IB, offset=0, indexType=index_type)
        self.f.command('vkCmdDrawIndexed', commandBuffer=self.f.CB,
                       indexCount=index_count, instanceCount=instance_count,
                       firstIndex=0, vertexOffset=0,
                       firstInstance=first_instance)
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.f.end()

    def test_rate1_attribute_with_indexed_draw(self):
        # vkCmdDrawIndexed + inputRate=1: a u16 index stream reorders four
        # uploaded vertices into two triangles per instance while the
        # rate-1 attribute offsets each instance via VB2.  instanceCount=2
        # reads offsets[0],offsets[1]; a vertex-rate or index-confused read
        # cannot reproduce both the reorder and the per-instance spread.
        col = (0.25, 0.5, 0.75, 1.0)
        # four vertices forming two triangles when indexed [0,1,2, 1,3,2];
        # base geometry centred near clip-x=-0.6 like the rate-1 tests.
        pos = [(-0.75, -1.0), (-0.45, -1.0), (-0.6, 1.0), (-0.3, 0.2)]
        self.upload([(p, col) for p in pos])
        indices = [0, 1, 2, 1, 3, 2]
        self.upload_indices(indices, 0)
        offsets = [0.0, 0.4]
        self.upload_rate(offsets)
        self.rate_indexed_prepared(0, len(indices), 2)
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        vp, sc, cw, ch = ((0.0, 0.0, 8.0, 4.0, 0.0, 1.0),
                          (0, 0, 8, 4), 8, 4)
        cov = set()
        for off in offsets:
            clip = [(x + off, y, 0.5, 1.0) for (x, y) in pos]
            for t in range(0, len(indices), 3):
                cov |= vn_golden.gfx_tri_coverage(
                    [clip[indices[t + k]] for k in range(3)],
                    vp, sc, cw, ch, True, 0)
        self.check_fb_coverage(cov)

    XB_OFF = 1024
    VB2_OFF = 1088

    def upload_indirect(self, *args):
        # pack u32 draw arguments into the indirect buffer's memory span
        data = b''.join(struct.pack('<I', a) for a in args)
        self.f.state.aperture.write(self.f.owner.base + self.XB_OFF, data)

    def indirect_coverage(self, clip, vertex_indices):
        # expected coverage for an indirect draw that resolves to the
        # given vertex-index triple (firstVertex/indices already applied).
        vp, sc, cw, ch = ((0.0, 0.0, 8.0, 4.0, 0.0, 1.0),
                          (0, 0, 8, 4), 8, 4)
        return vn_golden.gfx_tri_coverage(
            [clip[i] for i in vertex_indices], vp, sc, cw, ch, True, 0)

    def test_draw_indirect_reads_args_from_buffer(self):
        # vkCmdDrawIndirect reads {vertexCount,instanceCount,firstVertex,
        # firstInstance} from the indirect buffer: vertexCount=3 with
        # firstVertex=1 draws verts[1],[2],[3] — a different triangle than
        # the firstVertex=0 default, so ignoring the args cannot match.
        col = (0.25, 0.5, 0.75, 1.0)
        pos = [(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)]
        self.upload([(p, col) for p in pos])
        self.upload_indirect(3, 1, 1, 0)   # vertexCount=3, firstVertex=1
        self.pipeline()
        self.begin_pass()
        self.viewport()
        self.scissor()
        self.bind()
        self.f.command('vkCmdDrawIndirect', commandBuffer=self.f.CB,
                       buffer=self.XB, offset=0, drawCount=1, stride=16)
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.f.end()
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        clip = [(x, y, 0.5, 1.0) for x, y in pos]
        self.check_fb_coverage(self.indirect_coverage(clip, [1, 2, 3]))

    def test_draw_indexed_indirect_reads_args_from_buffer(self):
        # vkCmdDrawIndexedIndirect reads {indexCount,instanceCount,
        # firstIndex,vertexOffset,firstInstance}: indexCount=3 with
        # vertexOffset=1 and indices [0,1,2] resolves to vertex records
        # 1,2,3 — proving both the indirect args and the index buffer are
        # honored through the indirect path.
        col = (0.25, 0.5, 0.75, 1.0)
        pos = [(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)]
        self.upload([(p, col) for p in pos])
        self.upload_indices([0, 1, 2], 0)
        # indexCount=3, instanceCount=1, firstIndex=0, vertexOffset=1,
        # firstInstance=0 — the 20-byte DrawIndexedIndirectCommand.
        self.upload_indirect(3, 1, 0, 1, 0)
        self.pipeline(topology=3)
        self.begin_pass()
        self.viewport()
        self.scissor()
        self.bind()
        self.f.command('vkCmdBindIndexBuffer', commandBuffer=self.f.CB,
                       buffer=self.IB, offset=0, indexType=0)
        self.f.command('vkCmdDrawIndexedIndirect', commandBuffer=self.f.CB,
                       buffer=self.XB, offset=0, drawCount=1, stride=20)
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.f.end()
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        clip = [(x, y, 0.5, 1.0) for x, y in pos]
        # indices [0,1,2] + vertexOffset 1 -> vertex records 1,2,3
        self.check_fb_coverage(self.indirect_coverage(clip, [1, 2, 3]))

    def test_draw_indexed_primitive_restart_splits_triangles(self):
        # primitiveRestartEnable + uint16 indices [0,1,2,0xFFFF,3,4,5]:
        # the sentinel breaks the stream into two independent triangles.
        # indexCount=7 is not a multiple of 3, so only break-aware assembly
        # admits the draw — a restart-ignoring replay faults or misdraws.
        col = (0.25, 0.5, 0.75, 1.0)
        pos = [(-1.0, -1.0), (-1.0, 1.0), (0.0, -1.0),
               (0.0, 1.0), (1.0, -1.0), (1.0, 1.0)]
        self.upload([(p, col) for p in pos])
        indices = [0, 1, 2, 0xFFFF, 3, 4, 5]
        self.upload_indices(indices, 0)
        self.indexed_prepared(0, len(indices), topology=3, restart=1)
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        clip = [(x, y, 0.5, 1.0) for x, y in pos]
        self.check_fb_coverage(
            self.restart_coverage(clip, indices, 0xFFFF, 3))

    def test_draw_indexed_primitive_restart_strip_resets_window(self):
        # TRIANGLE_STRIP [v0,v1,v2] SENT [v3,v4,v5]: the break resets the
        # sliding window so each three-vertex run emits one triangle —
        # concatenating the runs would emit four cross-break triangles.
        col = (0.25, 0.5, 0.75, 1.0)
        pos = [(-1.0, -1.0), (-1.0, 1.0), (0.0, -1.0),
               (0.0, 1.0), (1.0, -1.0), (1.0, 1.0)]
        self.upload([(p, col) for p in pos])
        indices = [0, 1, 2, 0xFFFF, 3, 4, 5]
        self.upload_indices(indices, 0)
        self.indexed_prepared(0, len(indices), topology=4, restart=1)
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        clip = [(x, y, 0.5, 1.0) for x, y in pos]
        self.check_fb_coverage(
            self.restart_coverage(clip, indices, 0xFFFF, 4))

    # ---- bounded MRT (two colour attachments) end-to-end ----
    # fs_program2 emits loc0=vcol, loc1=const; the single Writeback stage
    # writes both attachments per fragment under one shared depth gate.
    # att1 image memory offset: 4352 sits in the 256-byte slot right after
    # att0's 4096..4352 span (the 5001-byte MEMORY has no room past ~4745).
    MRT_IMAGE, MRT_VIEW, MRT_OFF = (0x7D0000001000,
                                  0x7D0000001001, 4352)

    def read_mrt_texel(self, x, y):
        return self.f.state.aperture.read(
            self.f.owner.base + self.MRT_OFF + y * 64 + x * 4, 4)

    def mrt_texel(self, *floats):
        did = self.e.golden.img_fmt_id(self.e.model, 37)
        return self.e.golden.img_clear_texel(
            self.e.model, did,
            struct.unpack('<4I', struct.pack('<4f', *floats)))

    def test_mrt_two_attachments_write_both_targets(self):
        # two colour attachments: att0 = base VIEW (offset 4096),
        # att1 = MRT_VIEW (offset MRT_OFF).  Both fmt37 UNORM8 RGBA.
        self.g.r.image(handle=self.MRT_IMAGE, offset=self.MRT_OFF)
        self.g.r.view(handle=self.MRT_VIEW, image=self.MRT_IMAGE)
        self.g.r.render_pass(handle=self.g.r.RP2, count=2)
        self.g.r.framebuffer(handle=self.g.r.FB2, render_pass=self.g.r.RP2,
                             views=[self.g.r.VIEW, self.MRT_VIEW])
        self.f.command('vkDestroyShaderModule', device=self.w.DEVICE,
                       shaderModule=self.FS2)
        self.module(self.FS2, fs_program2())
        self.pipeline(rp=self.g.r.RP2, attachments=[{}, {}])
        self.begin_pass(rp=self.g.r.RP2, fb=self.g.r.FB2,
                        clears=[[0, 0, 0, 0x3F800000],
                                [0, 0x3F800000, 0, 0x3F800000]])
        self.viewport()
        self.scissor()
        self.bind()
        self.upload(self.ndc_triangle())
        self.draw()
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.f.end()
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        self.assertGreater(job.drawexec_stats[job.operation - 1]['records'], 0)
        c0 = self.mrt_texel(0.5, 0.25, 0.75, 1.0)    # fs_program2 loc0
        c1 = self.mrt_texel(1.0, 0.0, 1.0, 1.0)      # fs_program2 loc1
        clear0 = self.mrt_texel(0.0, 0.0, 0.0, 1.0)
        clear1 = self.mrt_texel(0.0, 1.0, 0.0, 1.0)
        for x, y in ((0, 0), (1, 1), (2, 0), (0, 2), (4, 1)):
            self.assertEqual(self.read_texel(x, y), c0, 'att0 (%d,%d)' % (x, y))
            self.assertEqual(self.read_mrt_texel(x, y), c1,
                             'att1 (%d,%d)' % (x, y))
        # uncovered corner keeps each attachment's own clear on both targets
        self.assertEqual(self.read_texel(7, 3), clear0)
        self.assertEqual(self.read_mrt_texel(7, 3), clear1)
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_mrt_per_attachment_blend(self):
        # is_mrtblend: att0 blendEnable=0 writes loc0 plainly; att1
        # blendEnable=1 with ONE/ONE ADD blends loc1 against att1's OWN
        # clear dst.  att1 clear (0.5,0.5,0.5,0.5) -> dst u8 ~128; src loc1
        # = (1,0,1,1).  Per channel res = src+dst clamped: R=1+~0.5->255,
        # G=0+~0.5->~128 (proves dst contributed — plain write gives 0),
        # B=1+~0.5->255, A via ONE/ZERO alpha factors -> 255.
        self.g.r.image(handle=self.MRT_IMAGE, offset=self.MRT_OFF)
        self.g.r.view(handle=self.MRT_VIEW, image=self.MRT_IMAGE)
        self.g.r.render_pass(handle=self.g.r.RP2, count=2)
        self.g.r.framebuffer(handle=self.g.r.FB2, render_pass=self.g.r.RP2,
                             views=[self.g.r.VIEW, self.MRT_VIEW])
        self.f.command('vkDestroyShaderModule', device=self.w.DEVICE,
                       shaderModule=self.FS2)
        self.module(self.FS2, fs_program2())
        # att0 no blend; att1 ONE/ONE ADD on colour, ONE/ZERO on alpha.
        self.pipeline(rp=self.g.r.RP2, attachments=[
            {},
            dict(blendEnable=1, srcColorBlendFactor=1,
                 dstColorBlendFactor=1, colorBlendOp=0,
                 srcAlphaBlendFactor=1, dstAlphaBlendFactor=0,
                 alphaBlendOp=0, colorWriteMask=15)])
        self.begin_pass(rp=self.g.r.RP2, fb=self.g.r.FB2,
                        clears=[[0, 0, 0, 0x3F800000],
                                [0x3F000000, 0x3F000000, 0x3F000000,
                                 0x3F000000]])
        self.viewport()
        self.scissor()
        self.bind()
        self.upload(self.ndc_triangle())
        self.draw()
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.f.end()
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        # att0 unblended: plain loc0 constant write
        for x, y in ((0, 0), (4, 1)):
            self.assertEqual(self.read_texel(x, y),
                             self.mrt_texel(0.5, 0.25, 0.75, 1.0))
            b = self.read_mrt_texel(x, y)
            # att1 blended: G byte ~128 (dst contributed), R/B saturate 255
            self.assertEqual(b[0], 255)
            self.assertGreater(b[1], 0)      # G != plain-write 0
            self.assertEqual(b[2], 255)
            self.assertEqual(b[3], 255)
        # uncovered keeps each attachment's own clear
        self.assertEqual(self.read_texel(7, 3), self.clear_texel())
        self.assertEqual(self.read_mrt_texel(7, 3),
                         self.mrt_texel(0.5, 0.5, 0.5, 0.5))
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_mrt_logicop_applies_per_attachment(self):
        # is_mrtlop: pipeline-global logicOp XOR applies to EVERY colour
        # attachment, each against its OWN stored dst.  att0 src=loc0
        # (0.5,0.25,0.75,1)->u8[128,64,191,255] ^ clear[0,0,0,255];
        # att1 src=loc1 (1,0,1,1)->u8[255,0,255,255] ^ clear[0,255,0,255].
        self.g.r.image(handle=self.MRT_IMAGE, offset=self.MRT_OFF)
        self.g.r.view(handle=self.MRT_VIEW, image=self.MRT_IMAGE)
        self.g.r.render_pass(handle=self.g.r.RP2, count=2)
        self.g.r.framebuffer(handle=self.g.r.FB2, render_pass=self.g.r.RP2,
                             views=[self.g.r.VIEW, self.MRT_VIEW])
        self.f.command('vkDestroyShaderModule', device=self.w.DEVICE,
                       shaderModule=self.FS2)
        self.module(self.FS2, fs_program2())
        self.pipeline(rp=self.g.r.RP2, attachments=[{}, {}], logic_op=6)
        self.begin_pass(rp=self.g.r.RP2, fb=self.g.r.FB2,
                        clears=[[0, 0, 0, 0x3F800000],
                                [0, 0x3F800000, 0, 0x3F800000]])
        self.viewport()
        self.scissor()
        self.bind()
        self.upload(self.ndc_triangle())
        self.draw()
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.f.end()
        job = self.f.enqueue()
        self.assertIsNotNone(job)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        # att0: [128,64,191,255] ^ [0,0,0,255] = [128,64,191,0]
        # att1: [255,0,255,255] ^ [0,255,0,255] = [255,255,255,0]
        e0 = bytes([128, 64, 191, 0])
        e1 = bytes([255, 255, 255, 0])
        for x, y in ((0, 0), (4, 1)):
            self.assertEqual(self.read_texel(x, y), e0, 'att0 (%d,%d)' % (x, y))
            self.assertEqual(self.read_mrt_texel(x, y), e1,
                             'att1 (%d,%d)' % (x, y))
        self.assertEqual(self.read_texel(7, 3), self.clear_texel())
        self.assertEqual(self.read_mrt_texel(7, 3),
                         self.mrt_texel(0.0, 1.0, 0.0, 1.0))
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_fragment_ubo_descriptor_reaches_framebuffer(self):
        # end-to-end: vkCmdBindDescriptorSets -> vkCmdDraw -> DrawExec ->
        # FragmentShade reads the bound UBO and broadcasts it to color.
        ubo = 0.5
        # descriptor set layout: set0/binding0 UNIFORM_BUFFER, fragment stage
        self.r.layout(((0, 6, 1, 16),))
        self.f.command('vkDestroyShaderModule', device=self.w.DEVICE,
                       shaderModule=self.FS2)
        self.module(self.FS2, fs_program('color', ubo=True))
        # uniform buffer with UNIFORM_BUFFER usage at MEMORY offset 2048
        self.f.command('vkCreateBuffer', device=self.w.DEVICE, pBuffer=self.UBO,
            pCreateInfo=self.w.structure('VkBufferCreateInfo', pNext=[], flags=0,
                size=256, usage=0x10, sharingMode=0, queueFamilyIndexCount=0,
                pQueueFamilyIndices=[]))
        self.f.command('vkBindBufferMemory', device=self.w.DEVICE, buffer=self.UBO,
                       memory=self.w.MEMORY, memoryOffset=2048)
        self.f.command('vkCreateDescriptorPool', device=self.w.DEVICE,
            pDescriptorPool=self.POOL,
            pCreateInfo=self.w.structure('VkDescriptorPoolCreateInfo', pNext=[],
                flags=1, maxSets=1, poolSizeCount=1, pPoolSizes=[
                    self.w.structure('VkDescriptorPoolSize', type=6,
                                     descriptorCount=1)]))
        self.f.command('vkAllocateDescriptorSets', device=self.w.DEVICE,
            pDescriptorSets=[self.DSET], pAllocateInfo=self.w.structure(
                'VkDescriptorSetAllocateInfo', pNext=[],
                descriptorPool=self.POOL, descriptorSetCount=1,
                pSetLayouts=[self.r.DSL]))
        self.f.command('vkUpdateDescriptorSets', device=self.w.DEVICE,
            descriptorWriteCount=1, descriptorCopyCount=0, pDescriptorCopies=[],
            pDescriptorWrites=[self.w.structure('VkWriteDescriptorSet', pNext=[],
                dstSet=self.DSET, dstBinding=0, dstArrayElement=0,
                descriptorCount=1, descriptorType=6, pTexelBufferView=[],
                pImageInfo=[], pBufferInfo=[self.w.structure(
                    'VkDescriptorBufferInfo', buffer=self.UBO, offset=0,
                    range=4)])])
        self.upload(self.ndc_triangle())
        self.f.state.aperture.write(self.f.owner.base + 2048,
                                    struct.pack('<f', ubo))
        self.pipeline()
        self.begin_pass()
        self.viewport()
        self.scissor()
        self.bind()
        self.f.command('vkCmdBindDescriptorSets', commandBuffer=self.f.CB,
            pipelineBindPoint=0, layout=self.g.PL, firstSet=0,
            descriptorSetCount=1, pDescriptorSets=[self.DSET],
            dynamicOffsetCount=0, pDynamicOffsets=[])
        self.draw()
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.f.end()
        job = self.f.enqueue()
        self.f.drain()
        self.assertEqual(job.state, 'done')
        did = self.e.golden.img_fmt_id(self.e.model, 37)
        want = self.e.golden.img_clear_texel(
            self.e.model, did,
            struct.unpack('<4I', struct.pack('<4f', ubo, ubo, ubo, ubo)))
        for x, y in ((0, 0), (1, 1), (2, 0), (0, 2), (4, 1)):
            self.assertEqual(self.read_texel(x, y), want)
        self.assertEqual(self.read_texel(7, 3), self.clear_texel())
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_fragment_dynamic_ubo_offset_draw(self):
        # end-to-end dynamic offset: a UNIFORM_BUFFER_DYNAMIC (type 8)
        # descriptor bound with pDynamicOffsets=[256] shifts the shader's
        # UBO read base by 256 bytes (minUniformBufferOffsetAlignment), so
        # it loads the float at buffer+256 (0.75) rather than buffer+0
        # (0.25).  The dynamic path bakes binding_offset + descriptor.offset
        # + dynamic_offset into the ShaderBinding base at resolve time.
        self.r.layout(((0, 8, 1, 16),))
        self.f.command('vkDestroyShaderModule', device=self.w.DEVICE,
                       shaderModule=self.FS2)
        self.module(self.FS2, fs_program('color', ubo=True))
        self.f.command('vkCreateBuffer', device=self.w.DEVICE, pBuffer=self.UBO,
            pCreateInfo=self.w.structure('VkBufferCreateInfo', pNext=[], flags=0,
                size=512, usage=0x10, sharingMode=0, queueFamilyIndexCount=0,
                pQueueFamilyIndices=[]))
        self.f.command('vkBindBufferMemory', device=self.w.DEVICE, buffer=self.UBO,
                       memory=self.w.MEMORY, memoryOffset=2048)
        self.f.command('vkCreateDescriptorPool', device=self.w.DEVICE,
            pDescriptorPool=self.POOL,
            pCreateInfo=self.w.structure('VkDescriptorPoolCreateInfo', pNext=[],
                flags=1, maxSets=1, poolSizeCount=1, pPoolSizes=[
                    self.w.structure('VkDescriptorPoolSize', type=8,
                                     descriptorCount=1)]))
        self.f.command('vkAllocateDescriptorSets', device=self.w.DEVICE,
            pDescriptorSets=[self.DSET], pAllocateInfo=self.w.structure(
                'VkDescriptorSetAllocateInfo', pNext=[],
                descriptorPool=self.POOL, descriptorSetCount=1,
                pSetLayouts=[self.r.DSL]))
        self.f.command('vkUpdateDescriptorSets', device=self.w.DEVICE,
            descriptorWriteCount=1, descriptorCopyCount=0, pDescriptorCopies=[],
            pDescriptorWrites=[self.w.structure('VkWriteDescriptorSet', pNext=[],
                dstSet=self.DSET, dstBinding=0, dstArrayElement=0,
                descriptorCount=1, descriptorType=8, pTexelBufferView=[],
                pImageInfo=[], pBufferInfo=[self.w.structure(
                    'VkDescriptorBufferInfo', buffer=self.UBO, offset=0,
                    range=4)])])
        self.upload(self.ndc_triangle())
        # decoy at the un-offset base (2048) and the dynamic target at +256
        self.f.state.aperture.write(self.f.owner.base + 2048,
                                    struct.pack('<f', 0.25))
        self.f.state.aperture.write(self.f.owner.base + 2048 + 256,
                                    struct.pack('<f', 0.75))
        self.pipeline()
        self.begin_pass()
        self.viewport()
        self.scissor()
        self.bind()
        self.f.command('vkCmdBindDescriptorSets', commandBuffer=self.f.CB,
            pipelineBindPoint=0, layout=self.g.PL, firstSet=0,
            descriptorSetCount=1, pDescriptorSets=[self.DSET],
            dynamicOffsetCount=1, pDynamicOffsets=[256])
        self.draw()
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.f.end()
        job = self.f.enqueue()
        self.f.drain()
        self.assertEqual(job.state, 'done')
        did = self.e.golden.img_fmt_id(self.e.model, 37)
        want = self.e.golden.img_clear_texel(
            self.e.model, did,
            struct.unpack('<4I', struct.pack('<4f', 0.75, 0.75, 0.75, 0.75)))
        for x, y in ((0, 0), (1, 1), (2, 0), (0, 2), (4, 1)):
            self.assertEqual(self.read_texel(x, y), want)
        self.assertEqual(self.read_texel(7, 3), self.clear_texel())
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_fragment_flat_varying_uses_provoking_vertex(self):
        # FS vcol input decorated Flat: the raster stage copies the
        # provoking (first) vertex's varying verbatim instead of
        # perspective-correct interpolation, so every covered fragment
        # carries v0's color.rgb and v0's VertexIndex alpha (0.0) rather
        # than the smooth three-vertex blend.
        self.f.command('vkDestroyShaderModule', device=self.w.DEVICE,
                       shaderModule=self.FS2)
        self.module(self.FS2, fs_program('color', flat=True))
        self.upload(self.color_triangle())
        self.prepared()
        job = self.f.enqueue()
        self.f.drain()
        self.assertEqual(job.state, 'done')
        did = self.e.golden.img_fmt_id(self.e.model, 37)
        want = self.e.golden.img_clear_texel(
            self.e.model, did,
            struct.unpack('<4I', struct.pack('<4f', 1.0, 0.0, 0.0, 0.0)))
        for x, y in ((1, 1), (4, 1), (2, 0)):
            self.assertEqual(self.read_texel(x, y), want)
        self.assertEqual(self.read_texel(7, 3), self.clear_texel())
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_fragment_sampled_image_fetch_reaches_framebuffer(self):
        # end-to-end: vkCmdBindDescriptorSets -> vkCmdDraw -> DrawExec ->
        # FragmentShade fetches a SAMPLED_IMAGE (UNIFORMCONST, kind 2)
        # texel and writes it to color.  Texels are laid out as
        # (x*32, y*64, (x+y)*16, 255) so the fetched coordinate is
        # identifiable in the framebuffer.
        cx, cy = 3, 2
        self.r.layout(((0, 2, 1, 16),))
        self.f.command('vkDestroyShaderModule', device=self.w.DEVICE,
                       shaderModule=self.FS2)
        self.module(self.FS2, fs_image_program(binding=0, coord=(cx, cy)))
        s = self.w.structure
        self.f.command('vkCreateImage', device=self.w.DEVICE, pImage=self.IMAGE,
            pCreateInfo=s('VkImageCreateInfo', pNext=[], flags=0, imageType=1,
                format=37, extent=s('VkExtent3D', width=8, height=4, depth=1),
                mipLevels=1, arrayLayers=1, samples=1, tiling=0, usage=15,
                sharingMode=0, queueFamilyIndexCount=0, pQueueFamilyIndices=[],
                initialLayout=1))
        self.f.command('vkBindImageMemory', device=self.w.DEVICE, image=self.IMAGE,
                       memory=self.w.MEMORY, memoryOffset=4352)
        self.f.command('vkCreateImageView', device=self.w.DEVICE, pView=self.VIEW,
            pCreateInfo=s('VkImageViewCreateInfo', pNext=[], flags=0,
                image=self.IMAGE, viewType=1, format=37,
                components=s('VkComponentMapping', r=0, g=0, b=0, a=0),
                subresourceRange=s('VkImageSubresourceRange', aspectMask=1,
                    baseMipLevel=0, levelCount=1, baseArrayLayer=0, layerCount=1)))
        self.f.command('vkCreateDescriptorPool', device=self.w.DEVICE,
            pDescriptorPool=self.POOL,
            pCreateInfo=s('VkDescriptorPoolCreateInfo', pNext=[], flags=1,
                maxSets=1, poolSizeCount=1,
                pPoolSizes=[s('VkDescriptorPoolSize', type=2,
                              descriptorCount=1)]))
        self.f.command('vkAllocateDescriptorSets', device=self.w.DEVICE,
            pDescriptorSets=[self.DSET], pAllocateInfo=s(
                'VkDescriptorSetAllocateInfo', pNext=[], descriptorPool=self.POOL,
                descriptorSetCount=1, pSetLayouts=[self.r.DSL]))
        self.f.command('vkUpdateDescriptorSets', device=self.w.DEVICE,
            descriptorWriteCount=1, descriptorCopyCount=0, pDescriptorCopies=[],
            pDescriptorWrites=[s('VkWriteDescriptorSet', pNext=[], dstSet=self.DSET,
                dstBinding=0, dstArrayElement=0, descriptorCount=1,
                descriptorType=2, pTexelBufferView=[],
                pImageInfo=[s('VkDescriptorImageInfo', sampler=0,
                    imageView=self.VIEW, imageLayout=1)], pBufferInfo=[])])
        # R8G8B8A8_UNORM texels: pitch = (8*4+63)&~63 = 64 bytes/row.
        did = self.e.golden.img_fmt_id(self.e.model, 37)
        pitch = self.e.golden.img_mpitch(self.e.model, 8, did, 0)
        base = self.f.owner.base + 4352
        for y in range(4):
            for x in range(8):
                texel = bytes((x * 32, y * 64, (x + y) * 16, 255))
                self.f.state.aperture.write(
                    base + y * pitch + x * 4, texel)
        self.upload(self.ndc_triangle())
        self.pipeline()
        self.begin_pass()
        self.viewport()
        self.scissor()
        self.bind()
        self.f.command('vkCmdBindDescriptorSets', commandBuffer=self.f.CB,
            pipelineBindPoint=0, layout=self.g.PL, firstSet=0,
            descriptorSetCount=1, pDescriptorSets=[self.DSET],
            dynamicOffsetCount=0, pDynamicOffsets=[])
        self.draw()
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.f.end()
        job = self.f.enqueue()
        self.f.drain()
        self.assertEqual(job.state, 'done')
        tx, ty = cx * 32, cy * 64
        tb = (cx + cy) * 16
        want = self.e.golden.img_clear_texel(
            self.e.model, did,
            struct.unpack('<4I', struct.pack('<4f',
                tx / 255.0, ty / 255.0, tb / 255.0, 1.0)))
        for x, y in ((0, 0), (1, 1), (2, 0), (0, 2), (4, 1)):
            self.assertEqual(self.read_texel(x, y), want)
        self.assertEqual(self.read_texel(7, 3), self.clear_texel())
        self.assertEqual(self.f.owner.work_refs, 0)

    def _image_fetch_setup(self, module, dtype=2, sampler_addr=0,
                           linear=False, border_color=0, mips=1,
                           max_lod=0.0, mip_linear=False,
                           mip_color=(0, 255, 0, 255)):
        """Shared vkCreateImage/View + image-descriptor-set setup for the
        image draw tests.  The image is an 8x4 R8G8B8A8_UNORM at MEMORY
        offset 4352 with texel(x,y) = (x*32, y*64, (x+y)*16, 255);
        `dtype` selects SAMPLED_IMAGE(2)/STORAGE_IMAGE(3)/
        COMBINED_IMAGE_SAMPLER(1); the combined form also creates a
        VkSampler bound into VkDescriptorImageInfo.  `sampler_addr` sets
        VkSamplerAddressMode for U/V/W (0 Repeat, 1 MirroredRepeat, 2
        ClampToEdge, 3 ClampToBorder); `linear` selects LINEAR (1) over
        NEAREST (0) min/mag filters; `border_color` sets VkBorderColor
        (4 FLOAT_OPAQUE_WHITE) for CLAMP_TO_BORDER substitution; `mips`
        sets VkImageCreateInfo.mipLevels and the view levelCount - mip0
        keeps the (x,y) texel pattern while mips>=1 are filled solid
        green (0,255,0,255) so an explicit-LOD sample proves mip select;
        `max_lod` sets VkSamplerCreateInfo.maxLod (must cover the mip
        count or the model clamps LOD to mip0); `mip_linear` selects
        VkSamplerMipmapMode.LINEAR (trilinear) over NEAREST; `mip_color`
        is the RGBA tuple filled into every mip>=1."""
        self.r.layout(((0, dtype, 1, 16),))
        if dtype in (0, 1):
            filt = 1 if linear else 0
            self.f.command('vkCreateSampler', device=self.w.DEVICE,
                pSampler=self.SAMPLER,
                pCreateInfo=self.w.structure('VkSamplerCreateInfo', pNext=[],
                    flags=0, magFilter=filt, minFilter=filt,
                    mipmapMode=1 if mip_linear else 0,
                    addressModeU=sampler_addr, addressModeV=sampler_addr,
                    addressModeW=sampler_addr,
                    mipLodBias=0, anisotropyEnable=0, maxAnisotropy=0,
                    compareEnable=0, compareOp=7, minLod=0,
                    maxLod=struct.unpack('<I', struct.pack('<f', max_lod))[0],
                    borderColor=border_color, unnormalizedCoordinates=0))
        self.f.command('vkDestroyShaderModule', device=self.w.DEVICE,
                       shaderModule=self.FS2)
        self.module(self.FS2, module)
        s = self.w.structure
        self.f.command('vkCreateImage', device=self.w.DEVICE, pImage=self.IMAGE,
            pCreateInfo=s('VkImageCreateInfo', pNext=[], flags=0, imageType=1,
                format=37, extent=s('VkExtent3D', width=8, height=4, depth=1),
                mipLevels=mips, arrayLayers=1, samples=1, tiling=0, usage=15,
                sharingMode=0, queueFamilyIndexCount=0, pQueueFamilyIndices=[],
                initialLayout=1))
        self.f.command('vkBindImageMemory', device=self.w.DEVICE, image=self.IMAGE,
                       memory=self.w.MEMORY, memoryOffset=4352)
        self.f.command('vkCreateImageView', device=self.w.DEVICE, pView=self.VIEW,
            pCreateInfo=s('VkImageViewCreateInfo', pNext=[], flags=0,
                image=self.IMAGE, viewType=1, format=37,
                components=s('VkComponentMapping', r=0, g=0, b=0, a=0),
                subresourceRange=s('VkImageSubresourceRange', aspectMask=1,
                    baseMipLevel=0, levelCount=mips, baseArrayLayer=0,
                    layerCount=1)))
        self.f.command('vkCreateDescriptorPool', device=self.w.DEVICE,
            pDescriptorPool=self.POOL,
            pCreateInfo=s('VkDescriptorPoolCreateInfo', pNext=[], flags=1,
                maxSets=1, poolSizeCount=1,
                pPoolSizes=[s('VkDescriptorPoolSize', type=dtype,
                              descriptorCount=1)]))
        self.f.command('vkAllocateDescriptorSets', device=self.w.DEVICE,
            pDescriptorSets=[self.DSET], pAllocateInfo=s(
                'VkDescriptorSetAllocateInfo', pNext=[], descriptorPool=self.POOL,
                descriptorSetCount=1, pSetLayouts=[self.r.DSL]))
        self.f.command('vkUpdateDescriptorSets', device=self.w.DEVICE,
            descriptorWriteCount=1, descriptorCopyCount=0, pDescriptorCopies=[],
            pDescriptorWrites=[s('VkWriteDescriptorSet', pNext=[], dstSet=self.DSET,
                dstBinding=0, dstArrayElement=0, descriptorCount=1,
                descriptorType=dtype, pTexelBufferView=[],
                pImageInfo=[s('VkDescriptorImageInfo',
                    sampler=self.SAMPLER if dtype in (0, 1) else 0,
                    imageView=0 if dtype == 0 else self.VIEW,
                    imageLayout=1)], pBufferInfo=[])])
        did = self.e.golden.img_fmt_id(self.e.model, 37)
        base = self.f.owner.base + 4352
        for m in range(mips):
            wm = self.e.golden.img_mdim(8, m)
            hm = self.e.golden.img_mdim(4, m)
            pitch = self.e.golden.img_mpitch(self.e.model, 8, did, m)
            moff = self.e.golden.img_mip_off(self.e.model, 8, 4, did, m)
            for y in range(hm):
                for x in range(wm):
                    if m == 0:
                        texel = bytes((x * 32, y * 64, (x + y) * 16, 255))
                    else:
                        texel = bytes(mip_color)
                    self.f.state.aperture.write(
                        base + moff + y * pitch + x * 4, texel)
        return did

    def _dref_setup(self, module, depth=0.25, mip_depth=None, mips=1,
                    compare_op=3, max_lod=0.0, depth_fn=None, linear=False):
        """Depth-reference (dref) variant of _image_fetch_setup: an 8x4
        D16_UNORM depth image (VkFormat 124 -> device fmt 13) at MEMORY
        offset 4352, a COMBINED_IMAGE_SAMPLER(1) descriptor, and a
        nearest VkSampler with compareEnable=1 and compareOp=compare_op
        (3=LESS_OR_EQUAL); `linear=True` switches mag/min to LINEAR so a
        dref sample runs PCF (per-texel compare, then bilinear weighting).  mip0 texels carry UNORM16 `depth`; every
        mip>=1 carries `mip_depth` (default `depth`) so an explicit-LOD
        dref sample can prove mip select.  `mips` sets mipLevels/levelCount
        and `max_lod` must cover the mip count or the model clamps LOD to
        mip0.  `depth_fn(x,y,m)` overrides the uniform depth per texel
        (used by dref-gather to give the 2x2 footprint mixed compare
        results).  The depth view uses aspectMask=2 (DEPTH); texels are
        2-byte u16, pitch = img_mpitch(model,8,13,m)."""
        self.r.layout(((0, 1, 1, 16),))
        self.f.command('vkCreateSampler', device=self.w.DEVICE,
            pSampler=self.SAMPLER,
            pCreateInfo=self.w.structure('VkSamplerCreateInfo', pNext=[],
                flags=0, magFilter=1 if linear else 0,
                minFilter=1 if linear else 0, mipmapMode=0,
                addressModeU=0, addressModeV=0, addressModeW=0,
                mipLodBias=0, anisotropyEnable=0, maxAnisotropy=0,
                compareEnable=1, compareOp=compare_op, minLod=0,
                maxLod=struct.unpack('<I', struct.pack('<f', max_lod))[0],
                borderColor=0, unnormalizedCoordinates=0))
        self.f.command('vkDestroyShaderModule', device=self.w.DEVICE,
                       shaderModule=self.FS2)
        self.module(self.FS2, module)
        s = self.w.structure
        self.f.command('vkCreateImage', device=self.w.DEVICE, pImage=self.IMAGE,
            pCreateInfo=s('VkImageCreateInfo', pNext=[], flags=0, imageType=1,
                format=124, extent=s('VkExtent3D', width=8, height=4, depth=1),
                mipLevels=mips, arrayLayers=1, samples=1, tiling=0, usage=15,
                sharingMode=0, queueFamilyIndexCount=0, pQueueFamilyIndices=[],
                initialLayout=1))
        self.f.command('vkBindImageMemory', device=self.w.DEVICE, image=self.IMAGE,
                       memory=self.w.MEMORY, memoryOffset=4352)
        self.f.command('vkCreateImageView', device=self.w.DEVICE, pView=self.VIEW,
            pCreateInfo=s('VkImageViewCreateInfo', pNext=[], flags=0,
                image=self.IMAGE, viewType=1, format=124,
                components=s('VkComponentMapping', r=0, g=0, b=0, a=0),
                subresourceRange=s('VkImageSubresourceRange', aspectMask=2,
                    baseMipLevel=0, levelCount=mips, baseArrayLayer=0,
                    layerCount=1)))
        self.f.command('vkCreateDescriptorPool', device=self.w.DEVICE,
            pDescriptorPool=self.POOL,
            pCreateInfo=s('VkDescriptorPoolCreateInfo', pNext=[], flags=1,
                maxSets=1, poolSizeCount=1,
                pPoolSizes=[s('VkDescriptorPoolSize', type=1,
                              descriptorCount=1)]))
        self.f.command('vkAllocateDescriptorSets', device=self.w.DEVICE,
            pDescriptorSets=[self.DSET], pAllocateInfo=s(
                'VkDescriptorSetAllocateInfo', pNext=[], descriptorPool=self.POOL,
                descriptorSetCount=1, pSetLayouts=[self.r.DSL]))
        self.f.command('vkUpdateDescriptorSets', device=self.w.DEVICE,
            descriptorWriteCount=1, descriptorCopyCount=0, pDescriptorCopies=[],
            pDescriptorWrites=[s('VkWriteDescriptorSet', pNext=[], dstSet=self.DSET,
                dstBinding=0, dstArrayElement=0, descriptorCount=1,
                descriptorType=1, pTexelBufferView=[],
                pImageInfo=[s('VkDescriptorImageInfo',
                    sampler=self.SAMPLER, imageView=self.VIEW,
                    imageLayout=1)], pBufferInfo=[])])
        did = self.e.golden.img_fmt_id(self.e.model, 124)
        base = self.f.owner.base + 4352
        for m in range(mips):
            wm = self.e.golden.img_mdim(8, m)
            hm = self.e.golden.img_mdim(4, m)
            pitch = self.e.golden.img_mpitch(self.e.model, 8, did, m)
            moff = self.e.golden.img_mip_off(self.e.model, 8, 4, did, m)
            d = depth if m == 0 else (depth if mip_depth is None else mip_depth)
            for y in range(hm):
                for x in range(wm):
                    dv = d if depth_fn is None else depth_fn(x, y, m)
                    d16 = struct.pack('<H', int(round(dv * 65535)))
                    self.f.state.aperture.write(
                        base + moff + y * pitch + x * 2, d16)
        return did

    def _separate_sampler_setup(self, module):
        """Separate SAMPLED_IMAGE(binding0, kind2) + SAMPLER(binding1, kind0)
        descriptor pair for the OpSampledImage merge path, plus the same
        8x4 R8G8B8A8_UNORM image and texel pattern as _image_fetch_setup."""
        self.r.layout(((0, 2, 1, 16), (1, 0, 1, 16)))
        self.f.command('vkCreateSampler', device=self.w.DEVICE,
            pSampler=self.SAMPLER,
            pCreateInfo=self.w.structure('VkSamplerCreateInfo', pNext=[],
                flags=0, magFilter=0, minFilter=0, mipmapMode=0,
                addressModeU=0, addressModeV=0, addressModeW=0,
                mipLodBias=0, anisotropyEnable=0, maxAnisotropy=0,
                compareEnable=0, compareOp=7, minLod=0, maxLod=0,
                borderColor=0, unnormalizedCoordinates=0))
        self.f.command('vkDestroyShaderModule', device=self.w.DEVICE,
                       shaderModule=self.FS2)
        self.module(self.FS2, module)
        s = self.w.structure
        self.f.command('vkCreateImage', device=self.w.DEVICE, pImage=self.IMAGE,
            pCreateInfo=s('VkImageCreateInfo', pNext=[], flags=0, imageType=1,
                format=37, extent=s('VkExtent3D', width=8, height=4, depth=1),
                mipLevels=1, arrayLayers=1, samples=1, tiling=0, usage=15,
                sharingMode=0, queueFamilyIndexCount=0, pQueueFamilyIndices=[],
                initialLayout=1))
        self.f.command('vkBindImageMemory', device=self.w.DEVICE, image=self.IMAGE,
                       memory=self.w.MEMORY, memoryOffset=4352)
        self.f.command('vkCreateImageView', device=self.w.DEVICE, pView=self.VIEW,
            pCreateInfo=s('VkImageViewCreateInfo', pNext=[], flags=0,
                image=self.IMAGE, viewType=1, format=37,
                components=s('VkComponentMapping', r=0, g=0, b=0, a=0),
                subresourceRange=s('VkImageSubresourceRange', aspectMask=1,
                    baseMipLevel=0, levelCount=1, baseArrayLayer=0, layerCount=1)))
        self.f.command('vkCreateDescriptorPool', device=self.w.DEVICE,
            pDescriptorPool=self.POOL,
            pCreateInfo=s('VkDescriptorPoolCreateInfo', pNext=[], flags=1,
                maxSets=1, poolSizeCount=2,
                pPoolSizes=[s('VkDescriptorPoolSize', type=2, descriptorCount=1),
                            s('VkDescriptorPoolSize', type=0, descriptorCount=1)]))
        self.f.command('vkAllocateDescriptorSets', device=self.w.DEVICE,
            pDescriptorSets=[self.DSET], pAllocateInfo=s(
                'VkDescriptorSetAllocateInfo', pNext=[], descriptorPool=self.POOL,
                descriptorSetCount=1, pSetLayouts=[self.r.DSL]))
        self.f.command('vkUpdateDescriptorSets', device=self.w.DEVICE,
            descriptorWriteCount=2, descriptorCopyCount=0, pDescriptorCopies=[],
            pDescriptorWrites=[
                s('VkWriteDescriptorSet', pNext=[], dstSet=self.DSET,
                    dstBinding=0, dstArrayElement=0, descriptorCount=1,
                    descriptorType=2, pTexelBufferView=[],
                    pImageInfo=[s('VkDescriptorImageInfo', sampler=0,
                        imageView=self.VIEW, imageLayout=1)], pBufferInfo=[]),
                s('VkWriteDescriptorSet', pNext=[], dstSet=self.DSET,
                    dstBinding=1, dstArrayElement=0, descriptorCount=1,
                    descriptorType=0, pTexelBufferView=[],
                    pImageInfo=[s('VkDescriptorImageInfo', sampler=self.SAMPLER,
                        imageView=0, imageLayout=1)], pBufferInfo=[])])
        did = self.e.golden.img_fmt_id(self.e.model, 37)
        pitch = self.e.golden.img_mpitch(self.e.model, 8, did, 0)
        base = self.f.owner.base + 4352
        for y in range(4):
            for x in range(8):
                texel = bytes((x * 32, y * 64, (x + y) * 16, 255))
                self.f.state.aperture.write(base + y * pitch + x * 4, texel)
        return did

    def _image_fetch_draw(self):
        self.upload(self.ndc_triangle())
        self.pipeline()
        self.begin_pass()
        self.viewport()
        self.scissor()
        self.bind()
        self.f.command('vkCmdBindDescriptorSets', commandBuffer=self.f.CB,
            pipelineBindPoint=0, layout=self.g.PL, firstSet=0,
            descriptorSetCount=1, pDescriptorSets=[self.DSET],
            dynamicOffsetCount=0, pDynamicOffsets=[])
        self.draw()
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.f.end()
        job = self.f.enqueue()
        self.f.drain()
        self.assertEqual(job.state, 'done')
        return job

    def texel_want(self, did, x, y):
        return self.e.golden.img_clear_texel(
            self.e.model, did,
            struct.unpack('<4I', struct.pack('<4f',
                (x * 32) / 255.0, (y * 64) / 255.0, ((x + y) * 16) / 255.0,
                1.0)))

    def test_fragment_per_pixel_image_fetch(self):
        # per-fragment texturing: the FS derives ivec2(FragCoord.xy) and
        # fetches texel(x,y); every covered framebuffer texel must equal
        # its own (x,y)-encoded image texel.
        did = self._image_fetch_setup(fs_image_program(per_pixel=True))
        self._image_fetch_draw()
        for x, y in ((0, 0), (1, 1), (2, 0), (0, 2), (4, 1)):
            self.assertEqual(self.read_texel(x, y), self.texel_want(did, x, y))
        self.assertEqual(self.read_texel(7, 3), self.clear_texel())
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_fragment_combined_image_sampler_fetch(self):
        # combined-image-sampler (kind 1): the FS declares OpTypeSampledImage
        # and OpImageFetch reads the bound image through a COMBINED_IMAGE_
        # SAMPLER descriptor carrying a VkSampler.  Fetch ignores sampler
        # state, so each covered texel must equal its (x,y)-encoded image
        # texel exactly as the kind-2 sampled-image draw did.
        did = self._image_fetch_setup(
            fs_image_program(per_pixel=True, combined=True), dtype=1)
        self._image_fetch_draw()
        for x, y in ((0, 0), (1, 1), (2, 0), (0, 2), (4, 1)):
            self.assertEqual(self.read_texel(x, y), self.texel_want(did, x, y))
        self.assertEqual(self.read_texel(7, 3), self.clear_texel())
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_fragment_explicit_lod_sample(self):
        # sampler-bearing filtered sampling: the FS declares
        # OpTypeSampledImage and OpImageSampleExplicitLod samples the
        # COMBINED_IMAGE_SAMPLER descriptor at normalized coord (0.3125,
        # 0.375) = texel (2,1) centre with LOD 0 under a nearest sampler.
        # Every covered framebuffer texel must equal that single texel.
        did = self._image_fetch_setup(fs_sample_program(), dtype=1)
        self._image_fetch_draw()
        want = self.texel_want(did, 2, 1)
        for x, y in ((0, 0), (1, 1), (2, 0), (0, 2), (4, 1)):
            self.assertEqual(self.read_texel(x, y), want)
        self.assertEqual(self.read_texel(7, 3), self.clear_texel())
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_fragment_implicit_lod_sample(self):
        # implicit-LOD sampling: OpImageSampleImplicitLod derives LOD from
        # coordinate derivatives; the constant coord gives zero derivatives
        # so the base mip resolves - same texel(2,1) result as explicit LOD 0.
        did = self._image_fetch_setup(
            fs_sample_program(implicit=True), dtype=1)
        self._image_fetch_draw()
        want = self.texel_want(did, 2, 1)
        for x, y in ((0, 0), (1, 1), (2, 0), (0, 2), (4, 1)):
            self.assertEqual(self.read_texel(x, y), want)
        self.assertEqual(self.read_texel(7, 3), self.clear_texel())
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_fragment_separate_sampler_image_sample(self):
        # separate sampler+image pairing: a SAMPLED_IMAGE (kind2, binding0)
        # and a SAMPLER (kind0, binding1) are merged by OpSampledImage and
        # sampled via OpImageSampleExplicitLod at normalized coord
        # (0.3125,0.375)=texel(2,1) centre under a nearest VkSampler.
        did = self._separate_sampler_setup(fs_separate_sample_program())
        self._image_fetch_draw()
        want = self.texel_want(did, 2, 1)
        for x, y in ((0, 0), (1, 1), (2, 0), (0, 2), (4, 1)):
            self.assertEqual(self.read_texel(x, y), want)
        self.assertEqual(self.read_texel(7, 3), self.clear_texel())
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_fragment_sampler_address_mode_clamp(self):
        # sampler address-mode variety: OpImageSampleExplicitLod at
        # normalized u=1.25 (su0=floor(1.25*8)=10, out of range) under a
        # CLAMP_TO_EDGE (mode 2) VkSampler clamps to texel x=7, whereas the
        # default REPEAT sampler would wrap to x=2.  v=0.375 -> y=1 in range.
        did = self._image_fetch_setup(
            fs_sample_program(u=1.25, v=0.375), dtype=1, sampler_addr=2)
        self._image_fetch_draw()
        want = self.texel_want(did, 7, 1)
        for x, y in ((0, 0), (1, 1), (2, 0), (0, 2), (4, 1)):
            self.assertEqual(self.read_texel(x, y), want)
        self.assertEqual(self.read_texel(7, 3), self.clear_texel())
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_fragment_sampler_address_mode_mirrored(self):
        # sampler address-mode variety: the same u=1.25 (su0=10) under a
        # MIRRORED_REPEAT (mode 1) VkSampler folds 10 % (2*8)=10, then since
        # 10 >= 8 mirrors to 2*8-1-10 = 5 -> texel x=5, distinct from
        # REPEAT x=2 and CLAMP_TO_EDGE x=7.  v=0.375 -> y=1 in range.
        did = self._image_fetch_setup(
            fs_sample_program(u=1.25, v=0.375), dtype=1, sampler_addr=1)
        self._image_fetch_draw()
        want = self.texel_want(did, 5, 1)
        for x, y in ((0, 0), (1, 1), (2, 0), (0, 2), (4, 1)):
            self.assertEqual(self.read_texel(x, y), want)
        self.assertEqual(self.read_texel(7, 3), self.clear_texel())
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_fragment_sampler_address_mode_border(self):
        # sampler address-mode variety: the same u=1.25 (su0=10, out of
        # range) under a CLAMP_TO_BORDER (mode 3) VkSampler substitutes the
        # sampler border colour rather than wrapping/clamping/mirroring.
        # FLOAT_OPAQUE_WHITE (borderColor=4) -> all channels 1.0 -> the
        # covered texels decode to (255,255,255,255).
        did = self._image_fetch_setup(
            fs_sample_program(u=1.25, v=0.375), dtype=1, sampler_addr=3,
            border_color=4)
        self._image_fetch_draw()
        want = self.e.golden.img_clear_texel(
            self.e.model, did,
            struct.unpack('<4I', struct.pack('<4f', 1.0, 1.0, 1.0, 1.0)))
        for x, y in ((0, 0), (1, 1), (2, 0), (0, 2), (4, 1)):
            self.assertEqual(self.read_texel(x, y), want)
        self.assertEqual(self.read_texel(7, 3), self.clear_texel())
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_fragment_mipmap_explicit_lod(self):
        # mipmap selection: a 2-mip 8x4 image (mip0 = (x,y) pattern,
        # mip1 = solid green 0,255,0,255) sampled by
        # OpImageSampleExplicitLod.  lod=1.0 -> le=16 -> m0=(16+8)>>4=1
        # selects mip1 under NEAREST_MIPMAP_NEAREST, so covered texels are
        # green - a value no mip0 texel can produce (max G=192).  This
        # exercises the multi-level view admission + ImageBinding.mips ->
        # mdim binding-row encode added for mipmapped descriptors.
        did = self._image_fetch_setup(
            fs_sample_program(u=0.5, v=0.5, lod=1.0), dtype=1, mips=2,
            max_lod=2.0)
        self._image_fetch_draw()
        want = self.e.golden.img_clear_texel(
            self.e.model, did,
            struct.unpack('<4I', struct.pack('<4f', 0.0, 1.0, 0.0, 1.0)))
        for x, y in ((0, 0), (1, 1), (2, 0), (0, 2), (4, 1)):
            self.assertEqual(self.read_texel(x, y), want)
        self.assertEqual(self.read_texel(7, 3), self.clear_texel())
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_fragment_trilinear_filter_blend(self):
        # trilinear filtering: a LINEAR min/mag + LINEAR mipmap VkSampler
        # samples at u=0.4375, v=0.375, lod=0.5.  mip0 (8x4) lands on a
        # single texel - su0=floor(0.4375*8*256-128)=768 -> iu0=3,fu0=0;
        # sv0=floor(0.375*4*256-128)=256 -> iv0=1,fv0=0 - texel(3,1)=
        # (96,64,64,255).  mip1 (4x2) is a solid (0,192,0,255) fill so its
        # bilinear footprint collapses to that colour regardless of the
        # (different-dimension) fractional coords.  lod=0.5 -> le=8 ->
        # mipmapMode LINEAR gives m0=0,m1=1,fw=(8&0xF)<<4=128 -> exact
        # 50/50 mip blend -> per-channel mean (48,128,32,255), all
        # integers so the 16-bit fixed-point + UNORM8 round-trip is
        # exact.  Exercises the tril (m0!=m1) accumulate + fw blend arm.
        did = self._image_fetch_setup(
            fs_sample_program(u=0.4375, v=0.375, lod=0.5), dtype=1,
            linear=True, mip_linear=True, mips=2, max_lod=2.0,
            mip_color=(0, 192, 0, 255))
        self._image_fetch_draw()
        want = self.e.golden.img_clear_texel(
            self.e.model, did,
            struct.unpack('<4I', struct.pack('<4f',
                (96 + 0) / 2 / 255.0, (64 + 192) / 2 / 255.0,
                (64 + 0) / 2 / 255.0, 1.0)))
        for x, y in ((0, 0), (1, 1), (2, 0), (0, 2), (4, 1)):
            self.assertEqual(self.read_texel(x, y), want)
        self.assertEqual(self.read_texel(7, 3), self.clear_texel())
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_fragment_image_gather(self):
        # OpImageGather (opcode 96): a combined-image-sampler gathers the
        # 2x2 texel footprint around a normalized coord and returns a vec4
        # whose component gi is the `comp` channel of footprint texel gi
        # (SPIR-V order (i0,j1),(i1,j1),(i1,j0),(i0,j0)).  At u=0.35,
        # v=0.4 the 8.8 coord gives iu0=2, iv0=1 -> footprint x{2,3},
        # y{1,2}; comp=0 selects the R channel (x*32): texels (2,2)=64,
        # (3,2)=96, (3,1)=96, (2,1)=64 -> framebuffer RGBA (64,96,96,64).
        # No filtering - each result component is one raw texel channel.
        did = self._image_fetch_setup(
            fs_gather_program(u=0.35, v=0.4, comp=0), dtype=1)
        self._image_fetch_draw()
        want = self.e.golden.img_clear_texel(
            self.e.model, did,
            struct.unpack('<4I', struct.pack('<4f',
                64 / 255.0, 96 / 255.0, 96 / 255.0, 64 / 255.0)))
        for x, y in ((0, 0), (1, 1), (2, 0), (0, 2), (4, 1)):
            self.assertEqual(self.read_texel(x, y), want)
        self.assertEqual(self.read_texel(7, 3), self.clear_texel())
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_fragment_projective_sample(self):
        # OpImageSampleProjImplicitLod (opcode 91): a vec3 coordinate
        # (u,v,d) is divided component-wise - coord.xy /= d - before
        # sampling.  u=0.6,v=0.7,d=2 -> (0.3,0.35); nearest mip0 ->
        # texel(2,1)=(64,64,48,255).  The undivided (0.6,0.7) would hit
        # texel(4,2)=(128,128,96,255), so the observed value proves the
        # perspective divide ran.  Implicit LOD with constant coords ->
        # zero derivatives -> base mip.
        did = self._image_fetch_setup(
            fs_proj_sample_program(u=0.6, v=0.7, d=2.0), dtype=1)
        self._image_fetch_draw()
        want = self.e.golden.img_clear_texel(
            self.e.model, did,
            struct.unpack('<4I', struct.pack('<4f',
                64 / 255.0, 64 / 255.0, 48 / 255.0, 1.0)))
        for x, y in ((0, 0), (1, 1), (2, 0), (0, 2), (4, 1)):
            self.assertEqual(self.read_texel(x, y), want)
        self.assertEqual(self.read_texel(7, 3), self.clear_texel())
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_fragment_dref_sample_compare(self):
        # OpImageSampleDrefImplicitLod (opcode 89): depth-reference
        # sampling of a D16_UNORM image through a compare-enabled
        # COMBINED_IMAGE_SAMPLER.  Every depth texel = 0.25; ref = 0.1
        # under LESS_OR_EQUAL -> f_dcmp(ref16, depth16) = ref <= depth
        # -> compare true -> scalar 1.0 broadcast to RGBA -> white
        # framebuffer texel.  The D16_UNORM descriptor is newly admitted
        # for sampled/combined kinds (still rejected for storage); the
        # compareEnable/compareOp reach the sampler word bits 20/17-19
        # the model reads as cen/cmo.
        self._dref_setup(fs_dref_program(u=0.5, v=0.5, ref=0.1))
        self._image_fetch_draw()
        did = self.e.golden.img_fmt_id(self.e.model, 37)
        want = self.e.golden.img_clear_texel(
            self.e.model, did,
            struct.unpack('<4I', struct.pack('<4f',
                1.0, 1.0, 1.0, 1.0)))
        for x, y in ((0, 0), (1, 1), (2, 0), (0, 2), (4, 1)):
            self.assertEqual(self.read_texel(x, y), want)
        self.assertEqual(self.read_texel(7, 3), self.clear_texel())
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_fragment_dref_sample_compare_false(self):
        # complementary dref case: same D16_UNORM depth=0.25 image and
        # LESS_OR_EQUAL compare, but ref = 0.5 > depth -> ref <= depth is
        # false -> scalar 0.0 -> transparent-black framebuffer texel.
        # Together with the true case this proves the compare
        # discriminates rather than returning a constant.
        self._dref_setup(fs_dref_program(u=0.5, v=0.5, ref=0.5))
        self._image_fetch_draw()
        did = self.e.golden.img_fmt_id(self.e.model, 37)
        want = self.e.golden.img_clear_texel(
            self.e.model, did,
            struct.unpack('<4I', struct.pack('<4f',
                0.0, 0.0, 0.0, 0.0)))
        for x, y in ((0, 0), (1, 1), (2, 0), (0, 2), (4, 1)):
            self.assertEqual(self.read_texel(x, y), want)
        self.assertEqual(self.read_texel(7, 3), self.clear_texel())
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_fragment_dref_projective_sample(self):
        # OpImageSampleDrefProjImplicitLod (opcode 93): the projective
        # dref form takes a vec3 coord (u,v,d) the model perspective-
        # divides (coord.xy /= d) before the depth compare.  Uniform
        # depth=0.25 + ref=0.1 -> ref<=depth true -> 1.0 -> white; the
        # uniform depth means the divide is not isolated here (that arm
        # is proven by test_fragment_projective_sample opcode 91), but
        # this exercises the vec3-coordinate dref operand path e2e.
        self._dref_setup(fs_dref_program(u=0.6, v=0.7, ref=0.1,
                                         proj=True, d=2.0))
        self._image_fetch_draw()
        did = self.e.golden.img_fmt_id(self.e.model, 37)
        want = self.e.golden.img_clear_texel(
            self.e.model, did,
            struct.unpack('<4I', struct.pack('<4f',
                1.0, 1.0, 1.0, 1.0)))
        for x, y in ((0, 0), (1, 1), (2, 0), (0, 2), (4, 1)):
            self.assertEqual(self.read_texel(x, y), want)
        self.assertEqual(self.read_texel(7, 3), self.clear_texel())
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_fragment_dref_explicit_lod_sample(self):
        # OpImageSampleDrefExplicitLod (opcode 90): a 2-level D16_UNORM
        # depth image, mip0 depth=0.25 and mip1 depth=0.6, sampled at
        # explicit LOD=1.0 under a LESS_OR_EQUAL compare with ref=0.5.
        # LOD 1 selects mip1 -> ref(0.5) <= depth(0.6) true -> 1.0 ->
        # white; mip0 would give ref <= 0.25 false -> black, so the white
        # result proves the explicit LOD drove mip selection in the dref
        # path (maxLod=1.0 keeps the sampler from clamping to mip0).
        self._dref_setup(fs_dref_program(u=0.5, v=0.5, ref=0.5, lod=1.0),
                         depth=0.25, mip_depth=0.6, mips=2, max_lod=1.0)
        self._image_fetch_draw()
        did = self.e.golden.img_fmt_id(self.e.model, 37)
        want = self.e.golden.img_clear_texel(
            self.e.model, did,
            struct.unpack('<4I', struct.pack('<4f',
                1.0, 1.0, 1.0, 1.0)))
        for x, y in ((0, 0), (1, 1), (2, 0), (0, 2), (4, 1)):
            self.assertEqual(self.read_texel(x, y), want)
        self.assertEqual(self.read_texel(7, 3), self.clear_texel())
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_fragment_dref_explicit_projective_sample(self):
        # OpImageSampleDrefProjExplicitLod (opcode 94): the explicit-
        # projective dref form combines a vec3 coord (u,v,d) the model
        # perspective-divides with an explicit Lod operand.  2-level
        # D16_UNORM depth image mip0=0.25/mip1=0.6, LOD=1.0, ref=0.5 ->
        # mip1 depth 0.6 -> ref<=depth true -> white; the uniform-per-mip
        # depth means the projective divide is not isolated (proven by
        # opcode 91/93), but this exercises the vec3+Lod dref operand
        # path end-to-end.
        self._dref_setup(fs_dref_program(u=0.6, v=0.7, ref=0.5, proj=True,
                                         d=2.0, lod=1.0),
                         depth=0.25, mip_depth=0.6, mips=2, max_lod=1.0)
        self._image_fetch_draw()
        did = self.e.golden.img_fmt_id(self.e.model, 37)
        want = self.e.golden.img_clear_texel(
            self.e.model, did,
            struct.unpack('<4I', struct.pack('<4f',
                1.0, 1.0, 1.0, 1.0)))
        for x, y in ((0, 0), (1, 1), (2, 0), (0, 2), (4, 1)):
            self.assertEqual(self.read_texel(x, y), want)
        self.assertEqual(self.read_texel(7, 3), self.clear_texel())
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_fragment_dref_gather_compare(self):
        # OpImageDrefGather (opcode 97): the 2x2 gather footprint feeds a
        # per-texel depth compare (no Component operand - the Dref float
        # sits where gather's Component would).  u=0.35,v=0.4 on the 8x4
        # image selects footprint texels x{2,3} y{1,2}; depth_fn=0.1*x
        # gives x=2 -> 0.2 and x=3 -> 0.3.  ref=0.25 under LESS_OR_EQUAL
        # (ref <= depth): the x=2 column fails, x=3 passes.  In SPIR-V
        # corner order the result vec4 is (i0j1,i1j1,i1j0,i0j0) =
        # (x2,x3,x3,x2) -> (0,1,1,0) -> RGBA(0,255,255,0), proving the
        # four compares ran independently rather than a uniform result.
        self._dref_setup(fs_dref_gather_program(u=0.35, v=0.4, ref=0.25),
                         depth_fn=lambda x, y, m: 0.1 * x)
        self._image_fetch_draw()
        did = self.e.golden.img_fmt_id(self.e.model, 37)
        want = self.e.golden.img_clear_texel(
            self.e.model, did,
            struct.unpack('<4I', struct.pack('<4f',
                0.0, 1.0, 1.0, 0.0)))
        for x, y in ((0, 0), (1, 1), (2, 0), (0, 2), (4, 1)):
            self.assertEqual(self.read_texel(x, y), want)
        self.assertEqual(self.read_texel(7, 3), self.clear_texel())
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_fragment_dref_pcf_bilinear_compare(self):
        # PCF (percentage-closer filtering): a LINEAR compare sampler runs
        # OpImageSampleDrefExplicitLod (opcode 90) — tx_finish_pts compares
        # each footprint texel then applies the same bilinear weighting as
        # colour sampling, returning the compare *fraction*.  u=0.25,v=0.375
        # on the 8x4 image gives footprint x{1,2} y{1} at exact 50/50 x
        # weight (same geometry as test_fragment_linear_filter_blend).
        # depth_fn gives x<=1 -> 0.4 (ref 0.5 fails LESS_OR_EQUAL) and
        # x>=2 -> 0.6 (passes): the two contributing taps compare 0 and 1,
        # averaged to scalar 0.5 -> vec4(0.5,..) mid-gray.  A fractional
        # result proves the compares ran per-texel and were weighted —
        # nearest would return a hard 0.0/1.0.
        self._dref_setup(fs_dref_program(u=0.25, v=0.375, ref=0.5, lod=0.0),
                         depth_fn=lambda x, y, m: 0.4 if x <= 1 else 0.6,
                         linear=True)
        self._image_fetch_draw()
        did = self.e.golden.img_fmt_id(self.e.model, 37)
        want = self.e.golden.img_clear_texel(
            self.e.model, did,
            struct.unpack('<4I', struct.pack('<4f',
                0.5, 0.5, 0.5, 0.5)))
        for x, y in ((0, 0), (1, 1), (2, 0), (0, 2), (4, 1)):
            self.assertEqual(self.read_texel(x, y), want)
        self.assertEqual(self.read_texel(7, 3), self.clear_texel())
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_fragment_linear_filter_blend(self):
        # bilinear filtering: a LINEAR min/mag VkSampler samples at
        # normalized u=0.25 (su0=floor((0.25*8-0.5)*256)=384 -> iu0=1,
        # fu0=128 -> exact 50/50 weight) blending texel(1,1)=(32,64,32)
        # and texel(2,1)=(64,64,48); v=0.375 -> iv0=1,fv0=0 single row.
        # Expected per-channel = mean of the two texels' UNORM decode.
        did = self._image_fetch_setup(
            fs_sample_program(u=0.25, v=0.375), dtype=1, linear=True)
        self._image_fetch_draw()
        want = self.e.golden.img_clear_texel(
            self.e.model, did,
            struct.unpack('<4I', struct.pack('<4f',
                (32 + 64) / 2 / 255.0, (64 + 64) / 2 / 255.0,
                (32 + 48) / 2 / 255.0, 1.0)))
        for x, y in ((0, 0), (1, 1), (2, 0), (0, 2), (4, 1)):
            self.assertEqual(self.read_texel(x, y), want)
        self.assertEqual(self.read_texel(7, 3), self.clear_texel())
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_fragment_storage_image_write(self):
        # storage-image write path: the FS derives ivec2(FragCoord.xy) and
        # OpImageWrites a constant red texel into a STORAGE_IMAGE (kind 3);
        # covered image texels must become red while uncovered keep their
        # pattern bytes.  Proves the GfxMemory kind-3 write admission.
        self._image_fetch_setup(fs_image_store_program(per_pixel=True), dtype=3)
        self._image_fetch_draw()
        did = self.e.golden.img_fmt_id(self.e.model, 37)
        pitch = self.e.golden.img_mpitch(self.e.model, 8, did, 0)
        base = self.f.owner.base + 4352
        red = bytes((255, 0, 0, 255))
        for y in range(4):
            for x in range(8):
                got = self.f.state.aperture.read(
                    base + y * pitch + x * 4, 4)
                if (x, y) in ((0, 0), (1, 1), (2, 0), (0, 2), (4, 1)):
                    self.assertEqual(got, red,
                                     'covered texel (%d,%d) not written' % (x, y))
                elif (x, y) == (7, 3):
                    self.assertEqual(
                        got, bytes((7 * 32, 3 * 64, (7 + 3) * 16, 255)),
                        'uncovered texel (7,3) was clobbered')
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
            queryPool=pool, firstQuery=0, queryCount=1, dataSize=16,
            pData=b'\0' * 16, stride=16, flags=0x1 | 0x8)
        mapping = self.f.blobs.map(7, 0)
        head = self.f.blobs.read(mapping, 0, 16)
        rtype, result, count = struct.unpack('<IIQ', head)
        payload = self.f.blobs.read(mapping, 16, count)
        # 64_BIT widens the availability word to u64 too (spec): the
        # (result,availability) pair is 16 bytes, not 12.
        value, avail = struct.unpack('<QQ', payload[:16])
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

    def begin_pass2(self):
        self.f.command('vkCmdBeginRenderPass', commandBuffer=self.f.CB,
            contents=0, pRenderPassBegin=self.w.structure('VkRenderPassBeginInfo',
                pNext=[], renderPass=self.g.r.RP2, framebuffer=self.g.r.FB2,
                renderArea=self.w.structure('VkRect2D',
                    offset=self.w.structure('VkOffset2D', x=0, y=0),
                    extent=self.w.structure('VkExtent2D', width=8, height=4)),
                clearValueCount=1, pClearValues=[self.w.structure('VkClearValue',
                    color=self.w.structure('VkClearColorValue',
                        uint32=[0, 0, 0, 0x3F800000]))]))

    def multi_pass_fixture(self):
        # two subpasses over the same attachment: layout 2 then layout 1
        self.g.r.multi_pass(subpasses=(((0, 2),), ((0, 1),)))
        self.g.r.framebuffer(handle=self.g.r.FB2, render_pass=self.g.r.RP2)

    def test_multi_subpass_begin_next_end_replays_on_wire_path(self):
        # the wire ObjPay carries both {C,refs} blocks; assembly walks
        # them, NextSubpass re-snapshots the active subpass, and replay
        # publishes the per-subpass boundary layouts
        self.multi_pass_fixture()
        self.begin_pass2()
        self.f.command('vkCmdNextSubpass', commandBuffer=self.f.CB)
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.f.end()
        job = self.f.enqueue()
        self.f.drain()
        self.assertEqual(job.state, 'done')
        self.assertFalse(self.f.front.fence_lost)
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_multi_subpass_next_past_last_loses_submission(self):
        # the record-time capture refuses advancing past the last
        # subpass, faulting the stream before the buffer can seal
        self.multi_pass_fixture()
        self.begin_pass2()
        self.f.command('vkCmdNextSubpass', commandBuffer=self.f.CB)
        with self.assertRaises(StreamFault):
            self.f.command('vkCmdNextSubpass', commandBuffer=self.f.CB)

    def test_multi_subpass_draw_in_later_subpass_replays_on_wire(self):
        # a pipeline declared for subpass 1 (kept on the wire, parked
        # in aux[9:8]) draws after vkCmdNextSubpass: the assembly
        # matches the pipeline subpass against the active subpass and
        # the draw replays into the subpass-1 attachment layout
        self.multi_pass_fixture()
        self.upload(self.ndc_triangle())
        self.pipeline(rp=self.g.r.RP2, subpass=1)
        self.begin_pass2()
        self.viewport()
        self.scissor()
        self.bind()
        self.f.command('vkCmdNextSubpass', commandBuffer=self.f.CB)
        self.draw()
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.f.end()
        job = self.f.enqueue()
        self.f.drain()
        self.assertEqual(job.state, 'done')
        self.assertFalse(self.f.front.fence_lost)
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_multi_subpass_subpass0_pipeline_draw_refuses_on_wire(self):
        # a subpass-0 pipeline inside subpass 1 loses the submission at
        # enqueue: aux[9:8]=0 != active subpass 1 (StDsPipeCpl mirror)
        self.multi_pass_fixture()
        self.pipeline(rp=self.g.r.RP2, subpass=0)
        self.begin_pass2()
        self.viewport()
        self.scissor()
        self.bind()
        self.f.command('vkCmdNextSubpass', commandBuffer=self.f.CB)
        self.draw()
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.f.end()
        with self.assertRaises(ValueError):
            self.f.enqueue()
        self.assertFalse(self.e.transfers.active)
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_multi_subpass_late_pipeline_draw_in_subpass0_refuses(self):
        # a subpass-1 pipeline inside subpass 0 loses symmetrically:
        # the declared subpass must equal the active subpass, not just
        # be in range
        self.multi_pass_fixture()
        self.pipeline(rp=self.g.r.RP2, subpass=1)
        self.begin_pass2()
        self.viewport()
        self.scissor()
        self.bind()
        self.draw()
        self.f.command('vkCmdEndRenderPass', commandBuffer=self.f.CB)
        self.f.end()
        with self.assertRaises(ValueError):
            self.f.enqueue()
        self.assertFalse(self.e.transfers.active)
        self.assertEqual(self.f.owner.work_refs, 0)

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
