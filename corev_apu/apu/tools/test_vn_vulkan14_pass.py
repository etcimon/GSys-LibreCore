#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Regression checks for the Vulkan 1.4 large-pass grouped simplifications."""
import sys
import tomllib
import unittest
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOLS))
sys.path.insert(0, str(TOOLS / 'shader'))

import gen_fmt_table  # noqa: E402
import gen_vn_tables as gvt  # noqa: E402
import sh_opcodes  # noqa: E402
import spirv_model  # noqa: E402
import spirv_scan  # noqa: E402
import vn_golden  # noqa: E402


class Vulkan14LargePassTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.profile = tomllib.loads(
            (TOOLS / 'vn_device_profile.toml').read_text(encoding='utf-8'))
        cls.model = gvt.Model(cls.profile)
        cls.names = cls.model.read_command_set(TOOLS / 'vn_command_set.txt')
        cls.unfit = cls.model.run(cls.names)
        cls.asm = cls.model.assemble()

    def test_profile_audit_passes_at_vulkan_1_4(self):
        audit = gvt.audit_profile(self.profile)
        self.assertEqual(audit['apiVersion'], '1.4.0')
        self.assertEqual(audit['status'], 'pass')
        self.assertEqual(audit['findings'], [])
        self.assertGreaterEqual(audit['checkedRules'], 88)

    def test_all_vulkan_1_4_commands_build_cleanly(self):
        self.assertEqual(self.unfit, {})
        self.assertGreaterEqual(len(self.model.cmd_progs), 234)
        for cmd in (
            'vkCmdSetCullMode', 'vkCmdSetFrontFace', 'vkCmdSetPrimitiveTopology',
            'vkCmdSetViewportWithCount', 'vkCmdSetScissorWithCount',
            'vkCmdBindVertexBuffers2', 'vkCmdBindIndexBuffer2',
            'vkCmdSetLineStipple', 'vkCmdBeginRendering', 'vkCmdEndRendering',
            'vkCmdSetRenderingAttachmentLocations',
            'vkCmdPipelineBarrier2', 'vkQueueSubmit2',
            'vkCmdCopyBuffer2', 'vkCmdCopyImage2', 'vkCmdBlitImage2',
            'vkCmdResolveImage2', 'vkResetQueryPool',
            'vkGetSemaphoreCounterValue', 'vkSignalSemaphore', 'vkWaitSemaphores',
            'vkGetBufferDeviceAddress', 'vkCmdDrawIndirectCount',
            'vkCmdDrawIndexedIndirectCount', 'vkCmdPushDescriptorSet',
            'vkCmdPushDescriptorSet2', 'vkCmdPushConstants2',
            'vkCmdBindDescriptorSets2', 'vkGetDeviceBufferMemoryRequirements',
            'vkGetDeviceImageMemoryRequirements', 'vkUnmapMemory2',
            'vkTransitionImageLayout', 'vkCreatePrivateDataSlot',
        ):
            self.assertIn(cmd, self.model.cmd_progs)

    def test_vulkan_1_1_to_1_4_feature_and_property_rollups_non_zero(self):
        for nm in ('VkPhysicalDeviceVulkan11Features',
                   'VkPhysicalDeviceVulkan12Features',
                   'VkPhysicalDeviceVulkan13Features',
                   'VkPhysicalDeviceVulkan14Features',
                   'VkPhysicalDeviceVulkan11Properties',
                   'VkPhysicalDeviceVulkan12Properties',
                   'VkPhysicalDeviceVulkan13Properties',
                   'VkPhysicalDeviceVulkan14Properties'):
            ty = self.model.reg.type_table[nm]
            words = self.model.profile_words(ty)
            self.assertIsNotNone(words, nm)
            self.assertTrue(any(w != 0 for w in words), f'{nm} unexpectedly all-zero')

    def test_format_table_audit_clean(self):
        rows = gen_fmt_table.load()
        self.assertEqual(gen_fmt_table.audit_profile(rows), 0)
        names, _, bpp, attr = self.model.img_fmt_tables()
        self.assertGreaterEqual(len(names), 40)
        self.assertEqual(len(bpp), 64)
        self.assertEqual(len(attr), 64)

    def test_shader_opcodes_capabilities_and_mirror_clamp_to_edge(self):
        for opc in (113, 114, 117, 120, 333, 339, 345, 349, 4431, 5630, 5631):
            self.assertIn(opc, sh_opcodes.ACCEPT)
        for cap in (22, 39, 53, 61, 67, 4427, 4433, 4448, 5345, 5347, 5629, 6026):
            self.assertIn(cap, spirv_scan.CAP_OK)
        self.assertEqual(spirv_scan.MAX_LOCAL, 256)
        self.assertEqual(spirv_model.twrap(-1, 8, 4), (0, 0))
        self.assertEqual(spirv_model.twrap(-2, 8, 4), (0, 1))
        self.assertEqual(spirv_model.twrap(-99, 8, 4), (0, 7))
        self.assertEqual(spirv_model.twrap(99, 8, 4), (0, 7))
        self.assertEqual(vn_golden.GP_PAY_WORDS, 70)


if __name__ == '__main__':
    unittest.main()
