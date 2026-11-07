# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Native compute pipeline entry selection and pinned module identity."""
import unittest

import test_vn_native_layouts as layout_fixture
from test_vn_compute import program
from vn_native_execution import StreamFault
from vn_native_pipelines import operand


class PipelineTests(unittest.TestCase):
    def setUp(self):
        self.l = layout_fixture.LayoutTests()
        self.l.setUp()
        self.f, self.w, self.e = self.l.f, self.l.w, self.l.f.engine
        self.l.layout()
        self.module()

    def module(self, code=None):
        code = code or program()
        self.f.command('vkCreateShaderModule', device=self.w.DEVICE,
            pShaderModule=self.l.MODULE, pCreateInfo=self.w.structure(
                'VkShaderModuleCreateInfo', pNext=[], flags=0,
                codeSize=len(code) * 4, pCode=list(code)))

    def pipeline(self, name='main', stage=0x20, spec=None):
        self.f.command('vkCreateComputePipelines', device=self.w.DEVICE,
            pipelineCache=0, createInfoCount=1, pPipelines=[self.l.PIPE],
            pCreateInfos=[self.w.structure('VkComputePipelineCreateInfo', pNext=[],
                flags=0, stage=self.w.structure('VkPipelineShaderStageCreateInfo',
                    pNext=[], flags=0, stage=stage, module=self.l.MODULE, pName=name,
                    pSpecializationInfo=spec), layout=self.l.PL,
                basePipelineHandle=0, basePipelineIndex=-1)])

    def test_selected_entry_and_module_layout_snapshot(self):
        self.pipeline()
        snapshot, references = operand(self.e, 1, self.l.PIPE)
        self.assertEqual(snapshot.entry, b'main')
        self.assertEqual(snapshot.code, program())
        self.assertEqual(len(references), 3)
        self.assertEqual(self.f.entry(self.l.PIPE)['pins'], 0)
        self.assertEqual(self.f.entry(self.l.MODULE)['pins'], 1)

    def test_destroyed_module_and_reused_wire_id_cannot_redirect_pipeline(self):
        self.pipeline()
        original, _ = operand(self.e, 1, self.l.PIPE)
        self.f.command('vkDestroyShaderModule', device=self.w.DEVICE,
                       shaderModule=self.l.MODULE)
        self.module(program(add=True))
        snapshot, _ = operand(self.e, 1, self.l.PIPE)
        self.assertEqual(snapshot.module, original.module)
        self.assertEqual(snapshot.code, program())
        self.assertNotEqual(snapshot.module, self.f.front.idmap[self.l.MODULE] |
                            self.f.entry(self.l.MODULE)['gen'] << 16)

    def test_layout_destruction_does_not_change_pipeline_value(self):
        self.pipeline()
        snapshot, _ = operand(self.e, 1, self.l.PIPE)
        self.f.command('vkDestroyPipelineLayout', device=self.w.DEVICE,
                       pipelineLayout=self.l.PL)
        self.l.layout(ranges=((0x20, 0, 16),))
        current, _ = operand(self.e, 1, self.l.PIPE)
        self.assertEqual(current.layout, snapshot.layout)
        self.assertFalse(current.layout.compatible(
            self.f.entry(self.l.PL)['native_pipeline_layout'], 0))

    def test_missing_entry_refuses_before_pipeline_allocation(self):
        with self.assertRaisesRegex(StreamFault, 'entry'):
            self.pipeline(name='not_main')
        self.assertNotIn(self.l.PIPE, self.f.front.idmap)

    def test_wrong_compute_stage_refuses_before_pipeline_allocation(self):
        with self.assertRaises(StreamFault):
            self.pipeline(stage=0x10)
        self.assertNotIn(self.l.PIPE, self.f.front.idmap)

    def test_reused_pipeline_id_rejects_old_generation(self):
        self.pipeline()
        _, references = operand(self.e, 1, self.l.PIPE)
        old = references[0][0]
        self.f.command('vkDestroyPipeline', device=self.w.DEVICE, pipeline=self.l.PIPE)
        self.pipeline()
        with self.assertRaises(KeyError):
            operand(self.e, 1, old)

    def test_parked_module_tamper_cannot_match_pipeline_snapshot(self):
        self.pipeline()
        snapshot, _ = operand(self.e, 1, self.l.PIPE)
        self.f.front.sh_code[snapshot.module][0] ^= 1
        with self.assertRaises(KeyError):
            operand(self.e, 1, self.l.PIPE)


if __name__ == '__main__':
    unittest.main()
