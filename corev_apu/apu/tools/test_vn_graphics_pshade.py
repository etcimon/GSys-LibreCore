# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Fragment-shader stage over FS-in records; no raster/ROP/descriptor admission."""
import struct
import unittest

import test_vn_transfers as transfer_fixture
from test_vn_graphics_shade import vs_program
from vn_compute import ShaderBinding
from vn_graphics_fetch import ATTR_STRIDE
from vn_graphics_pshade import FragmentShade


def f32bits(value):
    return struct.unpack('<I', struct.pack('<f', value))[0]


def fs_program(kind='color', desc=False, ubo=False, flat=False,
               nopersp=False):
    """Hand-assembled fragment modules (self-contained; the frozen cohort
    ships sources only):
    - 'color': color(loc0) = vcol(loc0) passthrough.
    - 'fc':    color(loc0) = vec4(FragCoord.x, FragCoord.y, 0, 1).
    desc=True adds an unused DescriptorSet/Binding UBO for refusal tests;
    ubo=True loads that float into every color channel so descriptor reads
    are observable in the color records; flat=True decorates the vcol input
    Flat so raster uses the provoking vertex's value (no interpolation);
    nopersp=True decorates it NoPerspective so raster skips the w divide."""
    words = [0x07230203, 0x00010300, 0, 40, 0]

    def emit(opcode, *values):
        words.extend(((len(values) + 1) << 16 | opcode, *values))

    emit(17, 1)                     # OpCapability Shader
    emit(14, 0, 1)                  # OpMemoryModel Logical GLSL450
    if kind == 'color':
        entry, lbl, c, v = 9, 10, 11, None
        emit(15, 4, entry, 0x6E69616D, 0, 7, 8)      # EntryPoint Fragment
        emit(16, entry, 7)                           # OriginUpperLeft
        emit(71, 7, 30, 0)                           # vcol  Location 0
        if flat:
            emit(71, 7, 14)                          # vcol  Flat
        if nopersp:
            emit(71, 7, 13)                          # vcol  NoPerspective
        emit(71, 8, 30, 0)                           # color Location 0
    else:
        entry, lbl, c, v = 11, 12, 13, 16
        emit(15, 4, entry, 0x6E69616D, 0, 7, 8)      # EntryPoint Fragment
        emit(16, entry, 7)                           # OriginUpperLeft
        emit(71, 7, 11, 15)                          # fc    BuiltIn FragCoord
        emit(71, 8, 30, 0)                           # color Location 0
    if desc or ubo:
        emit(71, 14, 34, 0)                          # ubo   DescriptorSet 0
        emit(71, 14, 33, 0)                          # ubo   Binding 0
        emit(71, 22, 2)                              # %22    Block
        emit(72, 22, 0, 35, 0)                       # %22.0  Offset 0
    emit(19, 1)                     # %void
    emit(33, 2, 1)                  # %fnty
    emit(22, 3, 32)                 # %float
    emit(23, 4, 3, 4)               # %v4f
    emit(32, 5, 1, 4)               # ptr Input v4f
    emit(32, 6, 3, 4)               # ptr Output v4f
    if desc or ubo:
        emit(30, 22, 3)             # %22 = struct{float}
        emit(21, 24, 32, 1)         # %24 = int
        emit(32, 23, 2, 3)          # %23 = ptr Uniform float
        emit(32, 15, 2, 22)         # %15 = ptr Uniform %22
        emit(43, 24, 25, 0)         # %25 = int 0 (access-chain index)
    emit(59, 5, 7, 1)               # vcol/fc input
    emit(59, 6, 8, 3)               # color output
    if desc or ubo:
        emit(59, 15, 14, 2)         # ubo (Uniform)
    if kind != 'color':
        emit(43, 3, 9, 0)           # f0
        emit(43, 3, 10, 0x3F800000) # f1
    emit(54, 1, entry, 0, 2)        # main()
    emit(248, lbl)                  # label
    emit(61, 4, c, 7)               # c = Load v4f input
    if ubo:
        emit(65, 23, 26, 14, 25)    # %26 = AccessChain %23 %14 %25 -> member
        emit(61, 3, 20, 26)         # uf  = Load float %26
        emit(80, 4, 21, 20, 20, 20, 20)  # vec4(uf,uf,uf,uf)
        emit(62, 8, 21)             # Store color
    elif kind == 'color':
        emit(62, 8, c)              # Store color c
    else:
        emit(81, 3, 14, c, 0)       # x = c.x
        emit(81, 3, 15, c, 1)       # y = c.y
        emit(80, 4, v, 14, 15, 9, 10)  # vec4(x, y, 0, 1)
        emit(62, 8, v)              # Store color v
    emit(253)                       # Return
    emit(56)                        # FunctionEnd
    return tuple(words)


def fs_image_program(binding=0, coord=(1, 1), per_pixel=False, combined=False):
    """Fragment module fetching a texel from a SAMPLED_IMAGE (kind 2) or,
    with combined=True, a COMBINED_IMAGE_SAMPLER (kind 1) UNIFORMCONST
    descriptor, writing it to color(loc0).  `per_pixel` derives the ivec2
    fetch coordinate from FragCoord.xy (pixel-center floats truncated to
    the fragment index); otherwise `coord` is a constant ivec2.  OpImageFetch
    ignores the sampler state, so the combined form exercises kind-1
    descriptor admission without filtered sampling."""
    words = [0x07230203, 0x00010300, 0, 48, 0]

    def emit(opcode, *values):
        words.extend(((len(values) + 1) << 16 | opcode, *values))

    entry, lbl = 9, 10
    emit(17, 1)                     # OpCapability Shader
    emit(14, 0, 1)                  # OpMemoryModel Logical GLSL450
    emit(15, 4, entry, 0x6E69616D, 0, 7, 8)      # EntryPoint Fragment main
    emit(16, entry, 7)              # OriginUpperLeft
    emit(71, 7, 11, 15)             # fc    BuiltIn FragCoord
    emit(71, 8, 30, 0)              # color Location 0
    emit(71, 17, 34, 0)             # img   DescriptorSet 0
    emit(71, 17, 33, binding)       # img   Binding N
    emit(19, 1)                     # %void
    emit(33, 2, 1)                  # %fnty
    emit(22, 3, 32)                 # %float
    emit(23, 4, 3, 4)               # %v4f
    emit(21, 11, 32, 1)             # %int
    emit(23, 12, 11, 2)             # %ivec2
    emit(25, 13, 3, 1, 0, 0, 0, 1, 0)  # %image2D sampled
    if combined:
        emit(27, 40, 13)            # %40 = OpTypeSampledImage %13 (kind 1)
    emit(32, 14, 0, 40 if combined else 13)  # ptr UniformConstant image
    emit(32, 15, 1, 4)              # ptr Input v4f
    emit(32, 16, 3, 4)              # ptr Output v4f
    emit(59, 15, 7, 1)              # fc input
    emit(59, 16, 8, 3)              # color output
    emit(59, 14, 17, 0)             # img (UniformConstant)
    if per_pixel:
        emit(54, 1, entry, 0, 2)    # main()
        emit(248, lbl)              # label
        emit(61, 4, 18, 7)          # %18 = Load FragCoord v4f
        emit(81, 3, 19, 18, 0)      # %19 = fc.x
        emit(81, 3, 20, 18, 1)      # %20 = fc.y
        emit(110, 11, 21, 19)       # %21 = int(fc.x)
        emit(110, 11, 22, 20)       # %22 = int(fc.y)
        emit(80, 12, 23, 21, 22)    # %23 = ivec2(x, y)
        emit(61, 40 if combined else 13, 24, 17)  # %24 = Load image %17
        emit(95, 4, 25, 24, 23)     # %25 = ImageFetch %24 %23
        emit(62, 8, 25)             # Store color %25
    else:
        emit(43, 11, 18, coord[0])  # int x
        emit(43, 11, 19, coord[1])  # int y
        emit(44, 12, 20, 18, 19)    # ivec2 coord
        emit(54, 1, entry, 0, 2)    # main()
        emit(248, lbl)              # label
        emit(61, 40 if combined else 13, 21, 17)  # %21 = Load image %17
        emit(95, 4, 22, 21, 20)     # %22 = ImageFetch %21 %20
        emit(62, 8, 22)             # Store color %22
    emit(253)                       # Return
    emit(56)                        # FunctionEnd
    return tuple(words)


def fs_image_store_program(binding=0, coord=(1, 1), per_pixel=False):
    """Fragment module storing a constant vec4 texel into a STORAGE_IMAGE
    (kind 3) UNIFORMCONST descriptor via OpImageWrite.  `per_pixel` derives
    the ivec2 coordinate from FragCoord.xy; otherwise `coord` is constant."""
    words = [0x07230203, 0x00010300, 0, 48, 0]

    def emit(opcode, *values):
        words.extend(((len(values) + 1) << 16 | opcode, *values))

    entry, lbl = 9, 10
    emit(17, 1)                     # OpCapability Shader
    emit(14, 0, 1)                  # OpMemoryModel Logical GLSL450
    emit(15, 4, entry, 0x6E69616D, 0, 7, 8)      # EntryPoint Fragment main
    emit(16, entry, 7)              # OriginUpperLeft
    emit(71, 7, 11, 15)             # fc    BuiltIn FragCoord
    emit(71, 8, 30, 0)              # color Location 0
    emit(71, 17, 34, 0)             # img   DescriptorSet 0
    emit(71, 17, 33, binding)       # img   Binding N
    emit(19, 1)                     # %void
    emit(33, 2, 1)                  # %fnty
    emit(22, 3, 32)                 # %float
    emit(23, 4, 3, 4)               # %v4f
    emit(21, 11, 32, 1)             # %int
    emit(23, 12, 11, 2)             # %ivec2
    emit(25, 13, 3, 1, 0, 0, 0, 2, 0)  # %image2D storage (sampled=2)
    emit(32, 14, 0, 13)             # ptr UniformConstant image
    emit(32, 15, 1, 4)              # ptr Input v4f
    emit(32, 16, 3, 4)              # ptr Output v4f
    emit(59, 15, 7, 1)              # fc input
    emit(59, 16, 8, 3)              # color output
    emit(59, 14, 17, 0)             # img (UniformConstant)
    emit(43, 3, 26, 0)              # f0  = 0.0
    emit(43, 3, 27, 0x3F800000)     # f1  = 1.0
    if per_pixel:
        emit(54, 1, entry, 0, 2)    # main()
        emit(248, lbl)              # label
        emit(61, 4, 18, 7)          # %18 = Load FragCoord v4f
        emit(81, 3, 19, 18, 0)      # %19 = fc.x
        emit(81, 3, 20, 18, 1)      # %20 = fc.y
        emit(110, 11, 21, 19)       # %21 = int(fc.x)
        emit(110, 11, 22, 20)       # %22 = int(fc.y)
        emit(80, 12, 23, 21, 22)    # %23 = ivec2(x, y)
    else:
        emit(43, 11, 18, coord[0])  # int x
        emit(43, 11, 19, coord[1])  # int y
        emit(44, 12, 23, 18, 19)    # ivec2 coord
        emit(54, 1, entry, 0, 2)    # main()
        emit(248, lbl)              # label
    emit(80, 4, 24, 27, 26, 26, 27) # %24 = vec4(1,0,0,1) red texel
    emit(61, 13, 25, 17)            # %25 = Load image %17
    emit(99, 25, 23, 24)            # ImageWrite %25 %23 %24
    emit(253)                       # Return
    emit(56)                        # FunctionEnd
    return tuple(words)


def fs_sample_program(binding=0, u=0.3125, v=0.375, implicit=False,
                      lod=0.0):
    """Fragment module sampling a COMBINED_IMAGE_SAMPLER (kind 1) via
    OpImageSampleExplicitLod (or OpImageSampleImplicitLod with implicit=True)
    at a constant normalized vec2 coordinate, writing the result to
    color(loc0).  With a nearest sampler and constant coords the implicit
    form's zero derivatives clamp to the base mip, resolving to the same
    single texel as explicit LOD 0.  `lod` is the explicit-LOD operand
    (ignored by the implicit form), selecting the mip level."""
    import struct as _st
    ub = _st.unpack('<I', _st.pack('<f', u))[0]
    vb = _st.unpack('<I', _st.pack('<f', v))[0]
    lb = _st.unpack('<I', _st.pack('<f', lod))[0]
    words = [0x07230203, 0x00010300, 0, 48, 0]

    def emit(opcode, *values):
        words.extend(((len(values) + 1) << 16 | opcode, *values))

    emit(17, 1)                     # OpCapability Shader
    emit(14, 0, 1)                  # OpMemoryModel Logical GLSL450
    emit(15, 4, 9, 0x6E69616D, 0, 8)  # EntryPoint Fragment %9 main, iface=[color]
    emit(16, 9, 7)                  # OriginUpperLeft
    emit(71, 8, 30, 0)              # color Location 0
    emit(71, 17, 34, 0)             # img   DescriptorSet 0
    emit(71, 17, 33, binding)       # img   Binding N
    emit(19, 1)                     # %1 void
    emit(33, 2, 1)                  # %2 fnty
    emit(22, 3, 32)                 # %3 float
    emit(23, 4, 3, 4)               # %4 v4f
    emit(23, 5, 3, 2)               # %5 v2f
    emit(25, 13, 3, 1, 0, 0, 0, 1, 0)  # %13 image2D sampled
    emit(27, 40, 13)                # %40 = OpTypeSampledImage %13 (kind 1)
    emit(32, 14, 0, 40)             # %14 = ptr UniformConstant SIMG
    emit(32, 15, 3, 4)              # %15 = ptr Output v4f
    emit(59, 15, 8, 3)              # %8  color output
    emit(59, 14, 17, 0)             # %17 img (UniformConstant)
    emit(43, 3, 18, ub)             # %18 = float u
    emit(43, 3, 19, vb)             # %19 = float v
    emit(44, 5, 20, 18, 19)         # %20 = vec2(u, v)
    emit(43, 3, 21, lb)             # %21 = float lod (LOD operand)
    emit(54, 1, 9, 0, 2)            # %9 main()
    emit(248, 22)                   # label
    emit(61, 40, 23, 17)            # %23 = Load SIMG %17
    if implicit:
        emit(87, 4, 24, 23, 20)     # %24 = ImageSampleImplicitLod %23 %20
    else:
        emit(88, 4, 24, 23, 20, 2, 21)  # %24 = ImageSampleExplicitLod %23 %20 Lod %21
    emit(62, 8, 24)                 # Store color %24
    emit(253)                       # Return
    emit(56)                        # FunctionEnd
    return tuple(words)


def fs_gather_program(binding=0, u=0.35, v=0.4, comp=0):
    """Fragment module gathering a COMBINED_IMAGE_SAMPLER (kind 1) via
    OpImageGather (opcode 96) at a constant normalized vec2 coordinate,
    writing the vec4 footprint result to color(loc0).  The model's gather
    operand order is ResultType, ResultId, SampledImage, Coordinate,
    Component(id whose value &3 selects the channel), ImageOperands mask
    (0 = none).  The result's component gi is the `comp` channel of the
    2x2 footprint texel at SPIR-V corner gi, so it lands directly in the
    RGBA framebuffer channels."""
    import struct as _st
    ub = _st.unpack('<I', _st.pack('<f', u))[0]
    vb = _st.unpack('<I', _st.pack('<f', v))[0]
    words = [0x07230203, 0x00010300, 0, 48, 0]

    def emit(opcode, *values):
        words.extend(((len(values) + 1) << 16 | opcode, *values))

    emit(17, 1)                     # OpCapability Shader
    emit(14, 0, 1)                  # OpMemoryModel Logical GLSL450
    emit(15, 4, 9, 0x6E69616D, 0, 8)  # EntryPoint Fragment %9 main, iface=[color]
    emit(16, 9, 7)                  # OriginUpperLeft
    emit(71, 8, 30, 0)              # color Location 0
    emit(71, 17, 34, 0)             # img   DescriptorSet 0
    emit(71, 17, 33, binding)       # img   Binding N
    emit(19, 1)                     # %1 void
    emit(33, 2, 1)                  # %2 fnty
    emit(22, 3, 32)                 # %3 float
    emit(21, 50, 32, 1)             # %50 = OpTypeInt 32 1 (signed)
    emit(23, 4, 3, 4)               # %4 v4f
    emit(23, 5, 3, 2)               # %5 v2f
    emit(25, 13, 3, 1, 0, 0, 0, 1, 0)  # %13 image2D sampled
    emit(27, 40, 13)                # %40 = OpTypeSampledImage %13 (kind 1)
    emit(32, 14, 0, 40)             # %14 = ptr UniformConstant SIMG
    emit(32, 15, 3, 4)              # %15 = ptr Output v4f
    emit(59, 15, 8, 3)              # %8  color output
    emit(59, 14, 17, 0)             # %17 img (UniformConstant)
    emit(43, 3, 18, ub)             # %18 = float u
    emit(43, 3, 19, vb)             # %19 = float v
    emit(44, 5, 20, 18, 19)         # %20 = vec2(u, v)
    emit(43, 50, 51, comp)          # %51 = OpConstant %50 int comp
    emit(54, 1, 9, 0, 2)            # %9 main()
    emit(248, 22)                   # label
    emit(61, 40, 23, 17)            # %23 = Load SIMG %17
    emit(96, 4, 24, 23, 20, 51, 0)  # %24 = OpImageGather %23 %20 comp=%51
    emit(62, 8, 24)                 # Store color %24
    emit(253)                       # Return
    emit(56)                        # FunctionEnd
    return tuple(words)


def fs_proj_sample_program(binding=0, u=0.6, v=0.7, d=2.0):
    """Fragment module projective-sampling a COMBINED_IMAGE_SAMPLER (kind 1)
    via OpImageSampleProjImplicitLod (opcode 91) at a constant vec3
    coordinate, writing the result to color(loc0).  The model's projective
    forms divide coord.xy by the last component before sampling, so
    (u,v,d) resolves as (u/d, v/d); with d=2 the divided coord lands on a
    different texel than the raw (u,v) would, proving the perspective
    divide.  Operand order: ResultType, ResultId, SampledImage,
    Coordinate(vec3), ImageOperands mask (absent -> implicit, wc=5)."""
    import struct as _st
    ub = _st.unpack('<I', _st.pack('<f', u))[0]
    vb = _st.unpack('<I', _st.pack('<f', v))[0]
    db = _st.unpack('<I', _st.pack('<f', d))[0]
    words = [0x07230203, 0x00010300, 0, 48, 0]

    def emit(opcode, *values):
        words.extend(((len(values) + 1) << 16 | opcode, *values))

    emit(17, 1)                     # OpCapability Shader
    emit(14, 0, 1)                  # OpMemoryModel Logical GLSL450
    emit(15, 4, 9, 0x6E69616D, 0, 8)  # EntryPoint Fragment %9 main, iface=[color]
    emit(16, 9, 7)                  # OriginUpperLeft
    emit(71, 8, 30, 0)              # color Location 0
    emit(71, 17, 34, 0)             # img   DescriptorSet 0
    emit(71, 17, 33, binding)       # img   Binding N
    emit(19, 1)                     # %1 void
    emit(33, 2, 1)                  # %2 fnty
    emit(22, 3, 32)                 # %3 float
    emit(23, 4, 3, 4)               # %4 v4f
    emit(23, 52, 3, 3)              # %52 = v3f (projective coord)
    emit(25, 13, 3, 1, 0, 0, 0, 1, 0)  # %13 image2D sampled
    emit(27, 40, 13)                # %40 = OpTypeSampledImage %13 (kind 1)
    emit(32, 14, 0, 40)             # %14 = ptr UniformConstant SIMG
    emit(32, 15, 3, 4)              # %15 = ptr Output v4f
    emit(59, 15, 8, 3)              # %8  color output
    emit(59, 14, 17, 0)             # %17 img (UniformConstant)
    emit(43, 3, 18, ub)             # %18 = float u
    emit(43, 3, 19, vb)             # %19 = float v
    emit(43, 3, 53, db)             # %53 = float d
    emit(44, 52, 20, 18, 19, 53)    # %20 = OpConstantComposite v3f(u,v,d)
    emit(54, 1, 9, 0, 2)            # %9 main()
    emit(248, 22)                   # label
    emit(61, 40, 23, 17)            # %23 = Load SIMG %17
    emit(91, 4, 24, 23, 20)         # %24 = OpImageSampleProjImplicitLod %23 %20
    emit(62, 8, 24)                 # Store color %24
    emit(253)                       # Return
    emit(56)                        # FunctionEnd
    return tuple(words)


def fs_separate_sample_program(image_binding=0, sampler_binding=1,
                               u=0.3125, v=0.375):
    """Fragment module sampling a SAMPLED_IMAGE (kind 2) and a separate
    SAMPLER (kind 0) merged at runtime by OpSampledImage, then
    OpImageSampleExplicitLod at a constant normalized coord -> color(loc0).
    Exercises the merged-sampler path where the sampler record is fetched
    separately from the image record."""
    import struct as _st
    ub = _st.unpack('<I', _st.pack('<f', u))[0]
    vb = _st.unpack('<I', _st.pack('<f', v))[0]
    words = [0x07230203, 0x00010300, 0, 48, 0]

    def emit(opcode, *values):
        words.extend(((len(values) + 1) << 16 | opcode, *values))

    emit(17, 1)                     # OpCapability Shader
    emit(14, 0, 1)                  # OpMemoryModel Logical GLSL450
    emit(15, 4, 9, 0x6E69616D, 0, 8)  # EntryPoint Fragment %9 main, iface=[color]
    emit(16, 9, 7)                  # OriginUpperLeft
    emit(71, 8, 30, 0)              # color Location 0
    emit(71, 17, 34, 0)             # img   DescriptorSet 0
    emit(71, 17, 33, image_binding) # img   Binding N
    emit(71, 39, 34, 0)             # smp   DescriptorSet 0
    emit(71, 39, 33, sampler_binding)  # smp Binding M
    emit(19, 1)                     # %1 void
    emit(33, 2, 1)                  # %2 fnty
    emit(22, 3, 32)                 # %3 float
    emit(23, 4, 3, 4)               # %4 v4f
    emit(23, 5, 3, 2)               # %5 v2f
    emit(25, 13, 3, 1, 0, 0, 0, 1, 0)  # %13 image2D sampled (kind 2)
    emit(26, 37)                    # %37 = OpTypeSampler (kind 0)
    emit(27, 40, 13)                # %40 = OpTypeSampledImage %13 (merge result)
    emit(32, 14, 0, 13)             # %14 = ptr UniformConstant image
    emit(32, 38, 0, 37)             # %38 = ptr UniformConstant sampler
    emit(32, 15, 3, 4)              # %15 = ptr Output v4f
    emit(59, 15, 8, 3)              # %8  color output
    emit(59, 14, 17, 0)             # %17 img (UniformConstant)
    emit(59, 38, 39, 0)             # %39 smp (UniformConstant)
    emit(43, 3, 18, ub)             # %18 = float u
    emit(43, 3, 19, vb)             # %19 = float v
    emit(44, 5, 20, 18, 19)         # %20 = vec2(u, v)
    emit(43, 3, 21, 0)              # %21 = float 0.0 (LOD)
    emit(54, 1, 9, 0, 2)            # %9 main()
    emit(248, 22)                   # label
    emit(61, 13, 23, 17)            # %23 = Load image %17
    emit(61, 37, 24, 39)            # %24 = Load sampler %39
    emit(86, 40, 25, 23, 24)        # %25 = OpSampledImage %23 %24 -> SIMG
    emit(88, 4, 26, 25, 20, 2, 21)  # %26 = ImageSampleExplicitLod %25 %20 Lod %21
    emit(62, 8, 26)                 # Store color %26
    emit(253)                       # Return
    emit(56)                        # FunctionEnd
    return tuple(words)


class FragmentShadeTests(unittest.TestCase):
    def setUp(self):
        self.f = transfer_fixture.TransferTests()
        self.f.setUp()
        self.e, self.executor, self.context = self.f.engine, self.f.executor, self.f.context
        self.owner, self.state = self.f.owner, self.f.state

    def records(self, count=4, vcol=None):
        out = bytearray()
        for i in range(count):
            rec = bytearray(ATTR_STRIDE)
            # FragCoord slot 0: {x=i+0.5, y=0.25, z=0.0, w=1.0}
            struct.pack_into('<4f', rec, 0, i + 0.5, 0.25, 0.0, 1.0)
            # vcol loc0 at byte 16
            col = vcol or (0.1 * (i + 1), 0.2 * (i + 1),
                           0.3 * (i + 1), 0.4 * (i + 1))
            struct.pack_into('<4f', rec, 16, *col)
            out += rec
        return bytes(out)

    def shade(self, kind='color', count=4, **kwargs):
        return FragmentShade(self.records(count), fs_program(kind), **kwargs)

    def drain(self):
        for _ in range(512):
            if not self.executor.active:
                return
            self.executor.poll()
        self.fail('bounded fragment shade cohort did not drain')

    def test_color_passthrough_records_in_order(self):
        job = self.executor.enqueue(self.context, [self.shade(count=4)])
        runtime = job.runtimes[0]
        self.drain()
        self.assertEqual(job.state, 'done')
        stats = job.fshade_stats[0]
        self.assertEqual((stats['records'], stats['batches'], stats['color']),
                         (4, 1, 4 * ATTR_STRIDE))
        color = bytes(runtime.color)
        self.assertEqual(len(color), 4 * ATTR_STRIDE)
        for i in range(4):
            words = struct.unpack_from('<36I', color, i * ATTR_STRIDE)
            self.assertEqual(words[:4],
                             struct.unpack('<4I', struct.pack(
                                 '<4f', 0.1 * (i + 1), 0.2 * (i + 1),
                                 0.3 * (i + 1), 0.4 * (i + 1))))
        self.assertEqual(self.owner.work_refs, 0)

    def test_fragcoord_builtin_and_batch_split(self):
        job = self.executor.enqueue(self.context,
                                    [self.shade('fc', count=7, batch=3)])
        runtime = job.runtimes[0]
        self.drain()
        self.assertEqual(job.state, 'done')
        stats = job.fshade_stats[0]
        self.assertEqual((stats['records'], stats['batches']), (7, 3))
        color = bytes(runtime.color)
        self.assertEqual(len(color), 7 * ATTR_STRIDE)
        for i in range(7):
            words = struct.unpack_from('<36I', color, i * ATTR_STRIDE)
            # color.xy = FragCoord.xy = {i+0.5, 0.25}; z=0 w=1
            self.assertEqual(words[:4],
                             struct.unpack('<4I', struct.pack(
                                 '<4f', i + 0.5, 0.25, 0.0, 1.0)))

    def test_helper_mask_and_front_flag_are_admitted(self):
        op = FragmentShade(self.records(4), fs_program('color'),
                           helpers=0b0101, front=1)
        job = self.executor.enqueue(self.context, [op])
        self.drain()
        self.assertEqual(job.state, 'done')
        self.assertEqual(job.fshade_stats[0]['records'], 4)

    def test_ubo_descriptor_read_reaches_color(self):
        ubo = 54321
        self.f.state.aperture.write(self.owner.base + 1024,
                                    struct.pack('<f', float(ubo)))
        binding = ShaderBinding(self.owner, 1024, 4, binding=0,
                                descriptor_set=0, kind=6, element=0)
        job = self.executor.enqueue(self.context, [
            FragmentShade(self.records(4), fs_program('color', ubo=True),
                          bindings=(binding,))])
        runtime = job.runtimes[0]
        self.drain()
        self.assertEqual(job.state, 'done')
        color = bytes(runtime.color)
        self.assertEqual(len(color), 4 * ATTR_STRIDE)
        for i in range(4):
            words = struct.unpack_from('<4I', color, i * ATTR_STRIDE)
            self.assertEqual(words, (f32bits(float(ubo)),) * 4)

    def test_ubo_descriptor_requires_matching_binding(self):
        with self.assertRaises(ValueError):
            self.executor.enqueue(self.context, [
                FragmentShade(self.records(4), fs_program('color', ubo=True))])

    def test_record_shape_and_stage_are_validated(self):
        code = fs_program('color')
        for bad in (b'', b'x' * 100, self.records(4)[:-4]):
            with self.assertRaises(ValueError):
                self.executor.enqueue(self.context,
                                      [FragmentShade(bad, code)])
        with self.assertRaises(ValueError):
            self.executor.enqueue(self.context,
                                  [FragmentShade(self.records(4),
                                                 vs_program())])
        with self.assertRaises(ValueError):
            self.executor.enqueue(self.context,
                                  [FragmentShade(self.records(4),
                                                 fs_program(desc=True))])

    def test_oversized_input_is_refused(self):
        big = self.records(4) * 300          # 1200 records > MAX_RECORDS
        with self.assertRaises(ValueError):
            self.executor.enqueue(self.context,
                                  [FragmentShade(big, fs_program())])


if __name__ == '__main__':
    unittest.main()
