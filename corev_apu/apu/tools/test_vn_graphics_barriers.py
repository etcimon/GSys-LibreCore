# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Graphics-scope pipeline barriers: draw stages, attachment accesses, layouts."""
import unittest

import test_vn_images as image_fixture

# VkPipelineStageFlagBits subset admitted for graphics draws
TOP, DRAW_IND, VERT_IN, VERT, FRAG = 0x1, 0x2, 0x4, 0x8, 0x80
EFRAG, LFRAG, CATT_OUT = 0x100, 0x200, 0x400
XFER, BOT, HOST, ALL_GFX, ALL_CMD = 0x1000, 0x2000, 0x4000, 0x8000, 0x10000
# VkAccessFlagBits subset
IND_CMDBUF, IDX, VERT_ATTR, UNIFORM = 0x1, 0x2, 0x4, 0x8
SHADER_R, SHADER_W = 0x20, 0x40
CATT_R, CATT_W = 0x80, 0x100
XFER_R, XFER_W, MEM_R, MEM_W = 0x800, 0x1000, 0x8000, 0x10000
# VkImageLayout
UNDEF, GENERAL, CATT_OPT, SHADER_RO = 0, 1, 2, 5
XFER_SRC, XFER_DST = 6, 7


class GraphicsBarrierTests(unittest.TestCase):
    def setUp(self):
        self.images = image_fixture.ImageTests()
        self.images.native_profile = True
        self.images.setUp()
        self.images.create(usage=0x17)  # TRANSFER_SRC|DST|SAMPLED|COLOR_ATTACHMENT
        self.f, self.w, self.e = self.images.f, self.images.w, self.images.e
        self.image = self.images.IMAGE

    def barrier(self, old=0, new=7, *, image=None, src=0, dst=0, src_stage=TOP,
                dst_stage=XFER, family=0xFFFFFFFF, aspect=1, mip=0,
                levels=0xFFFFFFFF, layer=0, layers=0xFFFFFFFF,
                memory=(), buffers=(), declared=None, flags=0):
        infos = [self.w.structure('VkImageMemoryBarrier', pNext=[],
            srcAccessMask=src, dstAccessMask=dst, oldLayout=old, newLayout=new,
            srcQueueFamilyIndex=family, dstQueueFamilyIndex=family,
            image=image or self.image,
            subresourceRange=self.w.structure('VkImageSubresourceRange',
                aspectMask=aspect, baseMipLevel=mip, levelCount=levels,
                baseArrayLayer=layer, layerCount=layers))]
        self.f.command('vkCmdPipelineBarrier', commandBuffer=self.f.CB,
            srcStageMask=src_stage, dstStageMask=dst_stage, dependencyFlags=flags,
            memoryBarrierCount=len(memory),
            pMemoryBarriers=[self.w.structure('VkMemoryBarrier', pNext=[],
                srcAccessMask=a, dstAccessMask=b) for a, b in memory],
            bufferMemoryBarrierCount=len(buffers), pBufferMemoryBarriers=[],
            imageMemoryBarrierCount=(len(infos) if declared is None else declared),
            pImageMemoryBarriers=infos)

    def enqueue(self):
        self.f.end()
        return self.f.enqueue()

    def test_draw_to_transfer_readback_barrier_is_admitted_and_ordered(self):
        self.f.begin()
        # attachment layout established first: image starts UNDEFINED
        self.barrier(old=UNDEF, new=CATT_OPT, src=0, dst=CATT_W,
                     src_stage=TOP, dst_stage=FRAG | CATT_OUT)
        # memory barrier: fragment-shader color writes -> transfer reads
        self.barrier(old=CATT_OPT, new=XFER_SRC, src=CATT_W, dst=XFER_R,
                     src_stage=FRAG | CATT_OUT, dst_stage=XFER,
                     memory=[(CATT_W, XFER_R)])
        self.f.end()
        job = self.enqueue()
        # each image barrier emits the single ordered backing-retention
        # op; the memory barrier only validates scopes
        self.assertEqual([op.kind for op in job.operations],
                         ['barrier', 'barrier'])
        self.f.drain()
        self.assertEqual(job.state, 'done')

    def test_attachment_layout_transitions_bracket_draw_scope(self):
        self.f.begin()
        # UNDEFINED -> COLOR_ATTACHMENT_OPTIMAL with attachment write
        self.barrier(old=UNDEF, new=CATT_OPT, src=0, dst=CATT_W,
                     src_stage=TOP, dst_stage=FRAG | CATT_OUT)
        # COLOR_ATTACHMENT_OPTIMAL -> TRANSFER_SRC for readback
        self.barrier(old=CATT_OPT, new=XFER_SRC, src=CATT_R, dst=XFER_R,
                     src_stage=CATT_OUT, dst_stage=XFER)
        self.f.end()
        job = self.enqueue()
        self.assertEqual(len(job.operations), 2)
        self.f.drain()

    def test_sampled_image_readonly_layout_and_shader_read(self):
        self.f.begin()
        # transfer destination established first (image starts UNDEFINED)
        self.barrier(old=UNDEF, new=XFER_DST, src=0, dst=XFER_W,
                     src_stage=TOP, dst_stage=XFER)
        self.barrier(old=XFER_DST, new=SHADER_RO, src=0, dst=SHADER_R,
                     src_stage=XFER, dst_stage=FRAG)
        self.f.end()
        job = self.enqueue()
        self.assertEqual(len(job.operations), 2)
        self.f.drain()

    def test_vertex_and_uniform_accesses_need_shader_stages(self):
        self.f.begin()
        # vertex attribute + index + uniform reads under vertex/fragment
        self.barrier(old=0, new=1, src=0,
                     dst=IDX | VERT_ATTR | UNIFORM,
                     src_stage=TOP, dst_stage=VERT | FRAG)
        self.f.end()
        job = self.enqueue()
        self.assertEqual(len(job.operations), 1)
        self.f.drain()

    def test_refusals_keep_atomic_no_pin_profile(self):
        cases = (
            # depth/stencil attachment accesses are not admitted
            dict(src=0x200), dict(dst=0x400),
            # input attachment reads are not admitted
            dict(src=0x10), dict(dst=0x10),
            # tessellation/geometry/compute stages stay refused
            dict(src_stage=0x10), dict(dst_stage=0x40), dict(src_stage=0x800),
            # incompatible stage for the access
            dict(src=CATT_W, src_stage=XFER),
            dict(dst=CATT_W, dst_stage=TOP),
            # color-attachment access needs COLOR_ATTACHMENT usage: create
            # a transfer-only image and aim the barrier at it
        )
        for fields in cases:
            self.f.begin()
            self.barrier(**fields)
            self.f.end()
            with self.assertRaises(ValueError, msg=str(fields)):
                self.enqueue()
            self.assertEqual(self.f.owner.work_refs, 0)

    def test_color_attachment_access_requires_usage_and_layout(self):
        # transfer-only image (usage=3): color-attachment access refused
        self.images.create(self.images.SECOND, offset=4352, usage=3)
        self.f.begin()
        self.barrier(old=0, new=1, src=0, dst=CATT_W, image=self.images.SECOND,
                     src_stage=TOP, dst_stage=FRAG | CATT_OUT)
        self.f.end()
        with self.assertRaises(ValueError):
            self.enqueue()
        self.assertEqual(self.f.owner.work_refs, 0)
        # same barrier on the color-attachment image is admitted
        self.f.begin()
        self.barrier(old=0, new=CATT_OPT, src=0, dst=CATT_W,
                     src_stage=TOP, dst_stage=FRAG | CATT_OUT)
        self.f.end()
        job = self.enqueue()
        self.assertEqual(len(job.operations), 1)
        self.f.drain()

    def test_attachment_access_layout_compatibility_pairs(self):
        bad = (
            # color-attachment write into a shader-read-only layout
            dict(old=0, new=SHADER_RO, src=0, dst=CATT_W),
            # shader write into a color-attachment layout
            dict(old=0, new=CATT_OPT, src=0, dst=SHADER_W),
        )
        for fields in bad:
            self.f.begin()
            self.barrier(src_stage=TOP, dst_stage=FRAG | CATT_OUT, **fields)
            self.f.end()
            with self.assertRaises(ValueError, msg=str(fields)):
                self.enqueue()
            self.assertEqual(self.f.owner.work_refs, 0)


if __name__ == '__main__':
    unittest.main()
