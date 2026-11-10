#!/usr/bin/env python3
"""
Faithful port of the deqp-vk memory.pipeline_barrier op-sequence generator.

Reproduces the deterministic op sequence that
vktMemoryPipelineBarrierTests.cpp :: createCommands() generates, WITHOUT needing
Vulkan.  Only the op *selection* and *state evolution* are modeled; the command
factories (createCmdCommand / createHostCommand / createRenderPassCommand) are
omitted on purpose: they take `const State&` and draw from a *clone* of
state.rng, so they cannot influence which ops are chosen or how State evolves.

Verified primitives:
  * de::Random  -> deRandom.c  (xorshift128-style, getUint32/getFloat/getBool/getInt/choose)
  * deUint32Hash-> deInt32.h
  * Op selection-> getAvailableOps + nextOpRng.choose (reservoir sampling)
  * State evolve-> applyOp + CacheState

Seed (per memory type / iteration):
  seed = 2830980989 ^ deUint32Hash(iteration * memoryTypeCount + memoryTypeNdx)

Usage for `all_device` = all usages & ~(HOST_READ|HOST_WRITE).
"""

import sys
import numpy as np

# --------------------------------------------------------------------------
# de::Random  (framework/delibs/debase/deRandom.c + decpp/deRandom.hpp)
# --------------------------------------------------------------------------
MASK = 0xFFFFFFFF


def _u32(x):
    return x & MASK


class DeRandom:
    """Exact port of deRandom (xorshift128)."""

    def __init__(self, seed):
        seed = _u32(seed)
        # x = (uint32_t)(-(int)seed ^ 123456789)
        sint = seed - 0x100000000 if seed & 0x80000000 else seed
        self.x = _u32((-sint) ^ 123456789)
        self.y = _u32(362436069 * seed)
        self.z = _u32(521288629 ^ (seed >> 7))
        self.w = _u32(88675123 ^ _u32(seed << 3))

    def getUint32(self):
        w = self.w
        t = _u32(self.x ^ _u32(self.x << 11))
        self.x = self.y
        self.y = self.z
        self.z = w
        self.w = _u32((_u32(w ^ (w >> 19))) ^ _u32(t ^ (t >> 8)))
        return self.w

    def getFloat(self):
        # (getUint32() & 0xFFFFFFF) / (0xFFFFFFF + 1) computed in float32
        # (C++ float; numerator is rounded to f32 before the divide).
        num = np.float32(self.getUint32() & 0x0FFFFFFF)
        return num / np.float32(0x0FFFFFFF + 1)

    def getBool(self):
        val = self.getUint32()
        return (val & 0xFFFFFF) < 0x800000

    def getInt(self, mn, mx):
        # Random::getInt : min + getUint32() % (max-min+1); special full-range case
        if mn == -0x80000000 and mx == 0x7FFFFFFF:
            v = self.getUint32()
            return v - 0x100000000 if v & 0x80000000 else v
        return mn + (self.getUint32() % _u32(mx - mn + 1))

    def choose(self, seq):
        """Random::choose(first,last) for a single item -> reservoir sampling k=1.

        For ndx==0 take seq[0]; for ndx>=1 draw getInt(0,ndx)=getUint32()%(ndx+1)
        and replace when r < 1 (i.e. r==0).
        """
        if not seq:
            raise RuntimeError("choose on empty")
        result = seq[0]
        for ndx in range(1, len(seq)):
            r = self.getInt(0, ndx)
            if r < 1:
                result = seq[ndx]
        return result


# --------------------------------------------------------------------------
# deUint32Hash  (framework/delibs/debase/deInt32.h)
# --------------------------------------------------------------------------
def deUint32Hash(key):
    key = _u32(key)
    key = _u32((key ^ 61) ^ (key >> 16))
    key = _u32(key + ((key << 3) & MASK))
    key ^= key >> 4
    key = _u32(key * 0x27D4EB2D)
    key ^= key >> 15
    return _u32(key)


# --------------------------------------------------------------------------
# Vulkan flag constants (stable ABI values)
# --------------------------------------------------------------------------
# VkPipelineStageFlagBits
STAGE_TOP_OF_PIPE          = 0x00000001
STAGE_DRAW_INDIRECT        = 0x00000002
STAGE_VERTEX_INPUT         = 0x00000004
STAGE_VERTEX_SHADER        = 0x00000008
STAGE_TESS_CONTROL_SHADER  = 0x00000010
STAGE_TESS_EVAL_SHADER     = 0x00000020
STAGE_GEOMETRY_SHADER      = 0x00000040
STAGE_FRAGMENT_SHADER      = 0x00000080
STAGE_EARLY_FRAGMENT_TESTS = 0x00000100
STAGE_LATE_FRAGMENT_TESTS  = 0x00000200
STAGE_COLOR_ATTACHMENT_OUT = 0x00000400
STAGE_COMPUTE_SHADER       = 0x00000800
STAGE_TRANSFER             = 0x00001000
STAGE_BOTTOM_OF_PIPE       = 0x00002000
STAGE_HOST                 = 0x00004000

# VkAccessFlagBits
ACC_INDIRECT_COMMAND_READ  = 0x00000001
ACC_INDEX_READ             = 0x00000002
ACC_VERTEX_ATTRIBUTE_READ  = 0x00000004
ACC_UNIFORM_READ           = 0x00000008
ACC_INPUT_ATTACHMENT_READ  = 0x00000010
ACC_SHADER_READ            = 0x00000020
ACC_SHADER_WRITE           = 0x00000040
ACC_COLOR_ATTACHMENT_READ  = 0x00000080
ACC_COLOR_ATTACHMENT_WRITE = 0x00000100
ACC_DEPTH_STENCIL_READ     = 0x00000200
ACC_DEPTH_STENCIL_WRITE    = 0x00000400
ACC_TRANSFER_READ          = 0x00000800
ACC_TRANSFER_WRITE         = 0x00001000
ACC_HOST_READ              = 0x00002000
ACC_HOST_WRITE             = 0x00004000
ACC_MEMORY_READ            = 0x00008000
ACC_MEMORY_WRITE           = 0x00010000

# VkImageLayout values used by the test
LAYOUT_UNDEFINED                       = 0
LAYOUT_GENERAL                         = 1
LAYOUT_COLOR_ATTACHMENT_OPTIMAL        = 2
LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL= 3
LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL = 4
LAYOUT_SHADER_READ_ONLY_OPTIMAL        = 5
LAYOUT_TRANSFER_SRC_OPTIMAL            = 6   # VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
LAYOUT_TRANSFER_DST_OPTIMAL            = 7   # VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
LAYOUT_PREINITIALIZED                  = 8   # VK_IMAGE_LAYOUT_PREINITIALIZED

# VkMemoryPropertyFlagBits
MEM_HOST_COHERENT = 0x00000004

# --------------------------------------------------------------------------
# Usage enum (test-local bit flags)
# --------------------------------------------------------------------------
USAGE_HOST_READ                = 0x1 << 0
USAGE_HOST_WRITE               = 0x1 << 1
USAGE_TRANSFER_SRC             = 0x1 << 2
USAGE_TRANSFER_DST             = 0x1 << 3
USAGE_INDEX_BUFFER             = 0x1 << 4
USAGE_VERTEX_BUFFER            = 0x1 << 5
USAGE_UNIFORM_BUFFER           = 0x1 << 6
USAGE_STORAGE_BUFFER           = 0x1 << 7
USAGE_UNIFORM_TEXEL_BUFFER     = 0x1 << 8
USAGE_STORAGE_TEXEL_BUFFER     = 0x1 << 9
USAGE_INDIRECT_BUFFER          = 0x1 << 10
USAGE_SAMPLED_IMAGE            = 0x1 << 11
USAGE_STORAGE_IMAGE            = 0x1 << 12
USAGE_COLOR_ATTACHMENT         = 0x1 << 13
USAGE_INPUT_ATTACHMENT         = 0x1 << 14
USAGE_DEPTH_STENCIL_ATTACHMENT = 0x1 << 15

# `all` = OR of the test's `usages[]` array, which contains ONLY these 12
# (excludes INDIRECT_BUFFER, COLOR_ATTACHMENT, INPUT_ATTACHMENT,
# DEPTH_STENCIL_ATTACHMENT).  Verified vs C++ getNumberOfSupportedLayouts -> 4.
ALL_USAGES = (USAGE_HOST_READ | USAGE_HOST_WRITE | USAGE_TRANSFER_SRC | USAGE_TRANSFER_DST |
              USAGE_INDEX_BUFFER | USAGE_VERTEX_BUFFER | USAGE_UNIFORM_BUFFER | USAGE_STORAGE_BUFFER |
              USAGE_UNIFORM_TEXEL_BUFFER | USAGE_STORAGE_TEXEL_BUFFER |
              USAGE_SAMPLED_IMAGE | USAGE_STORAGE_IMAGE)

# all_device = all & ~(HOST_READ|HOST_WRITE)
USAGE_ALL_DEVICE = ALL_USAGES & ~(USAGE_HOST_READ | USAGE_HOST_WRITE)

# --------------------------------------------------------------------------
# Op enum (order matters for readability; values are arbitrary indices)
# --------------------------------------------------------------------------
(OP_MAP, OP_UNMAP, OP_MAP_FLUSH, OP_MAP_INVALIDATE, OP_MAP_READ, OP_MAP_WRITE,
 OP_MAP_MODIFY, OP_BUFFER_CREATE, OP_BUFFER_DESTROY, OP_BUFFER_BINDMEMORY,
 OP_QUEUE_WAIT_FOR_IDLE, OP_DEVICE_WAIT_FOR_IDLE,
 OP_COMMAND_BUFFER_BEGIN, OP_COMMAND_BUFFER_END,
 OP_SECONDARY_COMMAND_BUFFER_BEGIN, OP_SECONDARY_COMMAND_BUFFER_END,
 OP_BUFFER_FILL, OP_BUFFER_UPDATE,
 OP_BUFFER_COPY_TO_BUFFER, OP_BUFFER_COPY_FROM_BUFFER,
 OP_BUFFER_COPY_TO_IMAGE, OP_BUFFER_COPY_FROM_IMAGE,
 OP_IMAGE_CREATE, OP_IMAGE_DESTROY, OP_IMAGE_BINDMEMORY,
 OP_IMAGE_TRANSITION_LAYOUT,
 OP_IMAGE_COPY_TO_BUFFER, OP_IMAGE_COPY_FROM_BUFFER,
 OP_IMAGE_COPY_TO_IMAGE, OP_IMAGE_COPY_FROM_IMAGE,
 OP_IMAGE_BLIT_TO_IMAGE, OP_IMAGE_BLIT_FROM_IMAGE,
 OP_IMAGE_RESOLVE,
 OP_PIPELINE_BARRIER_GLOBAL, OP_PIPELINE_BARRIER_BUFFER, OP_PIPELINE_BARRIER_IMAGE,
 OP_RENDERPASS_BEGIN, OP_RENDERPASS_END,
 OP_RENDER_VERTEX_BUFFER, OP_RENDER_INDEX_BUFFER,
 OP_RENDER_VERTEX_UNIFORM_BUFFER, OP_RENDER_FRAGMENT_UNIFORM_BUFFER,
 OP_RENDER_VERTEX_UNIFORM_TEXEL_BUFFER, OP_RENDER_FRAGMENT_UNIFORM_TEXEL_BUFFER,
 OP_RENDER_VERTEX_STORAGE_BUFFER, OP_RENDER_FRAGMENT_STORAGE_BUFFER,
 OP_RENDER_VERTEX_STORAGE_TEXEL_BUFFER, OP_RENDER_FRAGMENT_STORAGE_TEXEL_BUFFER,
 OP_RENDER_VERTEX_STORAGE_IMAGE, OP_RENDER_FRAGMENT_STORAGE_IMAGE,
 OP_RENDER_VERTEX_SAMPLED_IMAGE, OP_RENDER_FRAGMENT_SAMPLED_IMAGE) = range(52)

OP_NAMES = {v: k for k, v in list(globals().items()) if k.startswith("OP_") and isinstance(v, int)}

# Stage enum
(STAGE_HOST, STAGE_COMMAND_BUFFER, STAGE_SECONDARY_COMMAND_BUFFER, STAGE_RENDER_PASS) = range(4)
STAGE_NAMES = {0: "HOST", 1: "CMD", 2: "SEC", 3: "RP"}

# Sequential Access enum indices (match ACCESS_* order in C++ enum)
(ACC_INDIRECT_COMMAND_READ_B, ACC_INDEX_READ_B, ACC_VERTEX_ATTRIBUTE_READ_B,
 ACC_UNIFORM_READ_B, ACC_INPUT_ATTACHMENT_READ_B, ACC_SHADER_READ_B,
 ACC_SHADER_WRITE_B, ACC_COLOR_ATTACHMENT_READ_B, ACC_COLOR_ATTACHMENT_WRITE_B,
 ACC_DEPTH_STENCIL_READ_B, ACC_DEPTH_STENCIL_WRITE_B, ACC_TRANSFER_READ_B,
 ACC_TRANSFER_WRITE_B, ACC_HOST_READ_B, ACC_HOST_WRITE_B, ACC_MEMORY_READ_B,
 ACC_MEMORY_WRITE_B, ACCESS_LAST) = range(18)

# flag-bit -> sequential Access index
_ACCESS_FLAG_TO_IDX = {
    ACC_INDIRECT_COMMAND_READ:  ACC_INDIRECT_COMMAND_READ_B,
    ACC_INDEX_READ:             ACC_INDEX_READ_B,
    ACC_VERTEX_ATTRIBUTE_READ:  ACC_VERTEX_ATTRIBUTE_READ_B,
    ACC_UNIFORM_READ:           ACC_UNIFORM_READ_B,
    ACC_INPUT_ATTACHMENT_READ:  ACC_INPUT_ATTACHMENT_READ_B,
    ACC_SHADER_READ:            ACC_SHADER_READ_B,
    ACC_SHADER_WRITE:           ACC_SHADER_WRITE_B,
    ACC_COLOR_ATTACHMENT_READ:  ACC_COLOR_ATTACHMENT_READ_B,
    ACC_COLOR_ATTACHMENT_WRITE: ACC_COLOR_ATTACHMENT_WRITE_B,
    ACC_DEPTH_STENCIL_READ:     ACC_DEPTH_STENCIL_READ_B,
    ACC_DEPTH_STENCIL_WRITE:    ACC_DEPTH_STENCIL_WRITE_B,
    ACC_TRANSFER_READ:          ACC_TRANSFER_READ_B,
    ACC_TRANSFER_WRITE:         ACC_TRANSFER_WRITE_B,
    ACC_HOST_READ:              ACC_HOST_READ_B,
    ACC_HOST_WRITE:             ACC_HOST_WRITE_B,
    ACC_MEMORY_READ:            ACC_MEMORY_READ_B,
    ACC_MEMORY_WRITE:           ACC_MEMORY_WRITE_B,
}

# Sequential PipelineStage enum indices (match PIPELINESTAGE_* order in C++)
(PS_TOP_OF_PIPE, PS_BOTTOM_OF_PIPE, PS_DRAW_INDIRECT, PS_VERTEX_INPUT,
 PS_VERTEX_SHADER, PS_TESS_CONTROL, PS_TESS_EVAL, PS_GEOMETRY,
 PS_FRAGMENT_SHADER, PS_EARLY_FRAG, PS_LATE_FRAG, PS_COLOR_ATTACHMENT_OUT,
 PS_COMPUTE_SHADER, PS_TRANSFER, PS_HOST, PIPELINESTAGE_LAST) = range(16)

# flag-bit -> sequential PipelineStage index
_STAGE_FLAG_TO_IDX = {
    STAGE_TOP_OF_PIPE:          PS_TOP_OF_PIPE,
    STAGE_BOTTOM_OF_PIPE:       PS_BOTTOM_OF_PIPE,
    STAGE_DRAW_INDIRECT:        PS_DRAW_INDIRECT,
    STAGE_VERTEX_INPUT:         PS_VERTEX_INPUT,
    STAGE_VERTEX_SHADER:        PS_VERTEX_SHADER,
    STAGE_TESS_CONTROL_SHADER:  PS_TESS_CONTROL,
    STAGE_TESS_EVAL_SHADER:     PS_TESS_EVAL,
    STAGE_GEOMETRY_SHADER:      PS_GEOMETRY,
    STAGE_FRAGMENT_SHADER:      PS_FRAGMENT_SHADER,
    STAGE_EARLY_FRAGMENT_TESTS: PS_EARLY_FRAG,
    STAGE_LATE_FRAGMENT_TESTS:  PS_LATE_FRAG,
    STAGE_COLOR_ATTACHMENT_OUT: PS_COLOR_ATTACHMENT_OUT,
    STAGE_COMPUTE_SHADER:       PS_COMPUTE_SHADER,
    STAGE_TRANSFER:             PS_TRANSFER,
    STAGE_HOST:                 PS_HOST,
}
# index -> flag bit
_IDX_TO_STAGE_FLAG = {v: k for k, v in _STAGE_FLAG_TO_IDX.items()}
_IDX_TO_ACCESS_FLAG = {v: k for k, v in _ACCESS_FLAG_TO_IDX.items()}


def stage_flag_to_idx(flag):
    return _STAGE_FLAG_TO_IDX[flag]


def access_flag_to_idx(flag):
    return _ACCESS_FLAG_TO_IDX[flag]


def getWriteAccessFlags():
    return (ACC_SHADER_WRITE | ACC_COLOR_ATTACHMENT_WRITE |
            ACC_DEPTH_STENCIL_WRITE | ACC_TRANSFER_WRITE |
            ACC_HOST_WRITE | ACC_MEMORY_WRITE)


def isWriteAccess(access):
    return (getWriteAccessFlags() & access) != 0


# --------------------------------------------------------------------------
# usage -> stage / access flags  (lines 413-494)
# --------------------------------------------------------------------------
def usageToStageFlags(usage):
    flags = 0
    if usage & (USAGE_HOST_READ | USAGE_HOST_WRITE):
        flags |= STAGE_HOST
    if usage & (USAGE_TRANSFER_SRC | USAGE_TRANSFER_DST):
        flags |= STAGE_TRANSFER
    if usage & (USAGE_VERTEX_BUFFER | USAGE_INDEX_BUFFER):
        flags |= STAGE_VERTEX_INPUT
    if usage & USAGE_INDIRECT_BUFFER:
        flags |= STAGE_DRAW_INDIRECT
    if usage & (USAGE_UNIFORM_BUFFER | USAGE_STORAGE_BUFFER | USAGE_UNIFORM_TEXEL_BUFFER |
                USAGE_STORAGE_TEXEL_BUFFER | USAGE_SAMPLED_IMAGE | USAGE_STORAGE_IMAGE):
        flags |= (STAGE_VERTEX_SHADER | STAGE_FRAGMENT_SHADER | STAGE_COMPUTE_SHADER)
    if usage & USAGE_INPUT_ATTACHMENT:
        flags |= STAGE_FRAGMENT_SHADER
    if usage & USAGE_COLOR_ATTACHMENT:
        flags |= STAGE_COLOR_ATTACHMENT_OUT
    if usage & USAGE_DEPTH_STENCIL_ATTACHMENT:
        flags |= STAGE_EARLY_FRAGMENT_TESTS | STAGE_LATE_FRAGMENT_TESTS
    return flags


def usageToAccessFlags(usage):
    flags = 0
    if usage & USAGE_HOST_READ:
        flags |= ACC_HOST_READ
    if usage & USAGE_HOST_WRITE:
        flags |= ACC_HOST_WRITE
    if usage & USAGE_TRANSFER_SRC:
        flags |= ACC_TRANSFER_READ
    if usage & USAGE_TRANSFER_DST:
        flags |= ACC_TRANSFER_WRITE
    if usage & USAGE_INDEX_BUFFER:
        flags |= ACC_INDEX_READ
    if usage & USAGE_VERTEX_BUFFER:
        flags |= ACC_VERTEX_ATTRIBUTE_READ
    if usage & USAGE_UNIFORM_BUFFER:
        flags |= ACC_UNIFORM_READ
    if usage & USAGE_SAMPLED_IMAGE:
        flags |= ACC_SHADER_READ
    if usage & (USAGE_STORAGE_BUFFER | USAGE_UNIFORM_TEXEL_BUFFER |
                USAGE_STORAGE_TEXEL_BUFFER | USAGE_STORAGE_IMAGE):
        flags |= ACC_SHADER_READ | ACC_SHADER_WRITE
    if usage & USAGE_INDIRECT_BUFFER:
        flags |= ACC_INDIRECT_COMMAND_READ
    if usage & USAGE_COLOR_ATTACHMENT:
        flags |= ACC_COLOR_ATTACHMENT_READ | ACC_COLOR_ATTACHMENT_WRITE
    if usage & USAGE_INPUT_ATTACHMENT:
        flags |= ACC_INPUT_ATTACHMENT_READ
    if usage & USAGE_DEPTH_STENCIL_ATTACHMENT:
        flags |= ACC_DEPTH_STENCIL_READ | ACC_DEPTH_STENCIL_WRITE
    return flags


def supportsDeviceBufferWrites(usage):
    return bool(usage & (USAGE_TRANSFER_DST | USAGE_STORAGE_BUFFER | USAGE_STORAGE_TEXEL_BUFFER))


def supportsDeviceImageWrites(usage):
    return bool(usage & (USAGE_TRANSFER_DST | USAGE_STORAGE_IMAGE | USAGE_COLOR_ATTACHMENT))


# --------------------------------------------------------------------------
# layout helpers (lines 7929-8022)
# --------------------------------------------------------------------------
def layoutSupportedByUsage(usage, layout):
    if layout == LAYOUT_GENERAL:
        return True
    if layout == LAYOUT_COLOR_ATTACHMENT_OPTIMAL:
        return bool(usage & USAGE_COLOR_ATTACHMENT)
    if layout == LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL:
        return bool(usage & USAGE_DEPTH_STENCIL_ATTACHMENT)
    if layout == LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL:
        return bool(usage & USAGE_DEPTH_STENCIL_ATTACHMENT)
    if layout == LAYOUT_SHADER_READ_ONLY_OPTIMAL:
        return bool(usage & USAGE_SAMPLED_IMAGE)
    if layout == LAYOUT_TRANSFER_SRC_OPTIMAL:
        return bool(usage & USAGE_TRANSFER_SRC)
    if layout == LAYOUT_TRANSFER_DST_OPTIMAL:
        return bool(usage & USAGE_TRANSFER_DST)
    if layout == LAYOUT_PREINITIALIZED:
        return True
    raise RuntimeError("Unknown layout %r" % layout)


_LAYOUTS = [LAYOUT_GENERAL, LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL, LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL,
            LAYOUT_SHADER_READ_ONLY_OPTIMAL, LAYOUT_TRANSFER_SRC_OPTIMAL,
            LAYOUT_TRANSFER_DST_OPTIMAL]


def getNumberOfSupportedLayouts(usage):
    return sum(1 for l in _LAYOUTS if layoutSupportedByUsage(usage, l))


GNLL = []


def getRandomNextLayout(rng, usage, previousLayout):
    supported = getNumberOfSupportedLayouts(usage)
    raw = rng.getUint32()
    if previousLayout == LAYOUT_UNDEFINED:
        nxt = raw % supported
    else:
        nxt = raw % (supported - 1)
    GNLL.append((raw, supported, previousLayout, nxt))
    for layout in _LAYOUTS:
        if layoutSupportedByUsage(usage, layout) and layout != previousLayout:
            if nxt == 0:
                return layout
            nxt -= 1
    raise RuntimeError("Unreachable")


# --------------------------------------------------------------------------
# CacheState  (lines 7426-7927)
# --------------------------------------------------------------------------
class CacheState:
    def __init__(self, allowedStages, allowedAccesses):
        self.m_allowedStages = allowedStages
        self.m_allowedAccesses = allowedAccesses
        # [dstStage][srcStage][dstAccess] = srcAccesses
        self.m_unavailableWriteOperations = [[[0] * ACCESS_LAST
                                              for _ in range(PIPELINESTAGE_LAST)]
                                             for _ in range(PIPELINESTAGE_LAST)]
        self.m_unavailableLayoutTransition = [False] * PIPELINESTAGE_LAST
        self.m_invisibleOperations = [0] * PIPELINESTAGE_LAST
        self.m_incompleteOperations = [0] * PIPELINESTAGE_LAST

        dstStage_ = 1
        while dstStage_ <= self.m_allowedStages:
            if (dstStage_ & self.m_allowedStages) == 0:
                dstStage_ <<= 1
                continue
            dstStage = stage_flag_to_idx(dstStage_)
            self.m_invisibleOperations[dstStage] = 0
            self.m_incompleteOperations[dstStage] = 0
            self.m_unavailableLayoutTransition[dstStage] = False
            srcStage_ = 1
            while srcStage_ <= self.m_allowedStages:
                if (srcStage_ & self.m_allowedStages) == 0:
                    srcStage_ <<= 1
                    continue
                srcStage = stage_flag_to_idx(srcStage_)
                dstAccess_ = 1
                while dstAccess_ <= self.m_allowedAccesses:
                    if (dstAccess_ & self.m_allowedAccesses) == 0:
                        dstAccess_ <<= 1
                        continue
                    dstAccess = access_flag_to_idx(dstAccess_)
                    self.m_unavailableWriteOperations[dstStage][srcStage][dstAccess] = 0
                    dstAccess_ <<= 1
                srcStage_ <<= 1
            dstStage_ <<= 1

    def isValid(self, stage, access):
        dstStage = stage_flag_to_idx(stage)
        if self.m_unavailableLayoutTransition[dstStage] or \
           (self.m_invisibleOperations[dstStage] & access) != 0:
            return False
        if isWriteAccess(access):
            if self.m_incompleteOperations[dstStage] != 0:
                return False
        return True

    def perform(self, stage, access):
        srcStage = stage_flag_to_idx(stage)
        dstStage_ = 1
        while dstStage_ <= self.m_allowedStages:
            if (dstStage_ & self.m_allowedStages) == 0:
                dstStage_ <<= 1
                continue
            dstStage = stage_flag_to_idx(dstStage_)
            self.m_incompleteOperations[dstStage] |= stage
            if isWriteAccess(access):
                self.m_invisibleOperations[dstStage] |= self.m_allowedAccesses
                dstAccess_ = 1
                while dstAccess_ <= self.m_allowedAccesses:
                    if (dstAccess_ & self.m_allowedAccesses) == 0:
                        dstAccess_ <<= 1
                        continue
                    dstAccess = access_flag_to_idx(dstAccess_)
                    self.m_unavailableWriteOperations[dstStage][srcStage][dstAccess] |= access
                    dstAccess_ <<= 1
            dstStage_ <<= 1

    def submitCommandBuffer(self):
        self.barrier(self.m_allowedStages & STAGE_HOST,
                     self.m_allowedAccesses & (ACC_HOST_READ | ACC_HOST_WRITE),
                     self.m_allowedStages, self.m_allowedAccesses)

    def waitForIdle(self):
        self.barrier(self.m_allowedStages, self.m_allowedAccesses & getWriteAccessFlags(),
                     self.m_allowedStages, 0)
        self.barrier(self.m_allowedStages, 0,
                     self.m_allowedStages & ~STAGE_HOST, self.m_allowedAccesses)

    def getFullBarrier(self):
        srcStages = srcAccesses = dstStages = dstAccesses = 0
        dstStage_ = 1
        while dstStage_ <= self.m_allowedStages:
            if (dstStage_ & self.m_allowedStages) == 0:
                dstStage_ <<= 1
                continue
            dstStage = stage_flag_to_idx(dstStage_)
            if self.m_incompleteOperations[dstStage]:
                dstStages |= dstStage_
                srcStages |= self.m_incompleteOperations[dstStage]
            if self.m_invisibleOperations[dstStage]:
                dstStages |= dstStage_
                dstAccesses |= self.m_invisibleOperations[dstStage]
            srcStage_ = 1
            while srcStage_ <= self.m_allowedStages:
                if (srcStage_ & self.m_allowedStages) == 0:
                    srcStage_ <<= 1
                    continue
                srcStage = stage_flag_to_idx(srcStage_)
                dstAccess_ = 1
                while dstAccess_ <= self.m_allowedAccesses:
                    if (dstAccess_ & self.m_allowedAccesses) == 0:
                        dstAccess_ <<= 1
                        continue
                    dstAccess = access_flag_to_idx(dstAccess_)
                    if self.m_unavailableWriteOperations[dstStage][srcStage][dstAccess]:
                        dstStages |= dstStage_
                        srcStages |= dstStage_
                        srcAccesses |= self.m_unavailableWriteOperations[dstStage][srcStage][dstAccess]
                    dstAccess_ <<= 1
                if self.m_unavailableLayoutTransition[dstStage] and \
                   not self.m_unavailableLayoutTransition[srcStage]:
                    dstStages |= dstStage_
                    srcStages |= dstStage_
                srcStage_ <<= 1
            dstStage_ <<= 1
        return srcStages, srcAccesses, dstStages, dstAccesses

    def imageLayoutBarrier(self, srcStages, srcAccesses, dstStages, dstAccesses):
        # checkImageLayoutBarrier is debug-only asserts -> skipped
        dstStage_ = 1
        while dstStage_ <= self.m_allowedStages:
            if (dstStage_ & self.m_allowedStages) == 0:
                dstStage_ <<= 1
                continue
            dstStage = stage_flag_to_idx(dstStage_)
            self.m_incompleteOperations[dstStage] = self.m_allowedStages & (~dstStage_)
            self.m_invisibleOperations[dstStage] = self.m_allowedAccesses & (~dstAccesses)
            self.m_unavailableLayoutTransition[dstStage] = (dstStage_ & dstStages) == 0
            srcStage_ = 1
            while srcStage_ <= self.m_allowedStages:
                if (srcStage_ & self.m_allowedStages) == 0:
                    srcStage_ <<= 1
                    continue
                srcStage = stage_flag_to_idx(srcStage_)
                dstAccess_ = 1
                while dstAccess_ <= self.m_allowedAccesses:
                    if (dstAccess_ & self.m_allowedAccesses) == 0:
                        dstAccess_ <<= 1
                        continue
                    dstAccess = access_flag_to_idx(dstAccess_)
                    self.m_unavailableWriteOperations[dstStage][srcStage][dstAccess] = 0
                    dstAccess_ <<= 1
                srcStage_ <<= 1
            dstStage_ <<= 1

    def barrier(self, srcStages, srcAccesses, dstStages, dstAccesses):
        # --- Transitivity ---
        oldIncomplete = [v for v in self.m_incompleteOperations]
        oldUnavailableWrite = [[[self.m_unavailableWriteOperations[d][s][a]
                                 for a in range(ACCESS_LAST)]
                                for s in range(PIPELINESTAGE_LAST)]
                               for d in range(PIPELINESTAGE_LAST)]
        oldUnavailableLayout = [v for v in self.m_unavailableLayoutTransition]

        srcStage_ = 1
        while srcStage_ <= srcStages:
            if (srcStage_ & srcStages) == 0:
                srcStage_ <<= 1
                continue
            srcStage = stage_flag_to_idx(srcStage_)
            dstStage_ = 1
            while dstStage_ <= dstStages:
                if (dstStage_ & dstStages) == 0:
                    dstStage_ <<= 1
                    continue
                dstStage = stage_flag_to_idx(dstStage_)
                self.m_incompleteOperations[dstStage] &= oldIncomplete[srcStage]
                self.m_unavailableLayoutTransition[dstStage] &= oldUnavailableLayout[srcStage]
                sharedStage_ = 1
                while sharedStage_ <= self.m_allowedStages:
                    if (sharedStage_ & self.m_allowedStages) == 0:
                        sharedStage_ <<= 1
                        continue
                    sharedStage = stage_flag_to_idx(sharedStage_)
                    sharedAccess_ = 1
                    while sharedAccess_ <= self.m_allowedAccesses:
                        if (sharedAccess_ & self.m_allowedAccesses) == 0:
                            sharedAccess_ <<= 1
                            continue
                        sharedAccess = access_flag_to_idx(sharedAccess_)
                        self.m_unavailableWriteOperations[dstStage][sharedStage][sharedAccess] &= \
                            oldUnavailableWrite[srcStage][sharedStage][sharedAccess]
                        sharedAccess_ <<= 1
                    sharedStage_ <<= 1
                dstStage_ <<= 1
            srcStage_ <<= 1

        # --- Barrier ---
        dstStage_ = 1
        while dstStage_ <= dstStages:
            dstStage = stage_flag_to_idx(dstStage_)
            allWritesAvailable = True
            if (dstStage_ & dstStages) == 0:
                dstStage_ <<= 1
                continue
            self.m_incompleteOperations[dstStage] &= ~srcStages & MASK
            srcStage_ = 1
            while srcStage_ <= self.m_allowedStages:
                if (srcStage_ & self.m_allowedStages) == 0:
                    srcStage_ <<= 1
                    continue
                srcStage = stage_flag_to_idx(srcStage_)
                dstAccess_ = 1
                while dstAccess_ <= self.m_allowedAccesses:
                    if (dstAccess_ & self.m_allowedAccesses) == 0:
                        dstAccess_ <<= 1
                        continue
                    dstAccess = access_flag_to_idx(dstAccess_)
                    if ((srcStage_ & srcStages) != 0) and ((dstAccess_ & dstAccesses) != 0):
                        self.m_unavailableWriteOperations[dstStage][srcStage][dstAccess] &= ~srcAccesses & MASK
                    if self.m_unavailableWriteOperations[dstStage][srcStage][dstAccess] != 0:
                        allWritesAvailable = False
                    dstAccess_ <<= 1
                srcStage_ <<= 1
            if allWritesAvailable:
                self.m_invisibleOperations[dstStage] &= ~dstAccesses & MASK
            dstStage_ <<= 1

    def isClean(self):
        dstStage_ = 1
        while dstStage_ <= self.m_allowedStages:
            if (dstStage_ & self.m_allowedStages) == 0:
                dstStage_ <<= 1
                continue
            dstStage = stage_flag_to_idx(dstStage_)
            if self.m_invisibleOperations[dstStage] != 0:
                return False
            if self.m_incompleteOperations[dstStage] != 0:
                return False
            if self.m_unavailableLayoutTransition[dstStage]:
                return False
            srcStage_ = 1
            while srcStage_ <= self.m_allowedStages:
                if (srcStage_ & self.m_allowedStages) == 0:
                    srcStage_ <<= 1
                    continue
                srcStage = stage_flag_to_idx(srcStage_)
                dstAccess_ = 1
                while dstAccess_ <= self.m_allowedAccesses:
                    if (dstAccess_ & self.m_allowedAccesses) == 0:
                        dstAccess_ <<= 1
                        continue
                    dstAccess = access_flag_to_idx(dstAccess_)
                    if self.m_unavailableWriteOperations[dstStage][srcStage][dstAccess] != 0:
                        return False
                    dstAccess_ <<= 1
                srcStage_ <<= 1
            dstStage_ <<= 1
        return True


# --------------------------------------------------------------------------
# removeIllegalAccessFlags  (lines 8417-8474)
# --------------------------------------------------------------------------
def removeIllegalAccessFlags(accessflags, stageflags):
    accessflags = accessflags & MASK
    if not (stageflags & STAGE_DRAW_INDIRECT):
        accessflags &= ~ACC_INDIRECT_COMMAND_READ & MASK
    if not (stageflags & STAGE_VERTEX_INPUT):
        accessflags &= ~ACC_INDEX_READ & MASK
    if not (stageflags & STAGE_VERTEX_INPUT):
        accessflags &= ~ACC_VERTEX_ATTRIBUTE_READ & MASK
    shader_stages = (STAGE_VERTEX_SHADER | STAGE_TESS_CONTROL_SHADER |
                     STAGE_TESS_EVAL_SHADER | STAGE_GEOMETRY_SHADER |
                     STAGE_FRAGMENT_SHADER | STAGE_COMPUTE_SHADER)
    if not (stageflags & shader_stages):
        accessflags &= ~ACC_UNIFORM_READ & MASK
    if not (stageflags & STAGE_FRAGMENT_SHADER):
        accessflags &= ~ACC_INPUT_ATTACHMENT_READ & MASK
    if not (stageflags & shader_stages):
        accessflags &= ~ACC_SHADER_READ & MASK
    if not (stageflags & shader_stages):
        accessflags &= ~ACC_SHADER_WRITE & MASK
    if not (stageflags & STAGE_COLOR_ATTACHMENT_OUT):
        accessflags &= ~ACC_COLOR_ATTACHMENT_READ & MASK
    if not (stageflags & STAGE_COLOR_ATTACHMENT_OUT):
        accessflags &= ~ACC_COLOR_ATTACHMENT_WRITE & MASK
    if not (stageflags & (STAGE_EARLY_FRAGMENT_TESTS | STAGE_LATE_FRAGMENT_TESTS)):
        accessflags &= ~ACC_DEPTH_STENCIL_READ & MASK
    if not (stageflags & (STAGE_EARLY_FRAGMENT_TESTS | STAGE_LATE_FRAGMENT_TESTS)):
        accessflags &= ~ACC_DEPTH_STENCIL_WRITE & MASK
    if not (stageflags & STAGE_TRANSFER):
        accessflags &= ~ACC_TRANSFER_READ & MASK
    if not (stageflags & STAGE_TRANSFER):
        accessflags &= ~ACC_TRANSFER_WRITE & MASK
    if not (stageflags & STAGE_HOST):
        accessflags &= ~ACC_HOST_READ & MASK
    if not (stageflags & STAGE_HOST):
        accessflags &= ~ACC_HOST_WRITE & MASK
    return accessflags


# --------------------------------------------------------------------------
# State  (lines 8024-8074 + constructor)
# --------------------------------------------------------------------------
class State:
    def __init__(self, usage, seed, host_coherent):
        self.stage = STAGE_HOST
        self.cache = CacheState(usageToStageFlags(usage), usageToAccessFlags(usage))
        self.rng = DeRandom(seed)
        self.host_coherent = host_coherent
        self.mapped = False
        self.hostInvalidated = True
        self.hostFlushed = True
        self.memoryDefined = False
        self.hasBuffer = False
        self.hasBoundBufferMemory = False
        self.hasImage = False
        self.hasBoundImageMemory = False
        self.imageLayout = LAYOUT_UNDEFINED
        self.imageDefined = False
        self.queueIdle = True
        self.deviceIdle = True
        self.commandBufferIsEmpty = True
        self.primaryCommandBufferIsEmpty = True
        self.renderPassIsEmpty = True


# --------------------------------------------------------------------------
# getAvailableOps  (lines 8076-8415)
# supportsBuffers/supportsImages are both True for this test.
# --------------------------------------------------------------------------
def getAvailableOps(state, usage):
    ops = []
    if state.stage == STAGE_HOST:
        if usage & (USAGE_HOST_READ | USAGE_HOST_WRITE):
            if state.mapped:
                ops.append(OP_UNMAP)
                if not state.hostFlushed:
                    ops.append(OP_MAP_FLUSH)
                if (not state.hostInvalidated and state.queueIdle and
                    ((usage & USAGE_HOST_READ) == 0 or
                     state.cache.isValid(STAGE_HOST, ACC_HOST_READ)) and
                    ((usage & USAGE_HOST_WRITE) == 0 or
                     state.cache.isValid(STAGE_HOST, ACC_HOST_WRITE))):
                    ops.append(OP_MAP_INVALIDATE)
                if (usage & USAGE_HOST_READ and usage & USAGE_HOST_WRITE and state.memoryDefined and
                    state.hostInvalidated and state.queueIdle and
                    state.cache.isValid(STAGE_HOST, ACC_HOST_WRITE) and
                    state.cache.isValid(STAGE_HOST, ACC_HOST_READ)):
                    ops.append(OP_MAP_MODIFY)
                if (usage & USAGE_HOST_READ and state.memoryDefined and state.hostInvalidated and
                    state.queueIdle and state.cache.isValid(STAGE_HOST, ACC_HOST_READ)):
                    ops.append(OP_MAP_READ)
                if (usage & USAGE_HOST_WRITE and state.hostInvalidated and state.queueIdle and
                    state.cache.isValid(STAGE_HOST, ACC_HOST_WRITE)):
                    ops.append(OP_MAP_WRITE)
            else:
                ops.append(OP_MAP)

        if state.hasBoundBufferMemory and state.queueIdle:
            ops.append(OP_BUFFER_DESTROY)
        else:
            if state.hasBuffer:
                if not state.hasBoundBufferMemory:
                    ops.append(OP_BUFFER_BINDMEMORY)
            elif not state.hasImage:  # supportsBuffers == True
                ops.append(OP_BUFFER_CREATE)

        if state.hasBoundImageMemory and state.queueIdle:
            ops.append(OP_IMAGE_DESTROY)
        else:
            if state.hasImage:
                if not state.hasBoundImageMemory:
                    ops.append(OP_IMAGE_BINDMEMORY)
            elif not state.hasBuffer:  # supportsImages == True
                ops.append(OP_IMAGE_CREATE)

        if (state.hostFlushed and
            (state.memoryDefined or supportsDeviceBufferWrites(usage) or state.imageDefined or
             supportsDeviceImageWrites(usage)) and
            (state.hasBoundBufferMemory or state.hasBoundImageMemory) and
            (usageToStageFlags(usage) & ~STAGE_HOST) != 0):
            ops.append(OP_COMMAND_BUFFER_BEGIN)

        if not state.deviceIdle:
            ops.append(OP_DEVICE_WAIT_FOR_IDLE)
        if not state.queueIdle:
            ops.append(OP_QUEUE_WAIT_FOR_IDLE)

    elif state.stage == STAGE_COMMAND_BUFFER:
        if not state.cache.isClean():
            ops.append(OP_PIPELINE_BARRIER_GLOBAL)
            if state.hasImage and state.imageLayout != LAYOUT_UNDEFINED:
                ops.append(OP_PIPELINE_BARRIER_IMAGE)
            if state.hasBuffer:
                ops.append(OP_PIPELINE_BARRIER_BUFFER)

        if state.hasBoundBufferMemory:
            if usage & USAGE_TRANSFER_DST and \
               state.cache.isValid(STAGE_TRANSFER, ACC_TRANSFER_WRITE):
                ops.append(OP_BUFFER_FILL)
                ops.append(OP_BUFFER_UPDATE)
                ops.append(OP_BUFFER_COPY_FROM_BUFFER)
                ops.append(OP_BUFFER_COPY_FROM_IMAGE)
            if usage & USAGE_TRANSFER_SRC and state.memoryDefined and \
               state.cache.isValid(STAGE_TRANSFER, ACC_TRANSFER_READ):
                ops.append(OP_BUFFER_COPY_TO_BUFFER)
                ops.append(OP_BUFFER_COPY_TO_IMAGE)

        if state.hasBoundImageMemory and \
           (state.imageLayout == LAYOUT_UNDEFINED or getNumberOfSupportedLayouts(usage) > 1):
            ops.append(OP_IMAGE_TRANSITION_LAYOUT)
            if usage & USAGE_TRANSFER_DST and \
               (state.imageLayout == LAYOUT_GENERAL or
                state.imageLayout == LAYOUT_TRANSFER_DST_OPTIMAL) and \
               state.cache.isValid(STAGE_TRANSFER, ACC_TRANSFER_WRITE):
                ops.append(OP_IMAGE_COPY_FROM_BUFFER)
                ops.append(OP_IMAGE_COPY_FROM_IMAGE)
                ops.append(OP_IMAGE_BLIT_FROM_IMAGE)
            if usage & USAGE_TRANSFER_SRC and \
               (state.imageLayout == LAYOUT_GENERAL or
                state.imageLayout == LAYOUT_TRANSFER_SRC_OPTIMAL) and \
               state.imageDefined and \
               state.cache.isValid(STAGE_TRANSFER, ACC_TRANSFER_READ):
                ops.append(OP_IMAGE_COPY_TO_BUFFER)
                ops.append(OP_IMAGE_COPY_TO_IMAGE)
                ops.append(OP_IMAGE_BLIT_TO_IMAGE)

        if ((state.memoryDefined and state.hasBoundBufferMemory and
             (((usage & USAGE_VERTEX_BUFFER) and
               state.cache.isValid(STAGE_VERTEX_INPUT, ACC_VERTEX_ATTRIBUTE_READ)) or
              ((usage & USAGE_INDEX_BUFFER) and
               state.cache.isValid(STAGE_VERTEX_INPUT, ACC_INDEX_READ)) or
              ((usage & USAGE_UNIFORM_BUFFER) and
               (state.cache.isValid(STAGE_VERTEX_SHADER, ACC_UNIFORM_READ) or
                state.cache.isValid(STAGE_FRAGMENT_SHADER, ACC_UNIFORM_READ))) or
              ((usage & USAGE_UNIFORM_TEXEL_BUFFER) and
               (state.cache.isValid(STAGE_VERTEX_SHADER, ACC_SHADER_READ) or
                state.cache.isValid(STAGE_FRAGMENT_SHADER, ACC_SHADER_READ))) or
              ((usage & USAGE_STORAGE_BUFFER) and
               (state.cache.isValid(STAGE_VERTEX_SHADER, ACC_SHADER_READ) or
                state.cache.isValid(STAGE_FRAGMENT_SHADER, ACC_SHADER_READ))) or
              ((usage & USAGE_STORAGE_TEXEL_BUFFER) and
               state.cache.isValid(STAGE_VERTEX_SHADER, ACC_SHADER_READ)))) or
            (state.imageDefined and state.hasBoundImageMemory and
             (((usage & USAGE_STORAGE_IMAGE) and state.imageLayout == LAYOUT_GENERAL and
               (state.cache.isValid(STAGE_VERTEX_SHADER, ACC_SHADER_READ) or
                state.cache.isValid(STAGE_FRAGMENT_SHADER, ACC_SHADER_READ))) or
              ((usage & USAGE_SAMPLED_IMAGE) and
               (state.imageLayout == LAYOUT_GENERAL or
                state.imageLayout == LAYOUT_SHADER_READ_ONLY_OPTIMAL) and
               (state.cache.isValid(STAGE_VERTEX_SHADER, ACC_SHADER_READ) or
                state.cache.isValid(STAGE_FRAGMENT_SHADER, ACC_SHADER_READ)))))):
            ops.append(OP_RENDERPASS_BEGIN)

        ops.append(OP_SECONDARY_COMMAND_BUFFER_BEGIN)

        if len(ops) == 0 or not state.commandBufferIsEmpty:
            ops.append(OP_COMMAND_BUFFER_END)

    elif state.stage == STAGE_SECONDARY_COMMAND_BUFFER:
        if not state.cache.isClean():
            ops.append(OP_PIPELINE_BARRIER_GLOBAL)
            if state.hasImage and state.imageLayout != LAYOUT_UNDEFINED:
                ops.append(OP_PIPELINE_BARRIER_IMAGE)
            if state.hasBuffer:
                ops.append(OP_PIPELINE_BARRIER_BUFFER)

        if state.hasBoundBufferMemory:
            if usage & USAGE_TRANSFER_DST and \
               state.cache.isValid(STAGE_TRANSFER, ACC_TRANSFER_WRITE):
                ops.append(OP_BUFFER_FILL)
                ops.append(OP_BUFFER_UPDATE)
                ops.append(OP_BUFFER_COPY_FROM_BUFFER)
                ops.append(OP_BUFFER_COPY_FROM_IMAGE)
            if usage & USAGE_TRANSFER_SRC and state.memoryDefined and \
               state.cache.isValid(STAGE_TRANSFER, ACC_TRANSFER_READ):
                ops.append(OP_BUFFER_COPY_TO_BUFFER)
                ops.append(OP_BUFFER_COPY_TO_IMAGE)

        if state.hasBoundImageMemory and \
           (state.imageLayout == LAYOUT_UNDEFINED or getNumberOfSupportedLayouts(usage) > 1):
            ops.append(OP_IMAGE_TRANSITION_LAYOUT)
            if usage & USAGE_TRANSFER_DST and \
               (state.imageLayout == LAYOUT_GENERAL or
                state.imageLayout == LAYOUT_TRANSFER_DST_OPTIMAL) and \
               state.cache.isValid(STAGE_TRANSFER, ACC_TRANSFER_WRITE):
                ops.append(OP_IMAGE_COPY_FROM_BUFFER)
                ops.append(OP_IMAGE_COPY_FROM_IMAGE)
                ops.append(OP_IMAGE_BLIT_FROM_IMAGE)
            if usage & USAGE_TRANSFER_SRC and \
               (state.imageLayout == LAYOUT_GENERAL or
                state.imageLayout == LAYOUT_TRANSFER_SRC_OPTIMAL) and \
               state.imageDefined and \
               state.cache.isValid(STAGE_TRANSFER, ACC_TRANSFER_READ):
                ops.append(OP_IMAGE_COPY_TO_BUFFER)
                ops.append(OP_IMAGE_COPY_TO_IMAGE)
                ops.append(OP_IMAGE_BLIT_TO_IMAGE)

        if len(ops) == 0 or not state.commandBufferIsEmpty:
            ops.append(OP_SECONDARY_COMMAND_BUFFER_END)

    elif state.stage == STAGE_RENDER_PASS:
        if (usage & USAGE_VERTEX_BUFFER) and state.memoryDefined and state.hasBoundBufferMemory and \
           state.cache.isValid(STAGE_VERTEX_INPUT, ACC_VERTEX_ATTRIBUTE_READ):
            ops.append(OP_RENDER_VERTEX_BUFFER)
        if (usage & USAGE_INDEX_BUFFER) and state.memoryDefined and state.hasBoundBufferMemory and \
           state.cache.isValid(STAGE_VERTEX_INPUT, ACC_INDEX_READ):
            ops.append(OP_RENDER_INDEX_BUFFER)
        if (usage & USAGE_UNIFORM_BUFFER) and state.memoryDefined and state.hasBoundBufferMemory:
            if state.cache.isValid(STAGE_VERTEX_SHADER, ACC_UNIFORM_READ):
                ops.append(OP_RENDER_VERTEX_UNIFORM_BUFFER)
            if state.cache.isValid(STAGE_FRAGMENT_SHADER, ACC_UNIFORM_READ):
                ops.append(OP_RENDER_FRAGMENT_UNIFORM_BUFFER)
        if (usage & USAGE_UNIFORM_TEXEL_BUFFER) and state.memoryDefined and state.hasBoundBufferMemory:
            if state.cache.isValid(STAGE_VERTEX_SHADER, ACC_SHADER_READ):
                ops.append(OP_RENDER_VERTEX_UNIFORM_TEXEL_BUFFER)
            if state.cache.isValid(STAGE_FRAGMENT_SHADER, ACC_SHADER_READ):
                ops.append(OP_RENDER_FRAGMENT_UNIFORM_TEXEL_BUFFER)
        if (usage & USAGE_STORAGE_BUFFER) and state.memoryDefined and state.hasBoundBufferMemory:
            if state.cache.isValid(STAGE_VERTEX_SHADER, ACC_SHADER_READ):
                ops.append(OP_RENDER_VERTEX_STORAGE_BUFFER)
            if state.cache.isValid(STAGE_FRAGMENT_SHADER, ACC_SHADER_READ):
                ops.append(OP_RENDER_FRAGMENT_STORAGE_BUFFER)
        if (usage & USAGE_STORAGE_TEXEL_BUFFER) and state.memoryDefined and state.hasBoundBufferMemory:
            if state.cache.isValid(STAGE_VERTEX_SHADER, ACC_SHADER_READ):
                ops.append(OP_RENDER_VERTEX_STORAGE_TEXEL_BUFFER)
            if state.cache.isValid(STAGE_FRAGMENT_SHADER, ACC_SHADER_READ):
                ops.append(OP_RENDER_FRAGMENT_STORAGE_TEXEL_BUFFER)
        if (usage & USAGE_STORAGE_IMAGE) and state.imageDefined and state.hasBoundImageMemory and \
           state.imageLayout == LAYOUT_GENERAL:
            if state.cache.isValid(STAGE_VERTEX_SHADER, ACC_SHADER_READ):
                ops.append(OP_RENDER_VERTEX_STORAGE_IMAGE)
            if state.cache.isValid(STAGE_FRAGMENT_SHADER, ACC_SHADER_READ):
                ops.append(OP_RENDER_FRAGMENT_STORAGE_IMAGE)
        if (usage & USAGE_SAMPLED_IMAGE) and state.imageDefined and state.hasBoundImageMemory and \
           (state.imageLayout == LAYOUT_GENERAL or state.imageLayout == LAYOUT_SHADER_READ_ONLY_OPTIMAL):
            if state.cache.isValid(STAGE_VERTEX_SHADER, ACC_SHADER_READ):
                ops.append(OP_RENDER_VERTEX_SAMPLED_IMAGE)
            if state.cache.isValid(STAGE_FRAGMENT_SHADER, ACC_SHADER_READ):
                ops.append(OP_RENDER_FRAGMENT_SAMPLED_IMAGE)
        if not state.renderPassIsEmpty:
            ops.append(OP_RENDERPASS_END)
    else:
        raise RuntimeError("Unknown stage")

    return ops


# --------------------------------------------------------------------------
# applyOp  (lines 8476-8870)
# --------------------------------------------------------------------------
def applyOp(state, memory_host_coherent, op, usage):
    rng = state.rng
    if op == OP_MAP:
        state.mapped = True
    elif op == OP_UNMAP:
        state.mapped = False
    elif op == OP_MAP_FLUSH:
        state.hostFlushed = True
    elif op == OP_MAP_INVALIDATE:
        state.hostInvalidated = True
    elif op == OP_MAP_READ:
        rng.getUint32()
    elif op == OP_MAP_WRITE:
        if not memory_host_coherent:
            state.hostFlushed = False
        state.memoryDefined = True
        state.imageDefined = False
        state.imageLayout = LAYOUT_UNDEFINED
        rng.getUint32()
    elif op == OP_MAP_MODIFY:
        if not memory_host_coherent:
            state.hostFlushed = False
        rng.getUint32()
    elif op == OP_BUFFER_CREATE:
        state.hasBuffer = True
    elif op == OP_BUFFER_DESTROY:
        state.hasBuffer = False
        state.hasBoundBufferMemory = False
    elif op == OP_BUFFER_BINDMEMORY:
        state.hasBoundBufferMemory = True
    elif op == OP_IMAGE_CREATE:
        state.hasImage = True
    elif op == OP_IMAGE_DESTROY:
        state.hasImage = False
        state.hasBoundImageMemory = False
        state.imageLayout = LAYOUT_UNDEFINED
        state.imageDefined = False
    elif op == OP_IMAGE_BINDMEMORY:
        state.hasBoundImageMemory = True
    elif op == OP_IMAGE_TRANSITION_LAYOUT:
        srcLayout = state.imageLayout if rng.getFloat() < np.float32(0.9) else LAYOUT_UNDEFINED
        dstLayout = getRandomNextLayout(rng, usage, srcLayout)
        dirtySrcStages, dirtySrcAccesses, dirtyDstStages, dirtyDstAccesses = \
            state.cache.getFullBarrier()
        srcStages = dirtySrcStages
        srcAccesses = dirtySrcAccesses
        dstStages = state.cache.m_allowedStages & rng.getUint32()
        dstAccesses = state.cache.m_allowedAccesses & rng.getUint32()
        if dstStages == 0:
            dstStages = state.cache.m_allowedStages
        if srcStages == 0:
            srcStages = dstStages
        dstAccesses = removeIllegalAccessFlags(dstAccesses, dstStages)
        srcAccesses = removeIllegalAccessFlags(srcAccesses, srcStages)
        if srcLayout == LAYOUT_UNDEFINED:
            state.imageDefined = False
        state.commandBufferIsEmpty = False
        state.imageLayout = dstLayout
        state.memoryDefined = False
        state.cache.imageLayoutBarrier(srcStages, srcAccesses, dstStages, dstAccesses)
    elif op == OP_QUEUE_WAIT_FOR_IDLE:
        state.queueIdle = True
        state.cache.waitForIdle()
    elif op == OP_DEVICE_WAIT_FOR_IDLE:
        state.queueIdle = True
        state.deviceIdle = True
        state.cache.waitForIdle()
    elif op == OP_COMMAND_BUFFER_BEGIN:
        state.stage = STAGE_COMMAND_BUFFER
        state.commandBufferIsEmpty = True
        state.cache.submitCommandBuffer()
    elif op == OP_COMMAND_BUFFER_END:
        state.stage = STAGE_HOST
        state.queueIdle = False
        state.deviceIdle = False
    elif op == OP_SECONDARY_COMMAND_BUFFER_BEGIN:
        state.stage = STAGE_SECONDARY_COMMAND_BUFFER
        state.primaryCommandBufferIsEmpty = state.commandBufferIsEmpty
        state.commandBufferIsEmpty = True
    elif op == OP_SECONDARY_COMMAND_BUFFER_END:
        state.stage = STAGE_COMMAND_BUFFER
        state.commandBufferIsEmpty = state.primaryCommandBufferIsEmpty
    elif op in (OP_BUFFER_COPY_FROM_BUFFER, OP_BUFFER_COPY_FROM_IMAGE,
                OP_BUFFER_UPDATE, OP_BUFFER_FILL):
        rng.getUint32()
        if not memory_host_coherent:
            state.hostInvalidated = False
        state.commandBufferIsEmpty = False
        state.memoryDefined = True
        state.imageDefined = False
        state.imageLayout = LAYOUT_UNDEFINED
        state.cache.perform(STAGE_TRANSFER, ACC_TRANSFER_WRITE)
    elif op in (OP_BUFFER_COPY_TO_BUFFER, OP_BUFFER_COPY_TO_IMAGE):
        state.commandBufferIsEmpty = False
        state.cache.perform(STAGE_TRANSFER, ACC_TRANSFER_READ)
    elif op == OP_IMAGE_BLIT_FROM_IMAGE:
        _b = rng.getBool()
        BLITLOG.append(("FROM", _b))
        # C++ falls through into the OP_IMAGE_COPY_FROM_* case -> also getUint32()
        rng.getUint32()
        if not memory_host_coherent:
            state.hostInvalidated = False
        state.commandBufferIsEmpty = False
        state.memoryDefined = False
        state.imageDefined = True
        state.cache.perform(STAGE_TRANSFER, ACC_TRANSFER_WRITE)
    elif op in (OP_IMAGE_COPY_FROM_BUFFER, OP_IMAGE_COPY_FROM_IMAGE):
        rng.getUint32()
        if not memory_host_coherent:
            state.hostInvalidated = False
        state.commandBufferIsEmpty = False
        state.memoryDefined = False
        state.imageDefined = True
        state.cache.perform(STAGE_TRANSFER, ACC_TRANSFER_WRITE)
    elif op == OP_IMAGE_BLIT_TO_IMAGE:
        rng.getBool()
        # fallthrough
        state.commandBufferIsEmpty = False
        state.cache.perform(STAGE_TRANSFER, ACC_TRANSFER_READ)
    elif op in (OP_IMAGE_COPY_TO_BUFFER, OP_IMAGE_COPY_TO_IMAGE):
        state.commandBufferIsEmpty = False
        state.cache.perform(STAGE_TRANSFER, ACC_TRANSFER_READ)
    elif op in (OP_PIPELINE_BARRIER_GLOBAL, OP_PIPELINE_BARRIER_BUFFER,
                OP_PIPELINE_BARRIER_IMAGE):
        dirtySrcStages, dirtySrcAccesses, dirtyDstStages, dirtyDstAccesses = \
            state.cache.getFullBarrier()
        srcStages = dirtySrcStages & rng.getUint32()
        srcAccesses = dirtySrcAccesses & rng.getUint32()
        dstStages = dirtyDstStages & rng.getUint32()
        dstAccesses = dirtyDstAccesses & rng.getUint32()
        if srcStages == 0:
            srcStages = dirtySrcStages
        if dstStages == 0:
            dstStages = dirtyDstStages
        if srcStages == 0:
            srcStages = dstStages
        dstAccesses = removeIllegalAccessFlags(dstAccesses, dstStages)
        srcAccesses = removeIllegalAccessFlags(srcAccesses, srcStages)
        state.commandBufferIsEmpty = False
        state.cache.barrier(srcStages, srcAccesses, dstStages, dstAccesses)
    elif op == OP_RENDERPASS_BEGIN:
        state.renderPassIsEmpty = True
        state.stage = STAGE_RENDER_PASS
    elif op == OP_RENDERPASS_END:
        state.renderPassIsEmpty = True
        state.stage = STAGE_COMMAND_BUFFER
    elif op == OP_RENDER_VERTEX_BUFFER:
        state.renderPassIsEmpty = False
        state.cache.perform(STAGE_VERTEX_INPUT, ACC_VERTEX_ATTRIBUTE_READ)
    elif op == OP_RENDER_INDEX_BUFFER:
        state.renderPassIsEmpty = False
        state.cache.perform(STAGE_VERTEX_INPUT, ACC_INDEX_READ)
    elif op == OP_RENDER_VERTEX_UNIFORM_BUFFER:
        state.renderPassIsEmpty = False
        state.cache.perform(STAGE_VERTEX_SHADER, ACC_UNIFORM_READ)
    elif op == OP_RENDER_FRAGMENT_UNIFORM_BUFFER:
        state.renderPassIsEmpty = False
        state.cache.perform(STAGE_FRAGMENT_SHADER, ACC_UNIFORM_READ)
    elif op in (OP_RENDER_VERTEX_STORAGE_BUFFER, OP_RENDER_VERTEX_STORAGE_TEXEL_BUFFER,
                OP_RENDER_VERTEX_UNIFORM_TEXEL_BUFFER):
        state.renderPassIsEmpty = False
        state.cache.perform(STAGE_VERTEX_SHADER, ACC_SHADER_READ)
    elif op in (OP_RENDER_FRAGMENT_STORAGE_BUFFER, OP_RENDER_FRAGMENT_STORAGE_TEXEL_BUFFER,
                OP_RENDER_FRAGMENT_UNIFORM_TEXEL_BUFFER):
        state.renderPassIsEmpty = False
        state.cache.perform(STAGE_FRAGMENT_SHADER, ACC_SHADER_READ)
    elif op in (OP_RENDER_FRAGMENT_STORAGE_IMAGE, OP_RENDER_FRAGMENT_SAMPLED_IMAGE):
        state.renderPassIsEmpty = False
        state.cache.perform(STAGE_FRAGMENT_SHADER, ACC_SHADER_READ)
    elif op in (OP_RENDER_VERTEX_STORAGE_IMAGE, OP_RENDER_VERTEX_SAMPLED_IMAGE):
        state.renderPassIsEmpty = False
        state.cache.perform(STAGE_VERTEX_SHADER, ACC_SHADER_READ)
    else:
        raise RuntimeError("Unknown op %r" % op)


# --------------------------------------------------------------------------
# Generation loops  (createCommands / createCmdCommands /
#                    createRenderPassCommands / createSecondaryCmdCommands)
#
# opNdx is a shared mutable counter (list of one int) because C++ passes
# size_t& through the recursion.  We record a flat event log:
#   ("op", op)                              a selected op
#   ("cmdbuf_begin",)/("cmdbuf_end",)       SubmitCommandBuffer boundaries
#   ("secondary_begin",)/("secondary_end",) ExecuteSecondaryCommandBuffer
#   ("renderpass_begin",)/("renderpass_end",) SubmitRenderPass
# so the structure can be compared against the QPA <Section> ordering.
# --------------------------------------------------------------------------
# OPPICK recorder — mirrors the g6lc_logOpPick instrumentation added to
# vktMemoryPipelineBarrierTests.cpp so the Python FSM can be diffed against a
# real deqp-vk op log.  Each entry: (where, stage, chosen, avail_tuple).
OPPICKS = []

# (dir, scale_bool) for each OP_IMAGE_BLIT_*_IMAGE applyOp; scale_bool True =>
# factory drew BLIT_SCALE_20 (2x, our XBlitCvt refuses), False => BLIT_SCALE_10.
BLITLOG = []


def _oppick(where, state, ops, op):
    c = state.cache
    OPPICKS.append((where, state.stage, op, tuple(ops),
                    state.imageLayout, int(state.imageDefined), int(state.memoryDefined),
                    int(c.isValid(STAGE_TRANSFER, ACC_TRANSFER_WRITE)),
                    int(c.isValid(STAGE_TRANSFER, ACC_TRANSFER_READ))))


def dump_oppicks():
    out = []
    for where, stage, chosen, avail, lay, idef, mdef, tw, tr in OPPICKS:
        out.append("OPPICK %s stage=%d chosen=%d imgLay=%d imgDef=%d memDef=%d TW=%d TR=%d avail=[%s]"
                   % (where, stage, chosen, lay, idef, mdef, tw, tr,
                      ",".join(str(a) for a in avail)))
    return "\n".join(out) + ("\n" if out else "")


def createRenderPassCommands(nextOpRng, state, usage, opNdx, opCount, events):
    # OP_RENDERPASS_BEGIN was already applyOp'd by the caller.  Faithful port of
    # the C++ `for (; opNdx < opCount; opNdx++)` loop: the increment runs at the
    # END of each non-break iteration, AFTER any nested work.
    while opNdx[0] < opCount:
        ops = getAvailableOps(state, usage)
        op = nextOpRng.choose(ops)
        events.append(("op", op))
        if op == OP_RENDERPASS_END:
            break                       # for-loop increment skipped on break
        applyOp(state, state.host_coherent, op, usage)
        opNdx[0] += 1
    applyOp(state, state.host_coherent, OP_RENDERPASS_END, usage)
    events.append(("renderpass_end",))


def createSecondaryCmdCommands(nextOpRng, state, usage, opNdx, opCount, events):
    # OP_SECONDARY_COMMAND_BUFFER_BEGIN already applyOp'd by the caller.
    events.append(("secondary_begin",))
    while opNdx[0] < opCount:
        ops = getAvailableOps(state, usage)
        op = nextOpRng.choose(ops)
        events.append(("op", op))
        if op == OP_SECONDARY_COMMAND_BUFFER_END:
            break
        applyOp(state, state.host_coherent, op, usage)
        opNdx[0] += 1
    applyOp(state, state.host_coherent, OP_SECONDARY_COMMAND_BUFFER_END, usage)
    events.append(("secondary_end",))


def createCmdCommands(nextOpRng, state, usage, opNdx, opCount, events):
    # a mostly-full barrier orders this buffer wrt previous (not an op event)
    while opNdx[0] < opCount:
        ops = getAvailableOps(state, usage)
        op = nextOpRng.choose(ops)
        events.append(("op", op))
        if op == OP_COMMAND_BUFFER_END:
            break
        if op == OP_RENDERPASS_BEGIN:
            applyOp(state, state.host_coherent, op, usage)
            createRenderPassCommands(nextOpRng, state, usage, opNdx, opCount, events)
        elif op == OP_SECONDARY_COMMAND_BUFFER_BEGIN:
            applyOp(state, state.host_coherent, op, usage)
            createSecondaryCmdCommands(nextOpRng, state, usage, opNdx, opCount, events)
        else:
            applyOp(state, state.host_coherent, op, usage)
        opNdx[0] += 1                   # parent for-loop increment (post-recursion)
    applyOp(state, state.host_coherent, OP_COMMAND_BUFFER_END, usage)
    events.append(("cmdbuf_end",))


def createCommands(seed, usage, host_coherent, opCount, events):
    state = State(usage, seed, host_coherent)
    nextOpRng = DeRandom(_u32(seed ^ 12930809))
    opNdx = [0]
    while opNdx[0] < opCount:
        ops = getAvailableOps(state, usage)
        op = nextOpRng.choose(ops)
        events.append(("op", op))
        if op == OP_COMMAND_BUFFER_BEGIN:
            applyOp(state, state.host_coherent, op, usage)
            events.append(("cmdbuf_begin",))
            createCmdCommands(nextOpRng, state, usage, opNdx, opCount, events)
        else:
            applyOp(state, state.host_coherent, op, usage)
        opNdx[0] += 1                   # top for-loop increment
    # resource cleanup ops (QueueWaitIdle/Destroy*) are appended by the real code
    # but they are host-stage and do not consume RNG-relevant state for our purpose.
    return state


# --------------------------------------------------------------------------
# Command-tree reconstruction.
#
# Mirrors the generation loops above but returns the m_commands hierarchy so we
# can index "N:OpName" exactly like SubmitCommandBuffer::verify does:
#   * SubmitCommandBuffer (primary): sub[0] = intro PipelineBarrier, then ops.
#   * ExecuteSecondaryCommandBuffer / SubmitRenderPass: NO intro barrier.
#   * a SECONDARY_BEGIN..END block collapses to ONE ("secondary",[...]) node;
#     RENDERPASS_BEGIN..END to ONE ("renderpass",[...]) node; every other op is
#     a leaf ("op", opname).
# Node tuples: ("host",op) ("cmdbuf",subs) ("secondary",subs) ("renderpass",subs)
#              ("op",opname)
# --------------------------------------------------------------------------
def _node_name(node):
    kind = node[0]
    if kind in ("op", "host"):
        return node[1] if isinstance(node[1], str) else OP_NAMES.get(node[1], "op%d" % node[1])
    return {"cmdbuf": "SubmitCommandBuffer", "secondary": "ExecuteSecondaryCommandBuffer",
            "renderpass": "SubmitRenderPass"}[kind]


def _build_renderpass(nextOpRng, state, usage, opNdx, opCount):
    subs = []
    while opNdx[0] < opCount:
        ops = getAvailableOps(state, usage)
        op = nextOpRng.choose(ops)
        _oppick("rp", state, ops, op)
        if op == OP_RENDERPASS_END:
            break
        applyOp(state, state.host_coherent, op, usage)
        subs.append(("op", OP_NAMES.get(op, "op%d" % op)))
        opNdx[0] += 1
    applyOp(state, state.host_coherent, OP_RENDERPASS_END, usage)
    return ("renderpass", subs)


def _build_secondary(nextOpRng, state, usage, opNdx, opCount):
    subs = []
    while opNdx[0] < opCount:
        ops = getAvailableOps(state, usage)
        op = nextOpRng.choose(ops)
        _oppick("sec", state, ops, op)
        if op == OP_SECONDARY_COMMAND_BUFFER_END:
            break
        applyOp(state, state.host_coherent, op, usage)
        subs.append(("op", OP_NAMES.get(op, "op%d" % op)))
        opNdx[0] += 1
    applyOp(state, state.host_coherent, OP_SECONDARY_COMMAND_BUFFER_END, usage)
    return ("secondary", subs)


def _build_cmdbuf(nextOpRng, state, usage, opNdx, opCount):
    subs = [("op", "PipelineBarrier")]          # intro mostly-full barrier = index 0
    while opNdx[0] < opCount:
        ops = getAvailableOps(state, usage)
        op = nextOpRng.choose(ops)
        _oppick("cmd", state, ops, op)
        if op == OP_COMMAND_BUFFER_END:
            break
        if op == OP_RENDERPASS_BEGIN:
            applyOp(state, state.host_coherent, op, usage)
            subs.append(_build_renderpass(nextOpRng, state, usage, opNdx, opCount))
        elif op == OP_SECONDARY_COMMAND_BUFFER_BEGIN:
            applyOp(state, state.host_coherent, op, usage)
            subs.append(_build_secondary(nextOpRng, state, usage, opNdx, opCount))
        else:
            applyOp(state, state.host_coherent, op, usage)
            subs.append(("op", OP_NAMES.get(op, "op%d" % op)))
        opNdx[0] += 1
    applyOp(state, state.host_coherent, OP_COMMAND_BUFFER_END, usage)
    return ("cmdbuf", subs)


def gen_tree_seed(seed, usage, host_coherent, opCount=50):
    """Run the FSM for an explicit seed (bypasses mt/iter -> seed derivation)."""
    global OPPICKS
    OPPICKS = []
    state = State(usage, seed, host_coherent)
    nextOpRng = DeRandom(_u32(seed ^ 12930809))
    opNdx = [0]
    top = []
    while opNdx[0] < opCount:
        ops = getAvailableOps(state, usage)
        op = nextOpRng.choose(ops)
        _oppick("top", state, ops, op)
        if op == OP_COMMAND_BUFFER_BEGIN:
            applyOp(state, state.host_coherent, op, usage)
            top.append(_build_cmdbuf(nextOpRng, state, usage, opNdx, opCount))
        else:
            applyOp(state, state.host_coherent, op, usage)
            top.append(("host", OP_NAMES.get(op, "op%d" % op)))
        opNdx[0] += 1
    return seed, top


def gen_tree(memory_type_ndx, iteration, memory_type_count, host_coherent, usage,
             opCount=50):
    seed = _u32(2830980989 ^ deUint32Hash(_u32(iteration * memory_type_count +
                                                    memory_type_ndx)))
    return gen_tree_seed(seed, usage, host_coherent, opCount)


def dump_tree(node, depth=0, out=None):
    if out is None:
        out = []
    pad = "  " * depth
    if node[0] in ("cmdbuf", "secondary", "renderpass"):
        out.append(f"{pad}{_node_name(node)}")
        for i, s in enumerate(node[1]):
            out.append(f"{pad}  [{i}] ", end="")
            # inline leaf names, recurse for containers
            if s[0] in ("cmdbuf", "secondary", "renderpass"):
                out.append("")
                dump_tree(s, depth + 2, out)
            else:
                out[-1] += _node_name(s) + "\n"
    else:
        out.append(f"{pad}{_node_name(node)}\n")
    return out


# --------------------------------------------------------------------------
# Driver
# --------------------------------------------------------------------------
def gen(memory_type_ndx, iteration, memory_type_count, host_coherent, usage,
        opCount=50):
    seed = _u32(2830980989 ^ deUint32Hash(_u32(iteration * memory_type_count +
                                                    memory_type_ndx)))
    events = []
    createCommands(seed, usage, host_coherent, opCount, events)
    return seed, events


def main():
    # all_device: memoryTypeCount=2 (from QPA), type0 props=1 (not coherent),
    # type1 props=15 (coherent).  iterationCount=5, opCount=50.
    memory_type_count = 2
    host_coherent = [False, True]   # type0 props=1 -> no HOST_COHERENT; type1 props=15 -> yes

    which = sys.argv[1] if len(sys.argv) > 1 else "all"

    # oppick mode: emit the C++-format OPPICK stream for diffing against an
    # instrumented deqp-vk stderr log.  Usage:
    #   cts_barrier_repro.py oppick            -> all 10 (mt,it) seeds
    #   cts_barrier_repro.py oppick <seed> <hc>-> one explicit seed
    if which == "oppick":
        if len(sys.argv) >= 4:
            seed = _u32(int(sys.argv[2], 0))
            hc = bool(int(sys.argv[3]))
            gen_tree_seed(seed, USAGE_ALL_DEVICE, hc, 50)
            print("OPPICK-SEED %u" % seed)
            print(dump_oppicks(), end="")
            return
        for mt in range(memory_type_count):
            for it in range(5):
                seed = _u32(2830980989 ^ deUint32Hash(
                    _u32(it * memory_type_count + mt)))
                gen_tree_seed(seed, USAGE_ALL_DEVICE, host_coherent[mt], 50)
                print("OPPICK-SEED %u" % seed)
                print(dump_oppicks(), end="")
        return

    for mt in range(memory_type_count):
        for it in range(5):
            if which != "all" and which != f"{mt}:{it}":
                continue
            seed, events = gen(mt, it, memory_type_count, host_coherent[mt],
                               USAGE_ALL_DEVICE, 50)
            # count op types
            from collections import Counter
            c = Counter(e[1] for e in events if e[0] == "op")
            print(f"=== MemoryType{mt} iter{it} seed={seed:#010x} ===")
            print("  structure:", " ".join(
                ("[" + e[0].upper() + "]") if e[0] != "op" else OP_NAMES.get(e[1], "?")
                for e in events))
            print("  counts:", {OP_NAMES.get(k, k): v for k, v in sorted(c.items())})
            print()


if __name__ == "__main__":
    main()
