# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Fixed buffer descriptor arrays, dynamic elements and readonly alias safety."""
import unittest
from unittest.mock import patch

import test_vn_compute_submit as wire_fixture
from test_vn_compute import program
from vn_compute import Compute, ShaderBinding


def array_program(*, count=2, selected=1, uniform=False):
    source, result, position = program(), list(program()[:5]), 5
    storage = 2 if uniform else 12

    def emit(opcode, *operands):
        result.extend(((len(operands) + 1) << 16 | opcode, *operands))

    while position < len(source):
        length, opcode = source[position] >> 16, source[position] & 0xFFFF
        operands = source[position + 1:position + length]
        if opcode == 32 and operands[0] == 4:
            emit(43, 3, 22, count)
            emit(43, 3, 23, selected)
            emit(28, 21, 17, 22)
            emit(32, 4, storage, 21)
        elif opcode == 32 and operands[0] == 8:
            emit(32, 8, storage, 3)
        elif opcode == 30 and operands[0] == 17 and uniform:
            emit(30, 17, 3)
        elif opcode == 59 and operands[1] == 6:
            emit(59, 4, 6, storage)
        elif opcode == 65:
            emit(65, *operands[:3], 23, *operands[3:4] if uniform else operands[3:])
        elif opcode == 62 and uniform:
            emit(61, 3, 24, 12)
        else:
            result.extend(source[position:position + length])
        position += length
    return tuple(result)


class BufferArrayTests(unittest.TestCase):
    def setUp(self):
        self.r = wire_fixture.scene()
        self.f, self.e, self.w, self.d = self.r.f, self.r.e, self.r.w, self.r.d
        self.configure()

    def configure(self, *, dtype=7, count=2, uniform=False):
        self.f.command('vkDestroyPipeline', device=self.w.DEVICE, pipeline=self.r.l.PIPE)
        self.f.command('vkDestroyPipelineLayout', device=self.w.DEVICE, pipelineLayout=self.r.l.PL)
        self.f.command('vkFreeDescriptorSets', device=self.w.DEVICE, descriptorPool=self.d.POOL,
            descriptorSetCount=2, pDescriptorSets=[self.d.SOURCE, self.d.TARGET])
        self.f.command('vkDestroyDescriptorPool', device=self.w.DEVICE, descriptorPool=self.d.POOL)
        self.f.command('vkDestroyDescriptorSetLayout', device=self.w.DEVICE, descriptorSetLayout=self.d.LAYOUT)
        self.d.sets(dtype=dtype)
        self.r.l.layout()
        self.f.command('vkDestroyShaderModule', device=self.w.DEVICE, shaderModule=self.r.l.MODULE)
        self.r.p.module(array_program(count=count, uniform=uniform))
        self.r.p.pipeline()

    def write(self, count=2):
        self.f.command('vkUpdateDescriptorSets', device=self.w.DEVICE,
            descriptorWriteCount=1, descriptorCopyCount=0, pDescriptorCopies=[],
            pDescriptorWrites=[self.w.structure('VkWriteDescriptorSet', pNext=[],
                dstSet=self.d.SOURCE, dstBinding=0, dstArrayElement=0,
                descriptorCount=count, descriptorType=self.d.dtype, pImageInfo=[],
                pTexelBufferView=[], pBufferInfo=[self.w.structure('VkDescriptorBufferInfo',
                    buffer=self.f.BUFFER, offset=offset, range=128)
                    for offset in (256, 512)[:count]])])

    def record(self, offsets=()):
        self.f.begin()
        self.r.bind(offsets=offsets)
        self.r.dispatch()
        self.f.end()

    def test_wire_dispatch_selects_second_descriptor_element(self):
        self.write()
        self.record()
        self.f.service.execute(1, wire_fixture.submit_packet(self.w, [self.f.CB]))
        job = next(iter(self.e.submissions.pending.values()))
        self.assertEqual([b.element for b in job.operations[0].bindings], [0, 1])
        self.f.drain()
        self.assertEqual((self.r.word(256), self.r.word(512)), (0, 5))
        self.assertTrue(self.f.front.fence_sig)

    def test_dynamic_offsets_are_applied_per_array_element(self):
        self.configure(dtype=9)
        self.write()
        self.record((256, 512))
        job = self.r.enqueue()
        self.f.drain()
        self.assertEqual(job.state, 'done')
        self.assertEqual((self.r.word(512), self.r.word(1024)), (0, 5))

    def test_uniform_array_load_uses_second_readonly_record(self):
        self.configure(dtype=6, uniform=True)
        self.write()
        self.f.state.aperture.write(self.f.owner.base + 512, (41).to_bytes(4, 'little'))
        self.record()
        original, reads = self.f.state.aperture.read, []
        target = self.f.owner.base + 512

        def read(address, size):
            if (address, size) == (target, 4):
                reads.append(original(address, size))
            return original(address, size)

        job = self.r.enqueue()
        with patch.object(self.f.state.aperture, 'read', read):
            self.f.drain()
        self.assertEqual((job.state, reads), ('done', [(41).to_bytes(4, 'little')]))

    def test_missing_second_element_refuses_before_object_or_memory_leases(self):
        self.write(count=1)
        self.record()
        with self.assertRaises((ValueError, KeyError)):
            self.r.enqueue()
        self.r.no_work()

    def test_shader_array_count_cannot_exceed_layout_or_row_budget(self):
        for count in (3, 17):
            self.configure(count=count)
            self.write()
            self.record()
            with self.assertRaises(ValueError):
                self.r.enqueue()
            self.r.no_work()

    def test_interleaved_internal_rows_cannot_overwrite_another_binding(self):
        owner = self.f.owner
        op = Compute(array_program(), (ShaderBinding(owner, 256, 128),
            ShaderBinding(owner, 768, 128, binding=1),
            ShaderBinding(owner, 512, 128, element=1)))
        job = self.e.transfers.enqueue(self.f.context, [op])
        model = job.runtimes[0].model
        self.assertEqual(model.desc_rec(0, 0, 1)[0], owner.base + 512)
        self.assertEqual(model.desc_rec(0, 1, 0)[0], owner.base + 768)
        self.f.drain()
        self.assertEqual((job.state, self.r.word(512), self.r.word(768)), ('done', 5, 0))

    def test_stale_second_element_is_rejected_when_first_remains_live(self):
        other = 0x4001C000101C
        self.f.command('vkCreateBuffer', device=self.w.DEVICE, pBuffer=other,
            pCreateInfo=self.w.structure('VkBufferCreateInfo', pNext=[], flags=0,
                size=256, usage=0x20, sharingMode=0, queueFamilyIndexCount=0,
                pQueueFamilyIndices=[]))
        self.f.command('vkBindBufferMemory', device=self.w.DEVICE, buffer=other,
                       memory=self.w.MEMORY, memoryOffset=1024)
        self.write(count=1)
        self.f.command('vkUpdateDescriptorSets', device=self.w.DEVICE,
            descriptorWriteCount=1, descriptorCopyCount=0, pDescriptorCopies=[],
            pDescriptorWrites=[self.w.structure('VkWriteDescriptorSet', pNext=[],
                dstSet=self.d.SOURCE, dstBinding=0, dstArrayElement=1,
                descriptorCount=1, descriptorType=7, pImageInfo=[], pTexelBufferView=[],
                pBufferInfo=[self.w.structure('VkDescriptorBufferInfo',
                    buffer=other, offset=0, range=128)])])
        self.record()
        self.f.command('vkDestroyBuffer', device=self.w.DEVICE, buffer=other)
        with self.assertRaises((KeyError, ValueError)):
            self.r.enqueue()
        self.assertEqual(self.f.entry(self.f.BUFFER)['pins'], 0)
        self.r.no_work()

    def test_readonly_descriptor_cannot_borrow_writable_alias_permission(self):
        owner = self.f.owner
        op = Compute(program(), (ShaderBinding(owner, 0, 4, kind=6),
                                 ShaderBinding(owner, 0, 4, binding=1, kind=7)))
        job = self.e.transfers.enqueue(self.f.context, [op])
        self.f.drain()
        self.assertEqual((job.state, self.r.word(0)), ('faulted', 0))
        self.assertIn('DESCKIND', job.error)

    def test_cancelled_array_dispatch_releases_deduplicated_backing(self):
        self.write()
        self.record()
        job = self.r.enqueue()
        self.assertEqual((len(job.pins), self.f.owner.work_refs), (1, 1))
        self.e.transfers.cancel_context(self.f.context)
        self.assertEqual(job.state, 'cancelled')
        self.r.no_work()

    def test_descriptor_copy_propagates_both_element_sources(self):
        self.write()
        self.f.command('vkUpdateDescriptorSets', device=self.w.DEVICE,
            descriptorWriteCount=0, pDescriptorWrites=[], descriptorCopyCount=1,
            pDescriptorCopies=[self.w.structure('VkCopyDescriptorSet', pNext=[],
                srcSet=self.d.SOURCE, srcBinding=0, srcArrayElement=0,
                dstSet=self.d.TARGET, dstBinding=0, dstArrayElement=0, descriptorCount=2)])
        self.f.begin()
        self.r.bind(sets=False)
        self.f.command('vkCmdBindDescriptorSets', commandBuffer=self.f.CB,
            pipelineBindPoint=1, layout=self.r.l.PL, firstSet=0, descriptorSetCount=1,
            pDescriptorSets=[self.d.TARGET], dynamicOffsetCount=0, pDynamicOffsets=[])
        self.r.dispatch()
        self.f.end()
        self.r.enqueue()
        self.f.drain()
        self.assertEqual(self.r.word(512), 5)


if __name__ == '__main__':
    unittest.main()
