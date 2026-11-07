# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Graphics binding state resolves owned operands but never publishes work."""
import unittest
from unittest.mock import patch

import test_vn_graphics_resources as resource_fixture
from vn_graphics_bindings import GraphicsBindings


class BindingTests(unittest.TestCase):
    POOL, SET, ALT, IMAGE, VIEW = (0x770000001000 + i for i in range(5))

    def setUp(self):
        self.r = resource_fixture.ResourceTests()
        self.r.setUp()
        self.g, self.f, self.e, self.w = self.r.g, self.r.f, self.r.e, self.r.w
        self.f.command('vkDestroyBuffer', device=self.w.DEVICE, buffer=self.f.BUFFER)
        self.f.command('vkCreateBuffer', device=self.w.DEVICE, pBuffer=self.f.BUFFER,
            pCreateInfo=self.w.structure('VkBufferCreateInfo', pNext=[], flags=0,
                size=4096, usage=0x33, sharingMode=0, queueFamilyIndexCount=0,
                pQueueFamilyIndices=[]))
        self.f.command('vkBindBufferMemory', device=self.w.DEVICE, buffer=self.f.BUFFER,
                       memory=self.w.MEMORY, memoryOffset=0)

    def prepare(self, dtype=6, count=1, *, push=False, image=False):
        self.dtype, self.count, self.names = dtype, count, []
        if push:
            self.r.layout(push=((1, 0, 4), (16, 4, 4), (32, 8, 4)))
            self.r.module(0, storage=9, push_offsets=(0,))
            self.r.module(4, storage=9, push_offsets=(4,))
        else:
            self.r.layout(((0, dtype, count, 17),))
            for em in (0, 4):
                self.r.module(em, count=count, image_kind=3 if image else None)
            self.f.command('vkCreateDescriptorPool', device=self.w.DEVICE, pDescriptorPool=self.POOL,
                pCreateInfo=self.w.structure('VkDescriptorPoolCreateInfo', pNext=[], flags=1,
                    maxSets=1, poolSizeCount=1, pPoolSizes=[self.w.structure(
                        'VkDescriptorPoolSize', type=dtype, descriptorCount=count)]))
            self.f.command('vkAllocateDescriptorSets', device=self.w.DEVICE,
                pDescriptorSets=[self.SET], pAllocateInfo=self.w.structure(
                    'VkDescriptorSetAllocateInfo', pNext=[], descriptorPool=self.POOL,
                    descriptorSetCount=1, pSetLayouts=[self.r.DSL]))
            if image:
                self.image()
            self.write(image=image)
        self.g.pipeline()
        self.f.begin()
        self.command('vkCmdSetViewport', commandBuffer=self.f.CB, firstViewport=0, viewportCount=1,
            pViewports=[self.w.structure('VkViewport', x=0, y=0, width=0x41000000,
                height=0x40800000, minDepth=0, maxDepth=0x3F800000)])
        source = self.names[0][1]['native_graphics_dynamic']
        self.state = GraphicsBindings(self.e, 1, source)

    def image(self):
        self.f.command('vkCreateImage', device=self.w.DEVICE, pImage=self.IMAGE,
            pCreateInfo=self.w.structure('VkImageCreateInfo', pNext=[], flags=0,
                imageType=1, format=37, extent=self.w.structure(
                    'VkExtent3D', width=8, height=4, depth=1), mipLevels=1,
                arrayLayers=1, samples=1, tiling=0, usage=15, sharingMode=0,
                queueFamilyIndexCount=0, pQueueFamilyIndices=[], initialLayout=1))
        self.f.command('vkBindImageMemory', device=self.w.DEVICE, image=self.IMAGE,
                       memory=self.w.MEMORY, memoryOffset=4096)
        self.f.command('vkCreateImageView', device=self.w.DEVICE, pView=self.VIEW,
            pCreateInfo=self.w.structure('VkImageViewCreateInfo', pNext=[], flags=0,
                image=self.IMAGE, viewType=1, format=37,
                components=self.w.structure('VkComponentMapping', r=0, g=0, b=0, a=0),
                subresourceRange=self.w.structure('VkImageSubresourceRange',
                    aspectMask=1, baseMipLevel=0, levelCount=1, baseArrayLayer=0, layerCount=1)))

    def write(self, offset=0, *, image=False):
        self.f.command('vkUpdateDescriptorSets', device=self.w.DEVICE,
            descriptorWriteCount=1, descriptorCopyCount=0, pDescriptorCopies=[],
            pDescriptorWrites=[self.w.structure('VkWriteDescriptorSet', pNext=[],
                dstSet=self.SET, dstBinding=0, dstArrayElement=0, descriptorCount=self.count,
                descriptorType=self.dtype, pTexelBufferView=[],
                pImageInfo=[self.w.structure('VkDescriptorImageInfo', sampler=0,
                    imageView=self.VIEW, imageLayout=1)] * self.count if image else [],
                pBufferInfo=[] if image else [self.w.structure('VkDescriptorBufferInfo',
                    buffer=self.f.BUFFER, offset=offset + 256 * i, range=128)
                    for i in range(self.count)])])

    def command(self, name, **kwargs):
        self.f.command(name, **kwargs)
        record = self.f.front.cbd[self.f.front.idmap[self.f.CB]]['recs'][-1]
        self.names.append((name, record))

    def bind(self, *, pipeline=True, sets=True, offsets=(), point=0, layout=None):
        if pipeline:
            self.command('vkCmdBindPipeline', commandBuffer=self.f.CB,
                         pipelineBindPoint=point, pipeline=self.g.PIPE)
        if sets:
            self.command('vkCmdBindDescriptorSets', commandBuffer=self.f.CB,
                pipelineBindPoint=point, layout=layout or self.g.PL, firstSet=0,
                descriptorSetCount=1, pDescriptorSets=[self.SET],
                dynamicOffsetCount=len(offsets), pDynamicOffsets=list(offsets))

    def push(self, stage, offset, values):
        self.command('vkCmdPushConstants', commandBuffer=self.f.CB, layout=self.g.PL,
            stageFlags=stage, offset=offset, size=4 * len(values),
            pValues=b''.join(value.to_bytes(4, 'little') for value in values))

    def replay(self):
        for name, record in self.names[self.state.position:]:
            self.state.replay(name, record)

    def alternate_layout(self, *, sets=1, push=True):
        self.f.command('vkCreatePipelineLayout', device=self.w.DEVICE, pPipelineLayout=self.ALT,
            pCreateInfo=self.w.structure('VkPipelineLayoutCreateInfo', pNext=[], flags=0,
                setLayoutCount=sets, pSetLayouts=[self.r.DSL] * sets,
                pushConstantRangeCount=int(push), pPushConstantRanges=[self.w.structure(
                    'VkPushConstantRange', stageFlags=1, offset=0, size=4)] if push else []))

    def test_shared_ubo_resolves_separately_per_stage_without_leases(self):
        self.prepare()
        self.bind()
        self.f.end()
        self.replay()
        result = self.state.resolve()
        self.assertEqual(tuple(stage.stage for stage in result.stages), (1, 16))
        for stage in result.stages:
            self.assertEqual((stage.bindings[0].offset, stage.bindings[0].kind), (0, 6))
        result.validate()
        self.assertFalse(self.e.transfers.active)
        self.assertEqual(self.f.owner.work_refs, 0)
        self.assertFalse(any(entry['pins'] for entry in self.f.front.ent
                             if entry and entry['kind'] != self.e.golden.KIND['VkShaderModule']))

    def test_dynamic_offsets_apply_per_array_element(self):
        self.prepare(dtype=8, count=2)
        self.bind(offsets=(256, 512))
        self.replay()
        result = self.state.resolve()
        for stage in result.stages:
            self.assertEqual(tuple(binding.offset for binding in stage.bindings), (256, 768))

    def test_stage_specific_push_values_and_compute_isolation(self):
        self.prepare(push=True)
        self.bind(sets=False)
        self.push(1, 0, (7,))
        self.push(16, 4, (9,))
        self.push(32, 8, (99,))
        self.replay()
        vs, fs = self.state.resolve().stages
        self.assertEqual((vs.push[0], fs.push[1]), (7, 9))
        self.assertEqual((vs.push[1], fs.push[0], vs.push[2], fs.push[2]), (0, 0, 0, 0))

    def test_undefined_push_word_is_refused(self):
        self.prepare(push=True)
        self.bind(sets=False)
        self.push(1, 0, (7,))
        self.replay()
        with self.assertRaisesRegex(ValueError, 'undefined'):
            self.state.resolve()

    def test_compute_set_bind_does_not_replace_graphics_state(self):
        self.prepare()
        self.bind()
        self.replay()
        original = dict(self.state.sets)
        self.bind(pipeline=False, point=1)
        self.replay()
        self.assertEqual(self.state.sets, original)
        self.state.resolve().validate()

    def test_missing_set_is_refused(self):
        self.prepare()
        self.bind(sets=False)
        self.replay()
        with self.assertRaisesRegex(ValueError, 'missing'):
            self.state.resolve()

    def test_descriptor_rewrite_invalidates_old_guard_but_can_resolve_again(self):
        self.prepare()
        self.bind()
        self.replay()
        old = self.state.resolve()
        self.write(256)
        with self.assertRaises(KeyError):
            old.validate()
        self.assertEqual(self.state.resolve().stages[0].bindings[0].offset, 256)

    def test_pool_reset_invalidates_resolved_operands(self):
        self.prepare()
        self.bind()
        self.replay()
        result = self.state.resolve()
        self.f.command('vkResetDescriptorPool', device=self.w.DEVICE,
                       descriptorPool=self.POOL, flags=0)
        with self.assertRaises(KeyError):
            result.validate()

    def test_cb_reset_invalidates_binding_builder_and_result(self):
        self.prepare()
        self.bind()
        self.replay()
        result = self.state.resolve()
        self.f.end()
        self.f.command('vkResetCommandBuffer', commandBuffer=self.f.CB, flags=0)
        for action in (result.validate, self.state.resolve):
            with self.assertRaisesRegex(KeyError, 'recording epoch'):
                action()

    def test_storage_image_resolves_owned_backing_without_execution(self):
        self.prepare(dtype=3, image=True)
        self.bind()
        self.replay()
        for stage in self.state.resolve().stages:
            self.assertEqual((stage.bindings[0].kind, stage.bindings[0].offset), (3, 4096))
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_records_cannot_be_reordered_or_replayed_twice(self):
        self.prepare()
        self.bind()
        with self.assertRaisesRegex(ValueError, 'recording order'):
            self.state.replay(*self.names[1])
        self.replay()
        with self.assertRaisesRegex(ValueError, 'recording order'):
            self.state.replay(*self.names[-1])

    def test_resolution_admits_state_only_replay_without_work(self):
        self.prepare()
        self.bind()
        self.f.end()
        self.replay()
        self.state.resolve()
        job = self.e.replay.enqueue(1, [self.f.CB], compute=True)
        self.assertEqual(job.operations, ())
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_incompatible_rebind_disturbs_state_but_not_prior_resolution(self):
        self.prepare()
        self.bind()
        self.replay()
        original = self.state.resolve()
        self.alternate_layout()
        self.bind(pipeline=False, layout=self.ALT)
        self.replay()
        with self.assertRaisesRegex(ValueError, 'disturbed/incompatible'):
            self.state.resolve()
        original.validate()

    def test_late_bind_failure_does_not_partially_replace_sets(self):
        self.prepare()
        self.bind()
        self.replay()
        original = dict(self.state.sets)
        self.alternate_layout(sets=2, push=False)
        self.command('vkCmdBindDescriptorSets', commandBuffer=self.f.CB,
            pipelineBindPoint=0, layout=self.ALT, firstSet=0, descriptorSetCount=2,
            pDescriptorSets=[self.SET, self.SET], dynamicOffsetCount=0, pDynamicOffsets=[])
        name, record = self.names[-1]
        self.f.front.pay[record['imm'][7] + 2] = 0
        with self.assertRaises(KeyError):
            self.state.replay(name, record)
        self.assertEqual(self.state.sets, original)

    def test_late_push_failure_does_not_define_earlier_words(self):
        self.prepare(push=True)
        self.bind(sets=False)
        self.replay()
        self.push(1, 0, (7, 9))
        with self.assertRaisesRegex(ValueError, 'push stage/range'):
            self.replay()
        self.assertEqual(self.state.push, {})

    def test_new_pipeline_bind_does_not_redirect_old_result(self):
        self.prepare()
        self.bind()
        self.replay()
        original = self.state.resolve()
        self.g.PIPE = self.ALT + 1
        self.g.pipeline()
        self.bind(sets=False)
        self.replay()
        self.assertIsNot(original.pipeline, self.state.resolve().pipeline)
        original.validate()

    def test_module_destruction_keeps_pinned_pipeline_provenance(self):
        self.prepare()
        self.bind()
        self.replay()
        result = self.state.resolve()
        self.f.command('vkDestroyShaderModule', device=self.w.DEVICE, shaderModule=self.g.VS)
        result.validate()
        self.state.resolve().validate()

    def test_pipeline_retirement_during_descriptor_read_rejects_resolution(self):
        self.prepare()
        self.bind()
        self.replay()
        read, changed = self.f.front.apr64, False

        def retire(address):
            nonlocal changed
            if not changed:
                changed = True
                self.f.command('vkDestroyPipeline', device=self.w.DEVICE, pipeline=self.g.PIPE)
            return read(address)

        with patch.object(self.f.front, 'apr64', side_effect=retire):
            with self.assertRaises(KeyError):
                self.state.resolve()
        self.assertTrue(changed)
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_dynamic_alignment_is_checked_before_operand_admission(self):
        self.prepare(dtype=8, count=2)
        self.bind(offsets=(1, 256))
        self.replay()
        with self.assertRaisesRegex(ValueError, 'alignment'):
            self.state.resolve()
        self.assertFalse(self.e.transfers.active)

    def test_record_local_payload_length_prevents_neighbor_reads(self):
        self.prepare()
        self.bind()
        self.state.replay(*self.names[0])
        self.state.replay(*self.names[1])
        name, record = self.names[-1]
        record['payload_words'] = 1
        with self.assertRaisesRegex(ValueError, 'count/payload'):
            self.state.replay(name, record)
        self.assertEqual(self.state.sets, {})


if __name__ == '__main__':
    unittest.main()
