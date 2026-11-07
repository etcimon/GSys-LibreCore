# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Wire descriptor provenance, copy propagation, logical extents and reuse."""
import unittest
from unittest.mock import patch

import test_vn_replay as replay_fixture
from test_vn_compute import program
from vn_compute import Compute
from vn_descriptor_operands import buffer_descriptor


class DescriptorTests(unittest.TestCase):
    LAYOUT, POOL, SOURCE, TARGET = (0x400080001008, 0x400090001009,
                                  0x4000A000100A, 0x4000B000100B)

    def setUp(self):
        self.f = replay_fixture.ReplayTests()
        self.f.setUp()
        self.e, self.w, self.front = self.f.engine, self.f.wire, self.f.front
        self.buffer()

    def buffer(self):
        self.f.command('vkDestroyBuffer', device=self.w.DEVICE, buffer=self.f.BUFFER)
        self.f.command('vkCreateBuffer', device=self.w.DEVICE, pBuffer=self.f.BUFFER,
            pCreateInfo=self.w.structure('VkBufferCreateInfo', pNext=[], flags=0,
                size=4096, usage=0x33, sharingMode=0, queueFamilyIndexCount=0,
                pQueueFamilyIndices=[]))
        self.f.command('vkBindBufferMemory', device=self.w.DEVICE, buffer=self.f.BUFFER,
                       memory=self.w.MEMORY, memoryOffset=0)

    def sets(self, dtype=7):
        self.dtype = dtype
        self.f.command('vkCreateDescriptorSetLayout', device=self.w.DEVICE,
            pSetLayout=self.LAYOUT, pCreateInfo=self.w.structure(
                'VkDescriptorSetLayoutCreateInfo', pNext=[], flags=0, bindingCount=1,
                pBindings=[self.w.structure('VkDescriptorSetLayoutBinding',
                    binding=0, descriptorType=dtype, descriptorCount=2,
                    stageFlags=0x20, pImmutableSamplers=[])]))
        self.f.command('vkCreateDescriptorPool', device=self.w.DEVICE,
            pDescriptorPool=self.POOL, pCreateInfo=self.w.structure(
                'VkDescriptorPoolCreateInfo', pNext=[], flags=1, maxSets=2,
                poolSizeCount=1, pPoolSizes=[self.w.structure(
                    'VkDescriptorPoolSize', type=dtype, descriptorCount=4)]))
        self.f.command('vkAllocateDescriptorSets', device=self.w.DEVICE,
            pDescriptorSets=[self.SOURCE, self.TARGET], pAllocateInfo=self.w.structure(
                'VkDescriptorSetAllocateInfo', pNext=[], descriptorPool=self.POOL,
                descriptorSetCount=2, pSetLayouts=[self.LAYOUT, self.LAYOUT]))

    def write(self, offset=256, size=128):
        return self.f.command('vkUpdateDescriptorSets', device=self.w.DEVICE,
            descriptorWriteCount=1, descriptorCopyCount=0, pDescriptorCopies=[],
            pDescriptorWrites=[self.w.structure('VkWriteDescriptorSet', pNext=[],
                dstSet=self.SOURCE, dstBinding=0, dstArrayElement=0,
                descriptorCount=1, descriptorType=self.dtype, pImageInfo=[],
                pTexelBufferView=[], pBufferInfo=[self.w.structure(
                    'VkDescriptorBufferInfo', buffer=self.f.BUFFER, offset=offset,
                    range=size)])])

    def copy(self, destination=TARGET):
        self.f.command('vkUpdateDescriptorSets', device=self.w.DEVICE,
            descriptorWriteCount=0, pDescriptorWrites=[], descriptorCopyCount=1,
            pDescriptorCopies=[self.w.structure('VkCopyDescriptorSet', pNext=[],
                srcSet=self.SOURCE, srcBinding=0, srcArrayElement=0,
                dstSet=destination, dstBinding=0, dstArrayElement=0, descriptorCount=1)])

    def operand(self, descriptor_set=None, **kwargs):
        return buffer_descriptor(self.e, 1, descriptor_set or self.SOURCE, 0, **kwargs)

    def address(self, descriptor_set=None):
        entry = self.f.entry(descriptor_set or self.SOURCE)
        return (entry['aux'] & 0x1FFFFFF) << 2

    def test_real_descriptor_resolves_buffer_memory_pool_layout_generations(self):
        self.sets()
        self.write()
        operand = self.operand()
        self.assertEqual(len(operand.references), 5)
        self.assertEqual((operand.binding.offset, operand.binding.size,
                          operand.binding.kind), (256, 128, 7))
        job = self.e.transfers.enqueue(self.f.context, [Compute(program(), (operand.binding,))])
        self.f.drain()
        self.assertEqual(job.state, 'done')
        self.assertEqual(self.f.state.aperture.read(self.f.owner.base + 256, 4),
                         (5).to_bytes(4, 'little'))

    def test_copy_preserves_originating_buffer_generation(self):
        self.sets()
        self.write()
        self.copy()
        self.assertEqual(self.operand().binding, self.operand(self.TARGET).binding)
        self.buffer()
        with self.assertRaises(KeyError):
            self.operand(self.TARGET)

    def test_reused_wire_id_cannot_redirect_unchanged_memory_record(self):
        self.sets()
        self.write()
        old_bytes = self.f.state.aperture.read(self.address(), 32)
        self.buffer()
        self.assertEqual(self.f.state.aperture.read(self.address(), 32), old_bytes)
        with self.assertRaises(KeyError):
            self.operand()
        self.write()
        self.assertEqual(self.operand().binding.owner, self.f.owner)

    def test_buffer_rebinding_invalidates_descriptor_provenance(self):
        self.sets()
        self.write()
        self.f.command('vkBindBufferMemory', device=self.w.DEVICE, buffer=self.f.BUFFER,
                       memory=self.w.MEMORY, memoryOffset=256)
        with self.assertRaises(KeyError):
            self.operand()

    def test_dynamic_offset_checks_logical_buffer_not_page_rounded_memory(self):
        self.sets(dtype=9)
        self.write()
        self.assertEqual(self.operand(dynamic_offset=256).binding.offset, 512)
        for offset in (1, 3840, 1 << 64):
            with self.assertRaises(ValueError):
                self.operand(dynamic_offset=offset)

    def test_whole_size_dynamic_overflow_and_non_dynamic_offset_reject(self):
        self.sets(dtype=9)
        self.write(size=(1 << 64) - 1)
        self.assertEqual(self.operand().binding.size, 3840)
        with self.assertRaises(ValueError):
            self.operand(dynamic_offset=256)

    def test_unwritten_alignment_and_non_dynamic_fail_before_leases(self):
        self.sets()
        with self.assertRaises(KeyError):
            self.operand()
        self.write(offset=128)
        with self.assertRaises(ValueError):
            self.operand()
        self.write()
        with self.assertRaises(ValueError):
            self.operand(dynamic_offset=256)
        with self.assertRaises(KeyError):
            self.operand(element=1)
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_front_write_invalidates_and_raw_tamper_cannot_forge_provenance(self):
        self.sets()
        self.write()
        address = self.address()
        self.front.apw32({'apw': []}, address + 12, 0)
        with self.assertRaises(KeyError):
            self.operand()
        self.write()
        self.f.state.aperture.write(address + 4, (256).to_bytes(4, 'little'))
        with self.assertRaises(ValueError):
            self.operand()

    def test_pool_reset_rejects_old_epoch(self):
        self.sets()
        self.write()
        self.f.command('vkResetDescriptorPool', device=self.w.DEVICE,
                       descriptorPool=self.POOL, flags=0)
        with self.assertRaises(KeyError):
            self.operand()

    def test_sidecar_does_not_change_packed_record_bytes(self):
        self.sets()
        self.front.descriptor_sources = None
        self.write()
        old = self.f.state.aperture.read(self.address(), 32)
        self.front.descriptor_sources = {}
        self.write()
        self.assertEqual(self.f.state.aperture.read(self.address(), 32), old)
        self.assertEqual(self.operand().binding.size, 128)

    def test_copy_from_unprovenanced_source_clears_destination_metadata(self):
        self.sets()
        self.write()
        self.copy()
        self.front.apw32({'apw': []}, self.address() + 12, 0)
        self.copy()
        with self.assertRaises(KeyError):
            self.operand(self.TARGET)

    def test_resolution_detects_update_during_descriptor_read(self):
        self.sets()
        self.write()
        original = self.front.apr64
        changed = False

        def updating_read(address):
            nonlocal changed
            value = original(address)
            if not changed:
                changed = True
                self.write(offset=512)
            return value

        with patch.object(self.front, 'apr64', side_effect=updating_read):
            with self.assertRaises((ValueError, KeyError)):
                self.operand()
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_usage_and_cross_device_binding_reject(self):
        self.sets()
        self.write()
        entry = self.f.entry(self.f.BUFFER)
        entry['native_usage'] = 3
        with self.assertRaises(ValueError):
            self.operand()
        entry['native_usage'] = 0x33
        entry['parent'] = -1
        with self.assertRaises(ValueError):
            self.operand()


if __name__ == '__main__':
    unittest.main()
