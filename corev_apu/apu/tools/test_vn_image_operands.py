# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Native image/view/sampler provenance without shader-image submission."""
import unittest
from unittest.mock import patch

import test_vn_descriptor_operands as descriptor_fixture
import test_vn_native_layouts as layout_fixture
from test_vn_compute import program
from vn_compute import Compute
from vn_image_operands import image_descriptor


class ImageOperandTests(unittest.TestCase):
    IMAGE, VIEW = 0x700000007000, 0x700020007002
    SAMPLER = layout_fixture.LayoutTests.SAMPLER
    DSL2, SAMPLER2 = 0x700030007003, 0x700040007004

    def setUp(self):
        self.d = descriptor_fixture.DescriptorTests()
        self.d.setUp()
        self.f, self.e, self.w = self.d.f, self.d.e, self.d.w
        self.image()
        self.view()
        self.sampler()
        self.sets()

    def image(self, *, mips=1, layers=1, initial=1):
        self.f.command('vkCreateImage', device=self.w.DEVICE, pImage=self.IMAGE,
            pCreateInfo=self.w.structure('VkImageCreateInfo', pNext=[], flags=0,
                imageType=1, format=37, extent=self.w.structure(
                    'VkExtent3D', width=8, height=4, depth=1),
                mipLevels=mips, arrayLayers=layers, samples=1, tiling=0, usage=15,
                sharingMode=0, queueFamilyIndexCount=0, pQueueFamilyIndices=[],
                initialLayout=initial))
        self.f.command('vkBindImageMemory', device=self.w.DEVICE, image=self.IMAGE,
                       memory=self.w.MEMORY, memoryOffset=4096)

    def view(self, *, mip=0, layer=0):
        self.f.command('vkCreateImageView', device=self.w.DEVICE, pView=self.VIEW,
            pCreateInfo=self.w.structure('VkImageViewCreateInfo', pNext=[], flags=0,
                image=self.IMAGE, viewType=1, format=37,
                components=self.w.structure('VkComponentMapping', r=0, g=0, b=0, a=0),
                subresourceRange=self.w.structure('VkImageSubresourceRange', aspectMask=1,
                    baseMipLevel=mip, levelCount=1, baseArrayLayer=layer, layerCount=1)))

    def sampler(self, *, handle=None, address=0):
        helper = layout_fixture.LayoutTests()
        helper.f, helper.w, helper.SAMPLER = self.f, self.w, handle or self.SAMPLER
        helper.sampler(address)

    def layout(self, handle, dtype, immutable=False, sampler=None):
        self.f.command('vkCreateDescriptorSetLayout', device=self.w.DEVICE, pSetLayout=handle,
            pCreateInfo=self.w.structure('VkDescriptorSetLayoutCreateInfo', pNext=[], flags=0,
                bindingCount=1, pBindings=[self.w.structure('VkDescriptorSetLayoutBinding',
                    binding=0, descriptorType=dtype, descriptorCount=2, stageFlags=0x20,
                    pImmutableSamplers=[sampler or self.SAMPLER] * 2 if immutable else [])]))

    def sets(self, dtype=3, immutable=False):
        if self.d.SOURCE in self.f.front.idmap:
            self.f.command('vkFreeDescriptorSets', device=self.w.DEVICE,
                descriptorPool=self.d.POOL, descriptorSetCount=2,
                pDescriptorSets=[self.d.SOURCE, self.d.TARGET])
            self.f.command('vkDestroyDescriptorPool', device=self.w.DEVICE, descriptorPool=self.d.POOL)
            self.f.command('vkDestroyDescriptorSetLayout', device=self.w.DEVICE,
                           descriptorSetLayout=self.d.LAYOUT)
        self.dtype = dtype
        self.layout(self.d.LAYOUT, dtype, immutable)
        self.f.command('vkCreateDescriptorPool', device=self.w.DEVICE, pDescriptorPool=self.d.POOL,
            pCreateInfo=self.w.structure('VkDescriptorPoolCreateInfo', pNext=[], flags=1,
                maxSets=2, poolSizeCount=1, pPoolSizes=[self.w.structure(
                    'VkDescriptorPoolSize', type=dtype, descriptorCount=4)]))
        self.f.command('vkAllocateDescriptorSets', device=self.w.DEVICE,
            pDescriptorSets=[self.d.SOURCE, self.d.TARGET], pAllocateInfo=self.w.structure(
                'VkDescriptorSetAllocateInfo', pNext=[], descriptorPool=self.d.POOL,
                descriptorSetCount=2, pSetLayouts=[self.d.LAYOUT, self.d.LAYOUT]))

    def write(self, *, layout=1, sampler=None):
        self.f.command('vkUpdateDescriptorSets', device=self.w.DEVICE,
            descriptorWriteCount=1, descriptorCopyCount=0, pDescriptorCopies=[],
            pDescriptorWrites=[self.w.structure('VkWriteDescriptorSet', pNext=[],
                dstSet=self.d.SOURCE, dstBinding=0, dstArrayElement=0, descriptorCount=1,
                descriptorType=self.dtype, pBufferInfo=[], pTexelBufferView=[],
                pImageInfo=[self.w.structure('VkDescriptorImageInfo', imageView=self.VIEW,
                    sampler=self.SAMPLER if sampler is None else sampler, imageLayout=layout)])])

    def operand(self, descriptor_set=None):
        return image_descriptor(self.e, 1, descriptor_set or self.d.SOURCE, 0)

    def target_layout(self, immutable=False, sampler=None):
        self.f.command('vkFreeDescriptorSets', device=self.w.DEVICE,
            descriptorPool=self.d.POOL, descriptorSetCount=1, pDescriptorSets=[self.d.TARGET])
        self.layout(self.DSL2, self.dtype, immutable, sampler)
        self.f.command('vkAllocateDescriptorSets', device=self.w.DEVICE,
            pDescriptorSets=[self.d.TARGET], pAllocateInfo=self.w.structure(
                'VkDescriptorSetAllocateInfo', pNext=[], descriptorPool=self.d.POOL,
                descriptorSetCount=1, pSetLayouts=[self.DSL2]))

    def test_owned_storage_image_resolves_without_acquiring_leases(self):
        self.write()
        operand = self.operand()
        binding = operand.binding
        self.assertIs(binding.owner, self.f.owner)
        self.assertEqual((binding.offset, binding.size, binding.width, binding.height,
                          binding.pitch, binding.kind), (4096, 256, 8, 4, 64, 3))
        self.assertEqual(len(operand.references), 6)
        self.assertEqual(self.f.owner.work_refs, 0)
        self.assertFalse(any(entry['pins'] for entry in self.f.front.ent if entry))

    def test_sampled_image_shader_read_layout_and_combined_sampler(self):
        self.f.command('vkDestroyImageView', device=self.w.DEVICE, imageView=self.VIEW)
        self.f.command('vkDestroyImage', device=self.w.DEVICE, image=self.IMAGE)
        self.image(initial=5)
        self.view()
        for dtype in (2, 1):
            self.sets(dtype)
            self.write(layout=5)
            operand = self.operand()
            self.assertEqual(operand.binding.kind, dtype)
            self.assertEqual(len(operand.references), 7 if dtype == 1 else 6)

    def test_descriptor_layout_must_match_tracked_image_layout(self):
        self.sets(1)
        self.write(layout=5)
        with self.assertRaises(ValueError):
            self.operand()
        self.f.command('vkDestroyImageView', device=self.w.DEVICE, imageView=self.VIEW)
        self.f.command('vkDestroyImage', device=self.w.DEVICE, image=self.IMAGE)
        self.image(initial=5)
        self.view()
        self.write(layout=5)
        self.assertEqual(self.operand().binding.kind, 1)

    def test_view_reuse_does_not_redirect_descriptor(self):
        self.write()
        self.f.command('vkDestroyImageView', device=self.w.DEVICE, imageView=self.VIEW)
        self.view()
        with self.assertRaises(KeyError):
            self.operand()

    def test_image_reuse_under_old_view_poisons_update(self):
        self.f.command('vkDestroyImage', device=self.w.DEVICE, image=self.IMAGE)
        self.image()
        self.write()
        with self.assertRaises(KeyError):
            self.operand()
        self.assertTrue(self.f.entry(self.d.SOURCE)['aux'] & (1 << 31))

    def test_sampler_generation_reuse_is_rejected(self):
        self.sets(1)
        self.write()
        self.f.command('vkDestroySampler', device=self.w.DEVICE, sampler=self.SAMPLER)
        self.sampler(address=1)
        with self.assertRaises(KeyError):
            self.operand()

    def test_immutable_sampler_survives_sampler_and_layout_reuse(self):
        self.sets(1, immutable=True)
        original = self.f.entry(self.SAMPLER)['aux']
        self.write(sampler=0)
        self.f.command('vkDestroySampler', device=self.w.DEVICE, sampler=self.SAMPLER)
        self.sampler(address=1)
        self.f.command('vkDestroyDescriptorSetLayout', device=self.w.DEVICE,
                       descriptorSetLayout=self.d.LAYOUT)
        self.layout(self.d.LAYOUT, 1, immutable=True)
        self.write(sampler=0)
        operand = self.operand()
        self.assertEqual(operand.binding.sampler, (original & 0xFFFFFFFF, original >> 32))
        self.assertNotIn(self.e.golden.KIND['VkSampler'], [kind for _, kind in operand.references])

    def test_copy_into_immutable_destination_replaces_sampler_provenance(self):
        self.sets(1)
        self.write()
        self.sampler(handle=self.SAMPLER2, address=1)
        value = self.f.entry(self.SAMPLER2)['aux']
        self.target_layout(immutable=True, sampler=self.SAMPLER2)
        self.d.copy()
        self.f.command('vkDestroySampler', device=self.w.DEVICE, sampler=self.SAMPLER)
        binding = self.operand(self.d.TARGET).binding
        self.assertEqual(binding.sampler, (value & 0xFFFFFFFF, value >> 32))

    def test_immutable_sampler_only_copy_keeps_value_without_live_sampler(self):
        self.sets(0, immutable=True)
        value = self.f.entry(self.SAMPLER)['aux']
        self.f.command('vkDestroySampler', device=self.w.DEVICE, sampler=self.SAMPLER)
        self.target_layout()
        self.d.copy()
        operand = self.operand(self.d.TARGET)
        self.assertEqual(operand.binding.sampler, (value & 0xFFFFFFFF, value >> 32))
        self.assertIsNone(operand.binding.owner)
        self.assertEqual(len(operand.references), 3)

    def test_image_descriptor_copy_survives_source_set_free(self):
        self.write()
        self.d.copy()
        self.f.command('vkFreeDescriptorSets', device=self.w.DEVICE,
            descriptorPool=self.d.POOL, descriptorSetCount=1, pDescriptorSets=[self.d.SOURCE])
        self.assertEqual(self.operand(self.d.TARGET).binding.offset, 4096)

    def test_single_mip_layer_view_uses_owned_subresource_extent(self):
        self.f.command('vkDestroyImageView', device=self.w.DEVICE, imageView=self.VIEW)
        self.f.command('vkDestroyImage', device=self.w.DEVICE, image=self.IMAGE)
        self.image(mips=2, layers=2)
        self.view(mip=1, layer=1)
        self.write()
        binding = self.operand().binding
        self.assertEqual((binding.offset, binding.size, binding.width, binding.height),
                         (4736, 128, 4, 2))

    def test_storage_image_requires_general_descriptor_layout(self):
        self.write(layout=5)
        with self.assertRaises(ValueError):
            self.operand()

    def test_image_rebinding_invalidates_captured_provenance(self):
        self.write()
        self.f.command('vkBindImageMemory', device=self.w.DEVICE, image=self.IMAGE,
                       memory=self.w.MEMORY, memoryOffset=4352)
        with self.assertRaises(KeyError):
            self.operand()

    def test_descriptor_byte_tampering_is_rejected(self):
        self.write()
        self.f.state.aperture.write(self.d.address() + 12, b'\xff' * 4)
        with self.assertRaises(ValueError):
            self.operand()

    def test_mutation_during_descriptor_read_is_rechecked(self):
        self.write()
        original = self.f.front.apr64

        def read(address):
            value = original(address)
            if address == self.d.address():
                self.f.entry(self.IMAGE)['bind_off'] += 64
            return value

        with patch.object(self.f.front, 'apr64', read), self.assertRaises(KeyError):
            self.operand()
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_pool_reset_rejects_old_image_sets(self):
        self.write()
        self.f.command('vkResetDescriptorPool', device=self.w.DEVICE,
                       descriptorPool=self.d.POOL, flags=0)
        with self.assertRaises(KeyError):
            self.operand()

    def test_resolution_does_not_admit_image_bindings_into_shader_executor(self):
        self.write()
        binding = self.operand().binding
        with self.assertRaises(ValueError):
            self.e.transfers.enqueue(self.f.context, [Compute(program(), (binding,))])
        self.assertEqual(self.f.owner.work_refs, 0)


if __name__ == '__main__':
    unittest.main()
