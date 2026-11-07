# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""By-value layout identity, ID reuse, immutable state and native fault boundary."""
from dataclasses import replace
import unittest

import test_vn_descriptor_operands as descriptor_fixture
from test_vn_compute import program
from vn_native_execution import StreamFault


class LayoutTests(unittest.TestCase):
    PL, PL2, DSL2, MODULE, PIPE, SAMPLER = (
        0x4000C000100C, 0x4000D000100D, 0x4000E000100E,
        0x4000F000100F, 0x400100001010, 0x400110001011)

    def setUp(self):
        self.d = descriptor_fixture.DescriptorTests()
        self.d.setUp()
        self.d.sets()
        self.f, self.w, self.front = self.d.f, self.d.w, self.d.front

    def clone(self, handle=None, stages=0x20, dtype=7, samplers=None):
        self.f.command('vkCreateDescriptorSetLayout', device=self.w.DEVICE,
            pSetLayout=handle or self.DSL2, pCreateInfo=self.w.structure(
                'VkDescriptorSetLayoutCreateInfo', pNext=[], flags=0, bindingCount=1,
                pBindings=[self.w.structure('VkDescriptorSetLayoutBinding',
                    binding=0, descriptorType=dtype, descriptorCount=2,
                    stageFlags=stages, pImmutableSamplers=samplers or [])]))

    def layout(self, handle=None, sets=None, ranges=()):
        sets = [self.d.LAYOUT] if sets is None else sets
        self.f.command('vkCreatePipelineLayout', device=self.w.DEVICE,
            pPipelineLayout=handle or self.PL, pCreateInfo=self.w.structure(
                'VkPipelineLayoutCreateInfo', pNext=[], flags=0, setLayoutCount=len(sets),
                pSetLayouts=sets, pushConstantRangeCount=len(ranges),
                pPushConstantRanges=[self.w.structure('VkPushConstantRange',
                    stageFlags=stage, offset=offset, size=size)
                    for stage, offset, size in ranges]))
        return self.f.entry(handle or self.PL)['native_pipeline_layout']

    def destroy_layout(self):
        self.f.command('vkDestroyDescriptorSetLayout', device=self.w.DEVICE,
                       descriptorSetLayout=self.d.LAYOUT)

    def sampler(self, address=0):
        self.f.command('vkCreateSampler', device=self.w.DEVICE, pSampler=self.SAMPLER,
            pCreateInfo=self.w.structure('VkSamplerCreateInfo', pNext=[], flags=0,
                magFilter=0, minFilter=0, mipmapMode=0, addressModeU=address,
                addressModeV=address, addressModeW=address, mipLodBias=0,
                anisotropyEnable=0, maxAnisotropy=0, compareEnable=0, compareOp=7,
                minLod=0, maxLod=0, borderColor=0, unnormalizedCoordinates=0))

    def test_sets_update_and_copy_after_layout_destroy_and_id_reuse(self):
        self.d.write()
        original = self.f.entry(self.d.SOURCE)['native_layout']['native_signature']
        self.destroy_layout()
        self.clone(self.d.LAYOUT, stages=0x10, dtype=6)
        self.d.write(offset=512)
        self.d.copy()
        operand = self.d.operand(self.d.TARGET)
        self.assertEqual((operand.binding.offset, operand.binding.kind), (512, 7))
        self.assertEqual(len(operand.references), 5)
        self.assertEqual(self.f.entry(self.d.SOURCE)['native_layout']['native_signature'], original)

    def test_set_free_after_layout_storage_is_reused(self):
        self.destroy_layout()
        self.clone(self.d.LAYOUT, stages=0x10)
        self.f.command('vkFreeDescriptorSets', device=self.w.DEVICE,
            descriptorPool=self.d.POOL, descriptorSetCount=2,
            pDescriptorSets=[self.d.SOURCE, self.d.TARGET])
        with self.assertRaises(KeyError):
            self.d.operand()

    def test_stage_flags_distinguish_equal_legacy_row_hashes(self):
        self.clone(stages=0x10)
        first, second = self.f.entry(self.d.LAYOUT), self.f.entry(self.DSL2)
        self.assertEqual(first['state'], second['state'])
        self.assertNotEqual(first['native_signature'], second['native_signature'])

    def test_identical_different_layout_handles_are_compatible(self):
        self.clone()
        first = self.layout()
        second = self.layout(self.PL2, sets=[self.DSL2])
        self.assertTrue(first.compatible(second, 0))
        self.assertFalse(first.compatible(second, 1))

    def test_pipeline_layout_does_not_follow_reused_set_layout_id(self):
        first = self.layout()
        self.destroy_layout()
        self.clone(self.d.LAYOUT, stages=0x10)
        second = self.layout(self.PL2)
        self.assertFalse(first.compatible(second, 0))

    def test_equal_canonical_device_numbers_do_not_merge_context_owners(self):
        snapshot = self.layout()
        self.assertFalse(snapshot.compatible(replace(snapshot, context=object()), 0))

    def test_push_range_order_is_canonical_but_identity_is_not_ignored(self):
        ranges = ((0x20, 0, 16), (1, 8, 8))
        first = self.layout(ranges=ranges)
        second = self.layout(self.PL2, ranges=tuple(reversed(ranges)))
        self.assertTrue(first.compatible(second, 0))
        third = self.layout(self.PL2 + 1, ranges=((0x20, 0, 8),))
        self.assertFalse(first.compatible(third, 0))

    def test_push_overlapping_same_stage_is_rejected_before_allocation(self):
        with self.assertRaises(StreamFault):
            self.layout(ranges=((0x20, 0, 16), (0x20, 8, 8)))
        self.assertNotIn(self.PL, self.front.idmap)

    def test_disjoint_push_bytes_cannot_repeat_shader_stages(self):
        with self.assertRaises(StreamFault):
            self.layout(ranges=((0x20, 0, 8), (0x20, 8, 8)))

    def test_all_shader_stages_is_a_valid_core_push_mask(self):
        snapshot = self.layout(ranges=((0x7FFFFFFF, 0, 16),))
        self.assertEqual(snapshot.push, ((0x7FFFFFFF, 0, 16),))

    def test_immutable_sampler_signature_retains_values_not_wire_id(self):
        self.sampler()
        self.clone(dtype=0, samplers=[self.SAMPLER] * 2)
        original = self.f.entry(self.DSL2)['native_signature']
        self.f.command('vkDestroySampler', device=self.w.DEVICE, sampler=self.SAMPLER)
        self.sampler(address=2)
        self.clone(self.DSL2 + 1, dtype=0, samplers=[self.SAMPLER] * 2)
        self.assertEqual(self.f.entry(self.DSL2)['native_signature'], original)
        self.assertNotEqual(original, self.f.entry(self.DSL2 + 1)['native_signature'])

    def test_recorded_bind_and_push_retain_layout_value_after_destroy(self):
        snapshot = self.layout(ranges=((0x20, 0, 16),))
        self.f.begin()
        self.f.command('vkCmdBindDescriptorSets', commandBuffer=self.f.CB,
            pipelineBindPoint=1, layout=self.PL, firstSet=0, descriptorSetCount=1,
            pDescriptorSets=[self.d.SOURCE], dynamicOffsetCount=0, pDynamicOffsets=[])
        self.f.command('vkCmdPushConstants', commandBuffer=self.f.CB,
            layout=self.PL, stageFlags=0x20, offset=0, size=4, pValues=b'abcd')
        self.f.end()
        self.f.command('vkDestroyPipelineLayout', device=self.w.DEVICE, pipelineLayout=self.PL)
        records = self.front.cbd[self.front.idmap[self.f.CB]]['recs']
        self.assertEqual([r['native_pipeline_layout'] for r in records], [snapshot, snapshot])
        for record in records:
            packed = self.f.engine.golden.sess_rec_words(record)
            self.assertEqual(len(packed), 16)

    def test_unused_specialization_ids_are_ignored(self):
        self.layout()
        code = program()
        self.f.command('vkCreateShaderModule', device=self.w.DEVICE, pShaderModule=self.MODULE,
            pCreateInfo=self.w.structure('VkShaderModuleCreateInfo', pNext=[], flags=0,
                                         codeSize=len(code) * 4, pCode=list(code)))
        spec = self.w.structure('VkSpecializationInfo', mapEntryCount=1,
            pMapEntries=[self.w.structure('VkSpecializationMapEntry', constantID=0,
                                         offset=0, size=4)], dataSize=4, pData=b'abcd')
        self.f.command('vkCreateComputePipelines', device=self.w.DEVICE,
                pipelineCache=0, createInfoCount=1, pPipelines=[self.PIPE],
                pCreateInfos=[self.w.structure('VkComputePipelineCreateInfo', pNext=[],
                    flags=0, stage=self.w.structure('VkPipelineShaderStageCreateInfo',
                        pNext=[], flags=0, stage=0x20, module=self.MODULE, pName='main',
                        pSpecializationInfo=spec), layout=self.PL,
                    basePipelineHandle=0, basePipelineIndex=-1)])
        self.assertEqual(self.f.entry(self.PIPE)['native_pipeline'].code, code)


if __name__ == '__main__':
    unittest.main()
