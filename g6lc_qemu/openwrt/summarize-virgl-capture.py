#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
"""Summarize a vhost-user-gpu virgl capture directory."""
from __future__ import annotations

import argparse
import re
import struct
from collections import Counter
from pathlib import Path

CMD_NAMES = """
NOP CREATE_OBJECT BIND_OBJECT DESTROY_OBJECT SET_VIEWPORT_STATE
SET_FRAMEBUFFER_STATE SET_VERTEX_BUFFERS CLEAR DRAW_VBO RESOURCE_INLINE_WRITE
SET_SAMPLER_VIEWS SET_INDEX_BUFFER SET_CONSTANT_BUFFER SET_STENCIL_REF
SET_BLEND_COLOR SET_SCISSOR_STATE BLIT RESOURCE_COPY_REGION BIND_SAMPLER_STATES
BEGIN_QUERY END_QUERY GET_QUERY_RESULT SET_POLYGON_STIPPLE SET_CLIP_STATE
SET_SAMPLE_MASK SET_STREAMOUT_TARGETS SET_RENDER_CONDITION SET_UNIFORM_BUFFER
SET_SUB_CTX CREATE_SUB_CTX DESTROY_SUB_CTX BIND_SHADER SET_TESS_STATE
SET_MIN_SAMPLES SET_SHADER_BUFFERS SET_SHADER_IMAGES MEMORY_BARRIER LAUNCH_GRID
SET_FRAMEBUFFER_STATE_NO_ATTACH TEXTURE_BARRIER SET_ATOMIC_BUFFERS SET_DEBUG_FLAGS
GET_QUERY_RESULT_QBO TRANSFER3D END_TRANSFERS COPY_TRANSFER3D SET_TWEAKS
CLEAR_TEXTURE PIPE_RESOURCE_CREATE PIPE_RESOURCE_SET_TYPE GET_MEMORY_INFO
SEND_STRING_MARKER LINK_SHADER CREATE_VIDEO_CODEC DESTROY_VIDEO_CODEC
CREATE_VIDEO_BUFFER DESTROY_VIDEO_BUFFER BEGIN_FRAME DECODE_MACROBLOCK
DECODE_BITSTREAM ENCODE_BITSTREAM END_FRAME
""".split()

OBJ_NAMES = """
NULL BLEND RASTERIZER DSA SHADER VERTEX_ELEMENTS SAMPLER_VIEW SAMPLER_STATE
SURFACE QUERY STREAMOUT_TARGET MSAA_SURFACE
""".split()

BSET_NAMES = [
    "indep_blend_enable", "indep_blend_func", "cube_map_array",
    "shader_stencil_export", "conditional_render", "start_instance",
    "primitive_restart", "blend_eq_sep", "instanceid",
    "vertex_element_instance_divisor", "seamless_cube_map", "occlusion_query",
    "timer_query", "streamout_pause_resume", "texture_multisample",
    "fragment_coord_conventions", "depth_clip_disable",
    "seamless_cube_map_per_texture", "ubo", "color_clamping", "poly_stipple",
    "mirror_clamp", "texture_query_lod", "has_fp64",
    "has_tessellation_shaders", "has_indirect_draw", "has_sample_shading",
    "has_cull", "conditional_render_inverted", "derivative_control",
    "polygon_offset_clamp", "transform_feedback_overflow_query",
]

CAP_NAMES = [
    "TGSI_INVARIANT", "TEXTURE_VIEW", "SET_MIN_SAMPLES", "COPY_IMAGE",
    "TGSI_PRECISE", "TXQS", "MEMORY_BARRIER", "COMPUTE_SHADER",
    "FB_NO_ATTACH", "ROBUST_BUFFER_ACCESS", "TGSI_FBFETCH", "SHADER_CLOCK",
    "TEXTURE_BARRIER", "TGSI_COMPONENTS", "GUEST_MAY_INIT_LOG",
    "SRGB_WRITE_CONTROL", "QBO", "TRANSFER", "FBO_MIXED_COLOR_FORMATS",
    "HOST_IS_GLES", "BIND_COMMAND_ARGS", "MULTI_DRAW_INDIRECT",
    "INDIRECT_PARAMS", "TRANSFORM_FEEDBACK3", "3D_ASTC",
    "INDIRECT_INPUT_ADDR", "COPY_TRANSFER", "CLIP_HALFZ",
    "APP_TWEAK_SUPPORT", "BGRA_SRGB_IS_EMULATED", "CLEAR_TEXTURE",
    "ARB_BUFFER_STORAGE",
]

CAP2_NAMES = [
    "BLEND_EQUATION", "UNTYPED_RESOURCE", "VIDEO_MEMORY", "MEMINFO",
    "STRING_MARKER", "DIFFERENT_GPU", "IMPLICIT_MSAA",
    "COPY_TRANSFER_BOTH_DIRECTIONS", "SCANOUT_USES_GBM", "SSO",
    "TEXTURE_SHADOW_LOD", "VS_VERTEX_LAYER", "VS_VIEWPORT_INDEX",
    "PIPELINE_STATISTICS_QUERY", "DRAW_PARAMETERS", "GROUP_VOTE",
]

MASK_FIELDS = {
    "sampler": 1,
    "render": 17,
    "depth_stencil": 33,
    "vertex_buffer": 49,
    "supported_readback": 140,
    "scanout": 156,
    "supported_multisample": 192,
}

VIRTIO_CMD_TYPES = {
    0x200: "CTX_CREATE",
    0x201: "CTX_DESTROY",
    0x202: "CTX_ATTACH_RESOURCE",
    0x203: "CTX_DETACH_RESOURCE",
    0x204: "RESOURCE_CREATE_3D",
    0x205: "TRANSFER_TO_HOST_3D",
    0x206: "TRANSFER_FROM_HOST_3D",
    0x207: "SUBMIT_3D",
}

TARGET_NAMES = {
    0: "BUFFER",
    1: "TEXTURE_1D",
    2: "TEXTURE_2D",
    3: "TEXTURE_3D",
    4: "TEXTURE_CUBE",
    5: "TEXTURE_RECT",
    6: "TEXTURE_1D_ARRAY",
    7: "TEXTURE_2D_ARRAY",
    8: "TEXTURE_CUBE_ARRAY",
}

FORMAT_INFO = {
    0: ("NONE", 0),
    1: ("B8G8R8A8_UNORM", 4),
    2: ("B8G8R8X8_UNORM", 4),
    28: ("R32_FLOAT", 4),
    29: ("R32G32_FLOAT", 8),
    30: ("R32G32B32_FLOAT", 12),
    31: ("R32G32B32A32_FLOAT", 16),
    64: ("R8_UNORM", 1),
    65: ("R8G8_UNORM", 2),
    66: ("R8G8B8_UNORM", 3),
    67: ("R8G8B8A8_UNORM", 4),
    104: ("R8G8B8A8_SRGB", 4),
    121: ("A8B8G8R8_UNORM", 4),
    134: ("R8G8B8X8_UNORM", 4),
}

BIND_NAMES = {
    0: "DEPTH_STENCIL",
    1: "RENDER_TARGET",
    3: "SAMPLER_VIEW",
    4: "VERTEX_BUFFER",
    5: "INDEX_BUFFER",
    6: "CONSTANT_BUFFER",
    7: "DISPLAY_TARGET",
    8: "COMMAND_ARGS",
    11: "STREAM_OUTPUT",
    14: "SHADER_BUFFER",
    15: "QUERY_BUFFER",
    16: "CURSOR",
    17: "CUSTOM",
    18: "SCANOUT",
    19: "STAGING",
    20: "SHARED",
    22: "LINEAR",
}


def u32_words(data: bytes) -> list[int]:
    if len(data) % 4:
        raise ValueError(f"capture is not dword-aligned ({len(data)} bytes)")
    return list(struct.unpack(f"<{len(data) // 4}I", data))


def bit_names(value: int, names: list[str]) -> list[str]:
    return [name for bit, name in enumerate(names) if value & (1 << bit)]


def format_ids(words: list[int], base: int) -> list[int]:
    return [
        word * 32 + bit
        for word in range(16)
        for bit in range(32)
        if words[base + word] & (1 << bit)
    ]


def format_name(fmt: int) -> str:
    return FORMAT_INFO.get(fmt, (f"FORMAT_{fmt}", 0))[0]


def bind_names(value: int) -> str:
    names = [name for bit, name in BIND_NAMES.items() if value & (1 << bit)]
    return "|".join(names) if names else "none"


def resource_min_bytes(res: dict[str, int]) -> int:
    bpp = FORMAT_INFO.get(res["format"], ("", 0))[1]
    if res["target"] == 0:
        return res["width"] * max(1, res["height"]) * bpp
    layers = max(1, res.get("array", 1))
    levels = max(0, res.get("levels", 0)) + 1
    samples = max(1, res.get("samples", 0))
    total = 0
    for level in range(levels):
        total += (
            max(1, res["width"] >> level)
            * max(1, res["height"] >> level)
            * max(1, res["depth"] >> level)
            * layers
            * samples
            * bpp
        )
    return total


def transfer_bounds(res: dict[str, int], x: int, y: int, z: int,
                    w: int, h: int, d: int, level: int) -> str:
    width = max(1, res["width"] >> level)
    height = max(1, res["height"] >> level)
    if x + w <= width and y + h <= height and z + d <= res["depth"]:
        return "bounds=ok"
    return "bounds=BAD"


def transfer_bytes(res: dict[str, int], w: int, h: int, d: int) -> int:
    bpp = FORMAT_INFO.get(res["format"], ("", 0))[1]
    return w * h * d * bpp


def shader_text(payload: list[int]) -> str:
    raw = struct.pack(f"<{max(0, len(payload) - 5)}I", *payload[5:])
    return raw.split(b"\0", 1)[0].decode("utf-8", "replace")


def summarize_submit(path: Path, resources: dict[int, dict[str, int]]) -> list[str]:
    data = path.read_bytes()
    try:
        words = u32_words(data)
    except ValueError as exc:
        return [f"{path.name}: MALFORMED {exc}"]
    counts: Counter[str] = Counter()
    objects: Counter[str] = Counter()
    malformed: list[str] = []
    details: list[str] = []
    off = 0

    while off < len(words):
        header = words[off]
        cmd = header & 0xFF
        obj = (header >> 8) & 0xFF
        body_len = (header >> 16) & 0xFFFF
        name = CMD_NAMES[cmd] if cmd < len(CMD_NAMES) else f"UNKNOWN_{cmd}"
        obj_name = OBJ_NAMES[obj] if obj < len(OBJ_NAMES) else f"UNKNOWN_{obj}"
        if off + 1 + body_len > len(words):
            malformed.append(f"offset={off} {name} body={body_len} past end")
            break
        payload = words[off + 1 : off + 1 + body_len]
        counts[name] += 1
        if cmd == 1:
            objects[obj_name] += 1
            handle = payload[0] if payload else 0
            if obj_name == "SHADER" and len(payload) >= 5:
                stage = {0: "vertex", 1: "fragment"}.get(payload[1], str(payload[1]))
                text = shader_text(payload)
                shader_path = path.with_name(
                    f"{path.stem}-shader-{handle}.tgsi"
                )
                shader_path.write_text(text, encoding="utf-8")
                details.append(
                    f"  create shader handle={handle} stage={stage} "
                    f"wire_len={body_len} text_bytes={len(text.encode())} "
                    f"file={shader_path.name}"
                )
                first = " / ".join(line for line in text.splitlines()[:3])
                details.append(f"    {first}")
            elif obj_name == "SURFACE" and len(payload) >= 5:
                res = resources.get(payload[1], {})
                details.append(
                    f"  create SURFACE handle={handle} res={payload[1]} "
                    f"format={payload[2]}({format_name(payload[2])}) "
                    f"val0={payload[3]} val1={payload[4]} "
                    f"target={TARGET_NAMES.get(res.get('target', -1), '?')}"
                )
            elif obj_name == "VERTEX_ELEMENTS" and len(payload) >= 5:
                elements = [
                    f"off={payload[i]} div={payload[i + 1]} "
                    f"vb={payload[i + 2]} fmt={payload[i + 3]}"
                    f"({format_name(payload[i + 3])})"
                    for i in range(1, len(payload) - 3, 4)
                ]
                details.append(
                    f"  create VERTEX_ELEMENTS handle={handle} "
                    f"elements=[{'; '.join(elements)}]"
                )
            elif obj_name == "SAMPLER_VIEW" and len(payload) >= 6:
                fmt = payload[2] & 0xFFFFFF
                target = payload[2] >> 24
                res = resources.get(payload[1], {})
                details.append(
                    f"  create SAMPLER_VIEW handle={handle} res={payload[1]} "
                    f"format={fmt}({format_name(fmt)}) target={target}"
                    f"({TARGET_NAMES.get(target, '?')}) "
                    f"layers={payload[3] & 0xffff}-{(payload[3] >> 16) & 0xffff} "
                    f"levels={payload[4] & 0xff}-{(payload[4] >> 8) & 0xff} "
                    f"swizzle=0x{payload[5]:x} "
                    f"res_target={TARGET_NAMES.get(res.get('target', -1), '?')}"
                )
            elif obj_name == "SAMPLER_STATE" and len(payload) >= 9:
                lod_bias = struct.unpack("<f", struct.pack("<I", payload[2]))[0]
                min_lod = struct.unpack("<f", struct.pack("<I", payload[3]))[0]
                max_lod = struct.unpack("<f", struct.pack("<I", payload[4]))[0]
                details.append(
                    f"  create SAMPLER_STATE handle={handle} s0=0x{payload[1]:x} "
                    f"lod_bias={lod_bias} min_lod={min_lod} max_lod={max_lod} "
                    f"border={payload[5:9]}"
                )
            else:
                details.append(
                    f"  create {obj_name} handle={handle} body_dwords={body_len}"
                )
        elif cmd == 4 and len(payload) >= 7:
            floats = [
                struct.unpack("<f", struct.pack("<I", word))[0]
                for word in payload[1:7]
            ]
            details.append(
                f"  viewport start={payload[0]} scale={floats[:3]} "
                f"translate={floats[3:]}"
            )
        elif cmd == 5 and len(payload) >= 2:
            details.append(
                f"  framebuffer nr_cbufs={payload[0]} zsurf={payload[1]} "
                f"cbufs={payload[2:]}"
            )
        elif cmd == 6 and len(payload) >= 3:
            buffers = [
                f"stride={payload[i]} offset={payload[i + 1]} "
                f"handle={payload[i + 2]}"
                for i in range(0, len(payload) - 2, 3)
            ]
            details.append(f"  vertex-buffers [{'; '.join(buffers)}]")
        elif cmd == 7 and len(payload) >= 8:
            color = [
                struct.unpack("<f", struct.pack("<I", word))[0]
                for word in payload[1:5]
            ]
            depth = struct.unpack("<d", struct.pack("<II", *payload[5:7]))[0]
            details.append(
                f"  clear buffers=0x{payload[0]:x} color={color} "
                f"depth={depth} stencil={payload[7]}"
            )
        elif cmd == 8 and len(payload) >= 11:
            details.append(
                "  draw-vbo "
                f"start={payload[0]} count={payload[1]} mode={payload[2]} "
                f"indexed={payload[3]} instances={payload[4]} "
                f"min={payload[9]} max={payload[10]}"
            )
        elif cmd == 10 and len(payload) >= 2:
            handles = payload[2:]
            if handles and not any(handles):
                details.append(
                    f"  sampler-views shader={payload[0]} start={payload[1]} "
                    f"cleared_slots={len(handles)}"
                )
            else:
                details.append(
                    f"  sampler-views shader={payload[0]} start={payload[1]} "
                    f"handles={handles}"
                )
        elif cmd == 11 and payload:
            details.append(
                f"  index-buffer handle={payload[0]} "
                f"index_size={payload[1] if len(payload) > 1 else 0} "
                f"offset={payload[2] if len(payload) > 2 else 0}"
            )
        elif cmd == 12 and len(payload) >= 2:
            details.append(
                f"  constant-buffer shader={payload[0]} index={payload[1]} "
                f"data_dwords={max(0, len(payload) - 2)}"
            )
        elif cmd == 14 and len(payload) >= 3:
            scissors = [
                f"min={payload[i] & 0xffff},{payload[i] >> 16} "
                f"max={payload[i + 1] & 0xffff},{payload[i + 1] >> 16}"
                for i in range(1, len(payload) - 1, 2)
            ]
            details.append(
                f"  scissor start={payload[0]} [{'; '.join(scissors)}]"
            )
        elif cmd == 17 and len(payload) >= 2:
            details.append(
                f"  bind-sampler-states shader={payload[0]} "
                f"start={payload[1]} handles={payload[2:]}"
            )
        elif cmd in (28, 29, 30) and payload:
            details.append(f"  {name.lower()} subctx={payload[0]}")
        elif cmd == 31 and len(payload) >= 2:
            details.append(
                f"  bind-shader handle={payload[0]} stage={payload[1]}"
            )
        elif cmd == 34 and len(payload) >= 2:
            handles = payload[4::3]
            if handles and not any(handles):
                details.append(
                    f"  shader-buffers shader={payload[0]} start={payload[1]} "
                    f"cleared_slots={len(handles)}"
                )
            else:
                buffers = [
                    f"offset={payload[i]} length={payload[i + 1]} "
                    f"handle={payload[i + 2]}"
                    for i in range(2, len(payload) - 2, 3)
                ]
                details.append(
                    f"  shader-buffers shader={payload[0]} start={payload[1]} "
                    f"[{'; '.join(buffers)}]"
                )
        elif cmd == 35 and len(payload) >= 2:
            handles = payload[6::5]
            if handles and not any(handles):
                details.append(
                    f"  shader-images shader={payload[0]} start={payload[1]} "
                    f"cleared_slots={len(handles)}"
                )
            else:
                images = [
                    f"fmt={payload[i]}({format_name(payload[i])}) "
                    f"access={payload[i + 1]} layer={payload[i + 2]} "
                    f"level={payload[i + 3]} handle={payload[i + 4]}"
                    for i in range(2, len(payload) - 4, 5)
                ]
                details.append(
                    f"  shader-images shader={payload[0]} start={payload[1]} "
                    f"[{'; '.join(images)}]"
                )
        elif cmd == 38 and len(payload) >= 2:
            details.append(
                f"  framebuffer-no-attach "
                f"size={payload[0] & 0xffff}x{payload[0] >> 16} "
                f"layers={payload[1] & 0xffff} samples={payload[1] >> 16}"
            )
        elif cmd == 43 and len(payload) >= 13:
            res = resources.get(payload[0])
            direction = {1: "TO_HOST", 2: "FROM_HOST"}.get(
                payload[12], f"UNKNOWN_{payload[12]}"
            )
            line = (
                f"  transfer3d res={payload[0]} level={payload[1]} "
                f"stride={payload[3]} layer_stride={payload[4]} "
                f"box={payload[5]},{payload[6]},{payload[7]} "
                f"{payload[8]}x{payload[9]}x{payload[10]} "
                f"offset={payload[11]} dir={direction}"
            )
            if res:
                line += " " + transfer_bounds(
                    res, payload[5], payload[6], payload[7],
                    payload[8], payload[9], payload[10], payload[1]
                )
                need = payload[11] + transfer_bytes(
                    res, payload[8], payload[9], payload[10]
                )
                line += f" backing={res.get('attached', 0)} need={need}"
            details.append(line)
        elif cmd == 44:
            details.append(f"  end-transfers ignored_dwords={body_len}")
        elif cmd == 46 and len(payload) >= 2:
            details.append(f"  tweak id={payload[0]} value=0x{payload[1]:x}")
        off += 1 + body_len

    lines = [
        f"{path.name}: {len(data)} bytes, {len(words)} dwords, "
        f"{sum(counts.values())} commands"
    ]
    lines.extend(f"  {name}={count}" for name, count in counts.most_common())
    if objects:
        lines.append("  objects: " + ", ".join(
            f"{name}={count}" for name, count in objects.most_common()
        ))
    lines.extend(details)
    lines.extend(f"  MALFORMED {item}" for item in malformed)
    if off != len(words):
        lines.append(f"  MALFORMED parser ended at dword {off}/{len(words)}")
    return lines


def summarize_capset(path: Path, event: str) -> list[str]:
    data = path.read_bytes()
    try:
        words = u32_words(data)
    except ValueError as exc:
        return [f"{path.name}: MALFORMED {exc}"]
    lines = [f"{path.name}: {event}"]
    if len(words) < 346:
        lines.append(f"  capset too short: {len(data)} bytes")
        return lines

    bset = words[65]
    caps = words[98]
    caps2 = words[172]
    renderer = data[696:760].split(b"\0", 1)[0].decode("utf-8", "replace")
    lines += [
        f"  max_version={words[0]}",
        f"  glsl_level={words[66]}",
        f"  renderer={renderer}",
        f"  max_texture_2d={words[121]} max_texture_3d={words[122]} "
        f"max_texture_cube={words[123]}",
        f"  max_texture_array_layers={words[67]} max_render_targets={words[70]} "
        f"max_samples={words[71]} max_viewports={words[75]}",
        f"  max_vertex_attribs={words[89]} max_vertex_outputs={words[88]} "
        f"max_vertex_attrib_stride={words[107]}",
        f"  max_uniform_blocks={words[74]} max_uniform_block_size={words[343]} "
        f"const_buffer_sizes={words[208:214]}",
        f"  max_shader_buffers={words[108:110]} "
        f"max_shader_images={words[110:112]}",
        f"  compute invocations={words[113]} shared={words[114]} "
        f"grid={words[115:118]} block={words[118:121]}",
        f"  max_anisotropy={struct.unpack('<f', struct.pack('<I', words[190]))[0]} "
        f"texture_image_units={words[191]}",
        f"  num_video_caps={words[214]}",
        f"  bset=0x{bset:08x}: {', '.join(bit_names(bset, BSET_NAMES))}",
        f"  capability_bits=0x{caps:08x}: {', '.join(bit_names(caps, CAP_NAMES))}",
        f"  capability_bits_v2=0x{caps2:08x}: "
        f"{', '.join(bit_names(caps2, CAP2_NAMES))}",
    ]
    for name, base in MASK_FIELDS.items():
        ids = format_ids(words, base)
        lines.append(f"  formats.{name}: count={len(ids)} ids={ids}")
    return lines


def parse_api_events(
    events: dict[int, str],
) -> tuple[list[str], dict[int, dict[str, int]], list[str]]:
    resources: dict[int, dict[str, int]] = {}
    lines: list[str] = []
    problems: list[str] = []
    for seq, event in events.items():
        rc = re.search(r"(?:^| )rc=(-?\d+)", event)
        if rc and int(rc.group(1)) != 0:
            problems.append(f"api event {seq:06d} rc={rc.group(1)}")
        m = re.search(
            r"resource-create handle=(\d+) target=(\d+) format=(\d+) "
            r"bind=0x([0-9a-fA-F]+) size=(\d+)x(\d+)x(\d+) "
            r"array=(\d+) levels=(\d+) samples=(\d+)",
            event,
        )
        if m:
            handle = int(m.group(1))
            target = int(m.group(2))
            fmt = int(m.group(3))
            bind = int(m.group(4), 16)
            resources[handle] = {
                "target": target,
                "format": fmt,
                "bind": bind,
                "width": int(m.group(5)),
                "height": int(m.group(6)),
                "depth": int(m.group(7)),
                "array": int(m.group(8)),
                "levels": int(m.group(9)),
                "samples": int(m.group(10)),
                "attached": 0,
            }
            event = event.replace(
                f"target={target}", f"target={target}({TARGET_NAMES.get(target, '?')})"
            ).replace(
                f"format={fmt}", f"format={fmt}({format_name(fmt)})"
            ).replace(
                f"bind=0x{bind:x}", f"bind=0x{bind:x}({bind_names(bind)})"
            )
        m = re.search(
            r"resource-attach-iov handle=(\d+) iovs=\d+ bytes=(\d+)", event
        )
        if m:
            handle = int(m.group(1))
            attached = int(m.group(2))
            res = resources.get(handle)
            if res:
                res["attached"] = attached
                need = resource_min_bytes(res)
                state = "ok" if attached >= need else "BAD"
                event += f" min_bytes={need} backing={state}"
                if state != "ok":
                    problems.append(
                        f"resource {handle} backing {attached} < {need}"
                    )
        m = re.search(
            r"(transfer-read|transfer-write) handle=(\d+) ctx=\d+ "
            r"level=(\d+) stride=\d+ layer_stride=\d+ "
            r"box=(\d+),(\d+),(\d+) (\d+)x(\d+)x(\d+) offset=(\d+)",
            event,
        )
        if m:
            handle = int(m.group(2))
            level = int(m.group(3))
            x, y, z = int(m.group(4)), int(m.group(5)), int(m.group(6))
            w, h, d = int(m.group(7)), int(m.group(8)), int(m.group(9))
            offset = int(m.group(10))
            res = resources.get(handle)
            if res:
                bounds = transfer_bounds(res, x, y, z, w, h, d, level)
                event += " " + bounds
                need = offset + transfer_bytes(res, w, h, d)
                event += f" backing={res['attached']} need={need}"
                if bounds != "bounds=ok" or need > res["attached"]:
                    problems.append(
                        f"transfer {m.group(1)} handle={handle} "
                        f"{bounds} backing={res['attached']} need={need}"
                    )
        m = re.search(r"cmd_type=(0x[0-9a-fA-F]+|\d+)", event)
        if m:
            cmd_type = int(m.group(1), 0)
            name = VIRTIO_CMD_TYPES.get(cmd_type)
            if name:
                event = event.replace(
                    m.group(0), f"{m.group(0)}({name})", 1
                )
        lines.append(f"  {seq:06d} {event}")
    return lines, resources, problems


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("capture", type=Path)
    ap.add_argument("--out", type=Path, default=None)
    ap.add_argument("--strict", action="store_true")
    ap.add_argument(
        "--expect-errors",
        action="store_true",
        help="require API, malformed-buffer and bounds errors instead of rejecting them",
    )
    ap.add_argument(
        "--expect-audit",
        action="store_true",
        help="require the richer GLES2 audit command inventory",
    )
    args = ap.parse_args()
    capture = args.capture
    index_path = capture / "index.log"
    if not index_path.is_file():
        raise SystemExit(f"missing {index_path}")

    events = {}
    for line in index_path.read_text(encoding="utf-8", errors="replace").splitlines():
        m = re.match(r"(\d+)\s+(.*)", line)
        if m:
            events[int(m.group(1))] = m.group(2)

    api_lines, resources, problems = parse_api_events(events)
    lines = [f"capture={capture}", "", "API events:"]
    lines.extend(api_lines)
    lines.append("")
    lines.append("Capsets:")
    for path in sorted(capture.glob("*-capset.bin")):
        seq = int(path.name.split("-", 1)[0])
        lines.extend(summarize_capset(path, events.get(seq, "no index event")))
    lines.append("")
    lines.append("Submitted virgl command buffers:")
    submit_lines: list[str] = []
    submit_paths = sorted(capture.glob("*-submit.bin"))
    for path in submit_paths:
        submit_lines.extend(summarize_submit(path, resources))
    lines.extend(submit_lines)

    cmd_counts: Counter[str] = Counter()
    object_counts: Counter[str] = Counter()
    for line in submit_lines:
        m = re.match(r"  ([A-Z0-9_]+)=(\d+)$", line)
        if m and m.group(1) in CMD_NAMES:
            cmd_counts[m.group(1)] += int(m.group(2))
        m = re.match(r"  objects: (.*)$", line)
        if m:
            for name, count in re.findall(r"([A-Z0-9_]+)=(\d+)", m.group(1)):
                object_counts[name] += int(count)

    for line in api_lines + submit_lines:
        if "MALFORMED" in line or "BAD" in line:
            problems.append(line.strip())
    for path in sorted(capture.glob("*-capset.bin")):
        seq = int(path.name.split("-", 1)[0])
        m = re.search(r"fill-caps .*bytes=(\d+)", events.get(seq, ""))
        if not m:
            problems.append(f"{path.name} has no fill-caps index event")
        elif path.stat().st_size != int(m.group(1)):
            problems.append(
                f"{path.name} size {path.stat().st_size} != event bytes={m.group(1)}"
            )
    for seq, event in events.items():
        m = re.search(r"submit ctx=\d+ ndw=(\d+) bytes=(\d+)", event)
        if not m:
            continue
        path = capture / f"{seq:06d}-submit.bin"
        if not path.is_file():
            problems.append(f"missing {path.name}")
            continue
        actual = path.stat().st_size
        if actual != int(m.group(2)) or actual != int(m.group(1)) * 4:
            problems.append(
                f"{path.name} size {actual} != event bytes={m.group(2)} "
                f"ndw={m.group(1)}"
            )
    fence_types = [
        int(m.group(1), 0)
        for event in events.values()
        for m in [re.search(r"cmd_type=(0x[0-9a-fA-F]+|\d+)", event)]
        if m
    ]
    unrefs = sum("resource-unref" in event for event in events.values())
    detaches = sum("resource-detach-iov" in event for event in events.values())
    ctx_destroys = sum("ctx-destroy" in event for event in events.values())
    if len(submit_paths) != sum(" submit " in f" {event} " for event in events.values()):
        problems.append("submit event/binary count mismatch")

    api_errors = sum(p.startswith("api event") for p in problems)
    malformed = sum("MALFORMED" in line for line in submit_lines)
    bad_bounds = sum("bounds=BAD" in line for line in api_lines + submit_lines)
    expected_problem = all(
        problem.startswith("api event")
        or "MALFORMED" in problem
        or "bounds=BAD" in problem
        or "backing=BAD" in problem
        for problem in problems
    )
    expected_ok = (
        args.expect_errors
        and api_errors >= 3
        and malformed >= 1
        and bad_bounds >= 1
        and expected_problem
    )
    audit_required = {
        "SET_SAMPLER_VIEWS",
        "SET_INDEX_BUFFER",
        "SET_CONSTANT_BUFFER",
        "SET_SCISSOR_STATE",
        "BIND_SAMPLER_STATES",
        "BLIT",
    }
    audit_missing = [
        name for name in sorted(audit_required) if cmd_counts[name] == 0
    ]
    api_transfers = sum(
        "transfer-write" in line or "transfer-read" in line for line in api_lines
    )
    if cmd_counts["TRANSFER3D"] == 0 and api_transfers == 0:
        audit_missing.append("resource-transfer")
    if cmd_counts["TRANSFER3D"] != 0 and cmd_counts["END_TRANSFERS"] == 0:
        audit_missing.append("END_TRANSFERS")
    for name in ("SAMPLER_VIEW", "SAMPLER_STATE"):
        if object_counts[name] == 0:
            audit_missing.append(f"object:{name}")
    if cmd_counts["DRAW_VBO"] < 2 or not any(
        "indexed=1" in line and "draw-vbo" in line for line in submit_lines
    ):
        audit_missing.append("indexed-draw")
    if not any("index_size=2" in line for line in submit_lines):
        audit_missing.append("u16-index-buffer")
    if len(fence_types) < 8:
        audit_missing.append("typed-fences")
    if ctx_destroys < 1:
        audit_missing.append("ctx-destroy")
    if unrefs < 5:
        audit_missing.append("resource-cleanup")
    audit_ok = (
        args.expect_audit
        and not args.expect_errors
        and not audit_missing
        and not problems
    )
    if args.expect_audit and not audit_ok:
        problems.append(
            "audit contract missing " + ",".join(audit_missing)
        )
    passed = expected_ok if args.expect_errors else not problems
    if args.expect_audit:
        passed = audit_ok
    parsed_state = "ok" if malformed == 0 else f"{malformed} malformed"
    backing_state = "ok" if not any("backing=BAD" in line for line in api_lines) else "BAD"
    bounds_state = "ok" if bad_bounds == 0 else f"{bad_bounds} bad"

    lines += [
        "",
        "Validation:",
        f"  api_errors={'none' if api_errors == 0 else api_errors}",
        f"  submit_buffers={len(submit_paths)} parsed={parsed_state}",
        f"  resource_backing={backing_state}",
        f"  transfer_bounds={bounds_state}",
        f"  fences={len(fence_types)} cmd_types={fence_types}",
        f"  cleanup ctx_destroy={ctx_destroys} detach={detaches} unref={unrefs}",
        f"  expected_errors={'api>=3,malformed>=1,bounds>=1' if args.expect_errors else 'none'}",
        f"  expected_audit={'yes' if args.expect_audit else 'no'}",
        f"  result={'PASS' if passed else 'FAIL'}",
    ]
    for problem in problems:
        lines.append(f"  PROBLEM {problem}")

    text = "\n".join(lines) + "\n"
    out = args.out or capture / "summary.txt"
    out.write_text(text, encoding="utf-8")
    print(out)
    return 1 if args.strict and not passed else 0


if __name__ == "__main__":
    raise SystemExit(main())
