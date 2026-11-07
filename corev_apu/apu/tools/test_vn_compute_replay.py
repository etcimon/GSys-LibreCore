# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Opt-in internal compute replay ordering, admission and lifetime tests."""
import unittest
from unittest.mock import patch

import test_vn_native_pipelines as pipeline_fixture
from test_vn_compute import program
from vn_descriptor_operands import buffer_descriptor


def push_program():
    original, result = program(), list(program()[:5])

    def emit(code, *args):
        result.extend(((len(args) + 1) << 16 | code, *args))

    position, decorated = 5, False
    while position < len(original):
        count, opcode = original[position] >> 16, original[position] & 0xFFFF
        if opcode == 19 and not decorated:
            emit(71, 22, 2)
            emit(72, 22, 0, 35, 0)
            emit(72, 22, 1, 35, 4)
            decorated = True
        if opcode == 54:
            emit(30, 22, 3, 3)
            emit(32, 23, 9, 22)
            emit(32, 25, 9, 3)
            emit(43, 3, 21, 1)
            emit(59, 23, 24, 9)
        if opcode == 62:
            emit(65, 25, 27, 24, 21)
            emit(61, 3, 28, 27)
            emit(62, 12, 28)
        else:
            result.extend(original[position:position + count])
        position += count
    return tuple(result)


class ComputeReplayTests(unittest.TestCase):
    SECONDARY = 0x400120001012

    def setUp(self):
        self.p = pipeline_fixture.PipelineTests()
        self.p.setUp()
        self.p.pipeline()
        self.l, self.f, self.w, self.e = self.p.l, self.p.f, self.p.w, self.p.e
        self.d = self.l.d
        self.d.write()

    def pipeline_code(self, code):
        self.f.command('vkDestroyPipeline', device=self.w.DEVICE, pipeline=self.l.PIPE)
        self.f.command('vkDestroyShaderModule', device=self.w.DEVICE, shaderModule=self.l.MODULE)
        self.p.module(code)
        self.p.pipeline()

    def bind(self, handle=None, *, pipeline=True, sets=True, layout=None, offsets=()):
        cb = handle or self.f.CB
        if pipeline:
            self.f.command('vkCmdBindPipeline', commandBuffer=cb,
                           pipelineBindPoint=1, pipeline=self.l.PIPE)
        if sets:
            self.f.command('vkCmdBindDescriptorSets', commandBuffer=cb,
                pipelineBindPoint=1, layout=layout or self.l.PL, firstSet=0,
                descriptorSetCount=1, pDescriptorSets=[self.d.SOURCE],
                dynamicOffsetCount=len(offsets), pDynamicOffsets=list(offsets))

    def dispatch(self, handle=None):
        self.f.command('vkCmdDispatch', commandBuffer=handle or self.f.CB,
                       groupCountX=1, groupCountY=1, groupCountZ=1)

    def record(self):
        self.f.begin()
        self.bind()
        self.dispatch()
        self.f.end()

    def enqueue(self):
        return self.e.replay.enqueue(1, [self.f.CB], compute=True)

    def word(self, offset=256):
        return int.from_bytes(self.f.state.aperture.read(self.f.owner.base + offset, 4), 'little')

    def no_work(self):
        self.assertEqual(self.word(), 0)
        self.assertFalse(self.e.transfers.active)
        self.assertFalse(self.e.replay.held)
        self.assertEqual(self.f.owner.work_refs, 0)
        self.assertEqual(self.f.entry(self.f.CB)['state'] & 15, self.e.golden.CB_EXEC)

    def push_pipeline(self):
        self.f.command('vkDestroyPipeline', device=self.w.DEVICE, pipeline=self.l.PIPE)
        self.f.command('vkDestroyPipelineLayout', device=self.w.DEVICE, pipelineLayout=self.l.PL)
        self.l.layout(ranges=((0x20, 0, 16),))
        self.f.command('vkDestroyShaderModule', device=self.w.DEVICE, shaderModule=self.l.MODULE)
        self.p.module(push_program())
        self.p.pipeline()

    def push(self, values=(5, 7), offset=0, layout=None):
        self.f.command('vkCmdPushConstants', commandBuffer=self.f.CB,
            layout=layout or self.l.PL, stageFlags=0x20, offset=offset,
            size=4 * len(values), pValues=b''.join(v.to_bytes(4, 'little') for v in values))

    def dynamic_layout(self, *, stages=0x20, dtype=9, bindings=(4, 0)):
        self.f.command('vkFreeDescriptorSets', device=self.w.DEVICE,
            descriptorPool=self.d.POOL, descriptorSetCount=2,
            pDescriptorSets=[self.d.SOURCE, self.d.TARGET])
        self.f.command('vkDestroyDescriptorPool', device=self.w.DEVICE,
                       descriptorPool=self.d.POOL)
        self.l.destroy_layout()
        self.f.command('vkCreateDescriptorSetLayout', device=self.w.DEVICE,
            pSetLayout=self.d.LAYOUT, pCreateInfo=self.w.structure(
                'VkDescriptorSetLayoutCreateInfo', pNext=[], flags=0, bindingCount=len(bindings),
                pBindings=[self.w.structure('VkDescriptorSetLayoutBinding',
                    binding=b, descriptorType=dtype, descriptorCount=1,
                    stageFlags=stages, pImmutableSamplers=[]) for b in bindings]))
        self.f.command('vkCreateDescriptorPool', device=self.w.DEVICE,
            pDescriptorPool=self.d.POOL, pCreateInfo=self.w.structure(
                'VkDescriptorPoolCreateInfo', pNext=[], flags=1, maxSets=1,
                poolSizeCount=1, pPoolSizes=[self.w.structure(
                    'VkDescriptorPoolSize', type=dtype, descriptorCount=len(bindings))]))
        self.f.command('vkAllocateDescriptorSets', device=self.w.DEVICE,
            pDescriptorSets=[self.d.SOURCE], pAllocateInfo=self.w.structure(
                'VkDescriptorSetAllocateInfo', pNext=[], descriptorPool=self.d.POOL,
                descriptorSetCount=1, pSetLayouts=[self.d.LAYOUT]))
        self.d.dtype = dtype
        self.d.write(offset=0)
        self.f.command('vkDestroyPipeline', device=self.w.DEVICE, pipeline=self.l.PIPE)
        self.f.command('vkDestroyPipelineLayout', device=self.w.DEVICE, pipelineLayout=self.l.PL)
        self.l.layout()
        self.p.pipeline()

    def test_recorded_bind_dispatch_holds_objects_and_writes_on_poll_only(self):
        self.record()
        job = self.enqueue()
        self.assertEqual(self.word(), 0)
        for handle in (self.l.PIPE, self.d.SOURCE, self.d.POOL, self.f.BUFFER):
            self.assertGreater(self.f.entry(handle)['pins'], 0)
        self.assertEqual(self.f.entry(self.d.LAYOUT)['pins'], 0)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        self.assertEqual(self.word(), 5)
        self.assertFalse(self.e.replay.held)
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_default_transfer_replay_does_not_admit_shader_records(self):
        self.record()
        with self.assertRaisesRegex(ValueError, 'unsupported replay'):
            self.e.replay.enqueue(1, [self.f.CB])
        self.assertEqual(self.word(), 0)
        self.assertFalse(self.e.transfers.active)
        self.assertFalse(self.e.replay.held)

    def test_fill_compute_copy_order_uses_live_owned_memory(self):
        self.pipeline_code(program(add=True))
        self.f.begin()
        self.f.fill(offset=256, size=4)
        self.bind()
        self.dispatch()
        self.f.command('vkCmdCopyBuffer', commandBuffer=self.f.CB,
            srcBuffer=self.f.BUFFER, dstBuffer=self.f.BUFFER, regionCount=1,
            pRegions=[self.w.structure('VkBufferCopy', srcOffset=256, dstOffset=1024, size=4)])
        self.f.end()
        job = self.enqueue()
        self.f.drain()
        self.assertEqual(job.state, 'done')
        self.assertEqual(self.word(1024), 0x64636261 + 5)

    def test_module_layout_destruction_remains_safe_during_pending_execution(self):
        self.record()
        job = self.enqueue()
        self.f.command('vkDestroyShaderModule', device=self.w.DEVICE,
                       shaderModule=self.l.MODULE)
        self.f.command('vkDestroyPipelineLayout', device=self.w.DEVICE,
                       pipelineLayout=self.l.PL)
        self.l.destroy_layout()
        self.f.drain()
        self.assertEqual(job.state, 'done')
        self.assertEqual(self.word(), 5)

    def test_pipeline_destroy_and_descriptor_update_wait_for_retirement(self):
        self.record()
        job = self.enqueue()
        destroy = self.f.command('vkDestroyPipeline', device=self.w.DEVICE,
                                 pipeline=self.l.PIPE)
        update = self.d.write(offset=512)
        self.assertEqual(destroy.state, 'waiting')
        self.assertEqual(update.state, 'waiting')
        self.assertIn(self.l.PIPE, self.f.front.idmap)
        self.f.drain()
        destroy.advance([256, 65536])
        update.advance([256, 65536])
        self.assertEqual(destroy.state, 'done')
        self.assertEqual(update.state, 'done')
        self.assertEqual(job.state, 'done')
        self.assertEqual(self.word(), 5)
        self.assertEqual(self.word(512), 0)
        self.assertNotIn(self.l.PIPE, self.f.front.idmap)

    def test_cancellation_releases_compute_object_and_memory_leases(self):
        self.record()
        job = self.enqueue()
        self.e.transfers.cancel_context(self.f.context)
        self.assertEqual(job.state, 'cancelled')
        self.assertEqual(self.word(), 0)
        self.assertFalse(self.e.replay.held)
        self.assertEqual(self.f.owner.work_refs, 0)
        self.assertEqual(self.f.entry(self.f.CB)['state'] & 15, self.e.golden.CB_EXEC)

    def test_dynamic_offsets_follow_sorted_binding_numbers_not_supplied_order(self):
        self.dynamic_layout()
        self.f.begin()
        self.bind(offsets=(256, 512))
        self.dispatch()
        self.f.end()
        job = self.enqueue()
        self.f.drain()
        self.assertEqual(job.state, 'done')
        self.assertEqual(self.word(256), 5)
        self.assertEqual(self.word(512), 0)

    def test_dynamic_count_and_record_local_length_reject_before_writes(self):
        self.dynamic_layout()
        self.f.begin()
        self.bind(offsets=(256,))
        self.dispatch()
        self.f.end()
        with self.assertRaises(ValueError):
            self.enqueue()
        self.no_work()

    def test_partial_push_updates_preserve_other_words_and_feed_shader(self):
        self.push_pipeline()
        self.f.begin()
        self.bind()
        self.push()
        self.push((11,), offset=4)
        self.dispatch()
        self.f.end()
        job = self.enqueue()
        self.f.drain()
        self.assertEqual(job.state, 'done')
        self.assertEqual(self.word(), 11)

    def test_undefined_push_words_cannot_silently_become_zero(self):
        self.push_pipeline()
        self.f.begin()
        self.bind()
        self.push((5,))
        self.dispatch()
        self.f.end()
        with self.assertRaisesRegex(ValueError, 'undefined'):
            self.enqueue()
        self.no_work()

    def test_incompatible_push_range_identity_rejects(self):
        self.push_pipeline()
        self.l.layout(self.l.PL2, ranges=((0x20, 0, 32),))
        self.f.begin()
        self.bind()
        self.push(layout=self.l.PL2)
        self.dispatch()
        self.f.end()
        with self.assertRaisesRegex(ValueError, 'incompatible'):
            self.enqueue()
        self.no_work()

    def test_missing_descriptor_state_rejects_even_after_a_transfer_prefix(self):
        self.f.begin()
        self.f.fill(offset=256, size=4)
        self.bind(sets=False)
        self.dispatch()
        self.f.end()
        with self.assertRaisesRegex(ValueError, 'descriptor'):
            self.enqueue()
        self.no_work()

    def test_stale_pool_epoch_and_reused_buffer_reject_recorded_work(self):
        self.record()
        self.f.command('vkResetDescriptorPool', device=self.w.DEVICE,
                       descriptorPool=self.d.POOL, flags=0)
        with self.assertRaises(KeyError):
            self.enqueue()
        self.no_work()

    def test_stale_buffer_generation_is_not_redirected_by_descriptor_memory(self):
        self.record()
        self.d.buffer()
        with self.assertRaises(KeyError):
            self.enqueue()
        self.no_work()

    def test_late_memory_pin_failure_rolls_back_all_object_pins_and_cb_state(self):
        self.record()
        before = {i: entry['pins'] for i, entry in enumerate(self.f.front.ent) if entry}
        with patch.object(self.f.owner, 'pin_work', side_effect=MemoryError('late pin')):
            with self.assertRaises(MemoryError):
                self.enqueue()
        after = {i: entry['pins'] for i, entry in enumerate(self.f.front.ent) if entry}
        self.assertEqual(before, after)
        self.no_work()

    def test_secondary_owns_shader_state_and_primary_state_is_invalidated(self):
        self.f.allocate(self.SECONDARY, level=1)
        self.f.begin(self.SECONDARY)
        self.bind(self.SECONDARY)
        self.dispatch(self.SECONDARY)
        self.f.end(self.SECONDARY)
        self.f.begin()
        self.bind()
        self.f.command('vkCmdExecuteCommands', commandBuffer=self.f.CB,
                       commandBufferCount=1, pCommandBuffers=[self.SECONDARY])
        self.dispatch()
        self.f.end()
        with self.assertRaisesRegex(ValueError, 'pipeline'):
            self.enqueue()
        self.no_work()

    def test_secondary_with_own_shader_state_executes(self):
        self.f.allocate(self.SECONDARY, level=1)
        self.f.begin(self.SECONDARY)
        self.bind(self.SECONDARY)
        self.dispatch(self.SECONDARY)
        self.f.end(self.SECONDARY)
        self.f.begin()
        self.f.command('vkCmdExecuteCommands', commandBuffer=self.f.CB,
                       commandBufferCount=1, pCommandBuffers=[self.SECONDARY])
        self.f.end()
        job = self.enqueue()
        self.f.drain()
        self.assertEqual(job.state, 'done')
        self.assertEqual(self.word(), 5)

    def test_dispatch_job_budget_rejects_without_a_partial_prefix(self):
        self.f.begin()
        self.bind()
        for _ in range(17):
            self.dispatch()
        self.f.end()
        with self.assertRaisesRegex(ValueError, 'budget'):
            self.enqueue()
        self.no_work()

    def test_revalidation_catches_descriptor_update_after_operand_resolution(self):
        self.record()

        def changing(*args, **kwargs):
            result = buffer_descriptor(*args, **kwargs)
            self.d.write(offset=512)
            return result

        with patch('vn_compute_replay.buffer_descriptor', side_effect=changing):
            with self.assertRaises(KeyError):
                self.enqueue()
        self.no_work()

    def test_revalidation_catches_set_poison_without_generation_change(self):
        self.record()

        def poisoning(*args, **kwargs):
            result = buffer_descriptor(*args, **kwargs)
            self.d.write(offset=1 << 32)
            return result

        with patch('vn_compute_replay.buffer_descriptor', side_effect=poisoning):
            with self.assertRaises(KeyError):
                self.enqueue()
        self.no_work()

    def test_shader_visibility_is_checked_beyond_legacy_layout_hash(self):
        self.dynamic_layout(stages=0x10, dtype=7, bindings=(0,))
        self.record()
        with self.assertRaisesRegex(ValueError, 'visible'):
            self.enqueue()
        self.no_work()

    def test_shader_storage_class_must_match_descriptor_type(self):
        self.dynamic_layout(dtype=6, bindings=(0,))
        self.record()
        with self.assertRaisesRegex(ValueError, 'storage class'):
            self.enqueue()
        self.no_work()

    def higher_set_record(self, disturbed=False):
        code, position = list(program()), 5
        while position < len(code):
            count, opcode = code[position] >> 16, code[position] & 0xFFFF
            if opcode == 71 and code[position + 1:position + 3] == [6, 34]:
                code[position + 3] = 1
            position += count
        self.f.command('vkDestroyPipeline', device=self.w.DEVICE, pipeline=self.l.PIPE)
        self.f.command('vkDestroyPipelineLayout', device=self.w.DEVICE, pipelineLayout=self.l.PL)
        self.l.layout(sets=[self.d.LAYOUT, self.d.LAYOUT])
        self.f.command('vkDestroyShaderModule', device=self.w.DEVICE, shaderModule=self.l.MODULE)
        self.p.module(tuple(code))
        self.p.pipeline()
        self.d.copy()
        self.l.layout(self.l.PL2, ranges=((0x20, 0, 4),) if disturbed else ())
        self.f.begin()
        self.bind(sets=False)
        self.f.command('vkCmdBindDescriptorSets', commandBuffer=self.f.CB,
            pipelineBindPoint=1, layout=self.l.PL, firstSet=0, descriptorSetCount=2,
            pDescriptorSets=[self.d.SOURCE, self.d.TARGET], dynamicOffsetCount=0,
            pDynamicOffsets=[])
        self.bind(pipeline=False, layout=self.l.PL2)
        self.dispatch()
        self.f.end()

    def test_compatible_short_lower_set_bind_preserves_higher_set(self):
        self.higher_set_record()
        job = self.enqueue()
        self.f.drain()
        self.assertEqual(job.state, 'done')
        self.assertEqual(self.word(), 5)

    def test_incompatible_lower_set_bind_disturbs_higher_set(self):
        self.higher_set_record(disturbed=True)
        with self.assertRaisesRegex(ValueError, 'descriptor'):
            self.enqueue()
        self.no_work()

    def test_unused_bound_set_is_rechecked_for_late_poison(self):
        self.f.command('vkDestroyPipeline', device=self.w.DEVICE, pipeline=self.l.PIPE)
        self.f.command('vkDestroyPipelineLayout', device=self.w.DEVICE, pipelineLayout=self.l.PL)
        self.l.layout(sets=[self.d.LAYOUT, self.d.LAYOUT])
        self.p.pipeline()
        self.f.begin()
        self.bind(sets=False)
        self.f.command('vkCmdBindDescriptorSets', commandBuffer=self.f.CB,
            pipelineBindPoint=1, layout=self.l.PL, firstSet=0, descriptorSetCount=2,
            pDescriptorSets=[self.d.SOURCE, self.d.TARGET], dynamicOffsetCount=0,
            pDynamicOffsets=[])
        self.dispatch()
        self.f.end()

        def poison_unused(*args, **kwargs):
            result = buffer_descriptor(*args, **kwargs)
            self.f.command('vkUpdateDescriptorSets', device=self.w.DEVICE,
                descriptorWriteCount=1, descriptorCopyCount=0, pDescriptorCopies=[],
                pDescriptorWrites=[self.w.structure('VkWriteDescriptorSet', pNext=[],
                    dstSet=self.d.TARGET, dstBinding=0, dstArrayElement=0,
                    descriptorCount=1, descriptorType=7, pImageInfo=[],
                    pTexelBufferView=[], pBufferInfo=[self.w.structure(
                        'VkDescriptorBufferInfo', buffer=self.f.BUFFER, offset=1 << 32,
                        range=128)])])
            return result

        with patch('vn_compute_replay.buffer_descriptor', side_effect=poison_unused):
            with self.assertRaises(KeyError):
                self.enqueue()
        self.no_work()

    COND = 0x7B0000008000

    def cond_buffer(self, predicate):
        self.f.command('vkCreateBuffer', device=self.w.DEVICE,
            pBuffer=self.COND,
            pCreateInfo=self.w.structure('VkBufferCreateInfo', pNext=[],
                flags=0, size=256, usage=0x203, sharingMode=0,
                queueFamilyIndexCount=0, pQueueFamilyIndices=[]))
        self.f.command('vkBindBufferMemory', device=self.w.DEVICE,
            buffer=self.COND, memory=self.w.MEMORY, memoryOffset=4608)
        self.f.state.aperture.write(
            self.f.owner.base + 4608, predicate.to_bytes(4, 'little'))

    def gated_dispatch(self, predicate):
        self.cond_buffer(predicate)
        self.f.begin()
        self.bind()
        self.f.command('vkCmdBeginConditionalRenderingEXT',
            commandBuffer=self.f.CB,
            pConditionalRenderingBegin=self.w.structure(
                'VkConditionalRenderingBeginInfoEXT', pNext=[],
                buffer=self.COND, offset=0, flags=0))
        self.dispatch()
        self.f.command('vkCmdEndConditionalRenderingEXT',
                       commandBuffer=self.f.CB)
        self.f.end()

    def test_conditional_skips_dispatch_when_predicate_zero(self):
        self.gated_dispatch(0)
        self.e.replay.enqueue(1, [self.f.CB], compute=True)
        self.f.drain()
        self.no_work()

    def test_conditional_runs_dispatch_when_predicate_nonzero(self):
        self.gated_dispatch(1)
        self.e.replay.enqueue(1, [self.f.CB], compute=True)
        self.f.drain()
        self.assertEqual(self.word(), 5)


if __name__ == '__main__':
    unittest.main()
