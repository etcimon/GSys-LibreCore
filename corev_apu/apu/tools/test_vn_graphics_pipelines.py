# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Immutable VS/FS pipeline identity without native draw admission."""
import unittest

from shader.spirv_scan import Scanner
import test_vn_native_rendering as rendering_fixture
from vn_graphics_pipelines import operand
from vn_native_execution import StreamFault
from vn_native_pipelines import operand as compute_operand


def stage_program(em, value=0x3F800000, spec=False):
    words = [0x07230203, 0x00010300, 0, 16, 0]

    def emit(opcode, *values):
        words.extend(((len(values) + 1) << 16 | opcode, *values))

    emit(17, 1)
    emit(14, 0, 1)
    emit(15, em, 10, 0x6E69616D, 0, 6)
    if em == 4:
        emit(16, 10, 7)
    emit(71, 6, 11 if em == 0 else 30, 0)
    if spec:
        emit(71, 8, 1, 7)
    emit(19, 1)
    emit(33, 2, 1)
    emit(22, 3, 32)
    emit(23, 4, 3, 4)
    emit(32, 5, 3, 4)
    emit(59, 5, 6, 3)
    emit(43, 3, 7, 0)
    emit(50 if spec else 43, 3, 8, value)
    emit(44, 4, 9, *((7, 7, 7, 8) if em == 0 else (8, 8, 8, 8)))
    emit(54, 1, 10, 0, 2)
    emit(248, 11)
    emit(62, 6, 9)
    emit(253)
    emit(56)
    return tuple(words)


class GraphicsPipelineTests(unittest.TestCase):
    PL, VS, FS, PIPE = (0x740000001000 + i for i in range(4))

    def setUp(self):
        self.r = rendering_fixture.RenderingTests()
        self.r.setUp()
        self.f, self.e, self.w = self.r.f, self.r.e, self.r.w
        self.layout()
        self.module(self.VS, 0)
        self.module(self.FS, 4)

    def layout(self, ranges=()):
        self.f.command('vkCreatePipelineLayout', device=self.w.DEVICE, pPipelineLayout=self.PL,
            pCreateInfo=self.w.structure('VkPipelineLayoutCreateInfo', pNext=[], flags=0,
                setLayoutCount=0, pSetLayouts=[], pushConstantRangeCount=len(ranges),
                pPushConstantRanges=[self.w.structure('VkPushConstantRange',
                    stageFlags=stage, offset=offset, size=size) for stage, offset, size in ranges]))

    def module(self, handle, em, value=0x3F800000, spec=False):
        code = stage_program(em, value, spec)
        self.f.command('vkCreateShaderModule', device=self.w.DEVICE, pShaderModule=handle,
            pCreateInfo=self.w.structure('VkShaderModuleCreateInfo', pNext=[], flags=0,
                codeSize=len(code) * 4, pCode=list(code)))
        return code

    def spec(self, value):
        return self.w.structure('VkSpecializationInfo', mapEntryCount=1,
            pMapEntries=[self.w.structure('VkSpecializationMapEntry', constantID=7, offset=0, size=4)],
            dataSize=4, pData=value.to_bytes(4, 'little'))

    def pipeline(self, *, reverse=False, fs_name='main', vs_module=None, vs_spec=None, fs_spec=None):
        s = self.w.structure
        stages = [s('VkPipelineShaderStageCreateInfo', pNext=[], flags=0, stage=stage,
            module=module, pName=name, pSpecializationInfo=spec)
            for stage, module, name, spec in (
                (1, vs_module or self.VS, 'main', vs_spec), (0x10, self.FS, fs_name, fs_spec))]
        if reverse:
            stages.reverse()
        self.f.command('vkCreateGraphicsPipelines', device=self.w.DEVICE, pipelineCache=0,
            createInfoCount=1, pPipelines=[self.PIPE], pCreateInfos=[s('VkGraphicsPipelineCreateInfo',
                pNext=[], flags=0, stageCount=2, pStages=stages,
                pVertexInputState=s('VkPipelineVertexInputStateCreateInfo', pNext=[], flags=0,
                    vertexBindingDescriptionCount=0, pVertexBindingDescriptions=[],
                    vertexAttributeDescriptionCount=0, pVertexAttributeDescriptions=[]),
                pInputAssemblyState=s('VkPipelineInputAssemblyStateCreateInfo', pNext=[], flags=0,
                    topology=3, primitiveRestartEnable=0), pTessellationState=None,
                pViewportState=s('VkPipelineViewportStateCreateInfo', pNext=[], flags=0,
                    viewportCount=1, pViewports=[], scissorCount=1, pScissors=[]),
                pRasterizationState=s('VkPipelineRasterizationStateCreateInfo', pNext=[], flags=0,
                    depthClampEnable=0, rasterizerDiscardEnable=0, polygonMode=0,
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
                    dynamicStateCount=2, pDynamicStates=[0, 1]), layout=self.PL,
                renderPass=self.r.RP, subpass=0, basePipelineHandle=0, basePipelineIndex=-1)])
        return operand(self.e, 1, self.PIPE)[0]

    def test_selected_stages_and_parked_state_are_immutable_snapshots(self):
        snapshot = self.pipeline()
        self.assertEqual((snapshot.vertex.entry, snapshot.fragment.entry), (b'main', b'main'))
        self.assertEqual(snapshot.vertex.code, stage_program(0))
        self.assertEqual(snapshot.fragment.code, stage_program(4))
        self.assertEqual(len(snapshot.state), self.e.golden.GP_PAY_WORDS)
        self.assertEqual(len(operand(self.e, 1, self.PIPE)[1]), 4)
        self.assertEqual((self.f.entry(self.VS)['pins'], self.f.entry(self.FS)['pins']), (1, 1))
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_stage_order_is_normalized_only_for_legacy_allocation(self):
        snapshot = self.pipeline(reverse=True)
        self.assertEqual((snapshot.state[44], snapshot.state[46]),
                         (snapshot.vertex.module, snapshot.fragment.module))
        self.assertEqual(snapshot.vertex.code, stage_program(0))

    def test_module_destroy_and_wire_id_reuse_do_not_redirect_stages(self):
        original = self.pipeline()
        for handle, em in ((self.VS, 0), (self.FS, 4)):
            self.f.command('vkDestroyShaderModule', device=self.w.DEVICE, shaderModule=handle)
            self.module(handle, em, 0x40000000)
        snapshot, _ = operand(self.e, 1, self.PIPE)
        self.assertEqual(snapshot, original)
        self.assertNotEqual(snapshot.vertex.module,
                            self.f.entry(self.VS)['gen'] << 16 | self.f.front.idmap[self.VS])

    def test_layout_and_render_pass_values_survive_id_reuse(self):
        original = self.pipeline()
        self.f.command('vkDestroyPipelineLayout', device=self.w.DEVICE, pipelineLayout=self.PL)
        self.layout(((1, 0, 4),))
        self.f.command('vkDestroyRenderPass', device=self.w.DEVICE, renderPass=self.r.RP)
        other = self.r.render_pass(fmt=44)
        snapshot, _ = operand(self.e, 1, self.PIPE)
        self.assertEqual(snapshot, original)
        self.assertFalse(snapshot.render_pass.compatible(other))
        self.assertNotEqual(snapshot.layout, self.f.entry(self.PL)['native_pipeline_layout'])

    def test_missing_fragment_entry_fails_before_pipeline_allocation(self):
        with self.assertRaisesRegex(StreamFault, 'entry'):
            self.pipeline(fs_name='missing')
        self.assertNotIn(self.PIPE, self.f.front.idmap)

    def test_wrong_vertex_execution_model_fails_before_allocation(self):
        with self.assertRaisesRegex(StreamFault, 'stage'):
            self.pipeline(vs_module=self.FS)
        self.assertNotIn(self.PIPE, self.f.front.idmap)

    def test_compute_resolution_does_not_admit_graphics_pipeline(self):
        self.pipeline()
        with self.assertRaisesRegex(ValueError, 'compute snapshot'):
            compute_operand(self.e, 1, self.PIPE)

    def test_parked_state_tampering_is_rejected(self):
        self.pipeline()
        base = (self.f.entry(self.PIPE)['aux'] >> 16 & 0xFFFF) << 6
        self.f.front.pay[base] ^= 1
        with self.assertRaises(KeyError):
            operand(self.e, 1, self.PIPE)

    def test_original_module_tampering_is_rejected(self):
        snapshot = self.pipeline()
        self.f.front.sh_code[snapshot.fragment.module][0] ^= 1
        with self.assertRaises(KeyError):
            operand(self.e, 1, self.PIPE)

    def test_independent_stage_specialization_preserves_original_words(self):
        for handle, em in ((self.VS, 0), (self.FS, 4)):
            self.f.command('vkDestroyShaderModule', device=self.w.DEVICE, shaderModule=handle)
            self.module(handle, em, spec=True)
        snapshot = self.pipeline(reverse=True, vs_spec=self.spec(0x40000000),
                                 fs_spec=self.spec(0x3F000000))
        self.assertEqual(snapshot.vertex.module_code, stage_program(0, spec=True))
        self.assertEqual(snapshot.fragment.module_code, stage_program(4, spec=True))
        self.assertNotEqual(snapshot.vertex.code, snapshot.vertex.module_code)
        self.assertNotEqual(snapshot.fragment.code, snapshot.fragment.module_code)
        self.assertEqual(Scanner(list(snapshot.vertex.code)).scan().consts[8], [0x40000000])
        self.assertEqual(Scanner(list(snapshot.fragment.code)).scan().consts[8], [0x3F000000])


if __name__ == '__main__':
    unittest.main()
