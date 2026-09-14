// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! virgl execbuffer construction for `VioVirgl` — the M4 guest-GPU lane.
//!
//! [`execbuf`] emits a **byte-exact** virgl command stream (`VIRGL_CMD0`
//! framing: `cmd | obj<<8 | body_dwords<<16`, body dwords exclude the header)
//! for a textured-quad draw — object/state creation, sampler+texture, vertex
//! buffer, framebuffer/viewport/scissor, `CLEAR`, `DRAW_VBO` — validated
//! field-for-field against virglrenderer 1.0.0 (`virgl_protocol.h`,
//! `vrend_decode.c`). Shaders are submitted as **TGSI text** (the
//! `tgsi_dump` canonical form `tgsi_text_translate` parses — the binary
//! token wire was retired in virglrenderer 0.9.0). The stream is handed to
//! `VIRTIO_GPU_CMD_SUBMIT_3D` as the
//! OUT payload after the 32-byte `virtio_gpu_cmd_submit` header.
//!
//! **Composite contract** (see `architecture/DISPLAY.md`): the sampler view
//! binds the **2D scanout resource** (`RES_SCAN` = 1) — the host-side surface
//! `VioPaint` already filled from `__scan_fb` via `TRANSFER_TO_HOST_2D`. The
//! draw therefore resamples the *committed display frame* through the GPU
//! into `RES_RT` (a dedicated offscreen render target), which `VioVirgl` then
//! scans out and flushes — the displayed image is GPU-rastered, not a guest
//! copy. `TRANSFER_FROM_HOST_3D` additionally pulls `RES_RT` into
//! `__virgl_out` for the byte-exact readback gate.
//!
//! Scope honesty: the transport, capset negotiation, context lifecycle and
//! this execbuffer are real; the host-GPU raster is proven through the real
//! `virglrenderer` decoder (`out/virgl/`, WSL d3d12 surfaceless EGL) — the
//! `egl-headless,gl=on` QEMU path still needs a host `/dev/dri/renderD*`.

#![allow(missing_docs)]

use crate::encode::{
    virgl_cmd0, VIO_GPU_CTX_ATTACH_RESOURCE, VIO_GPU_CTX_CREATE, VIO_GPU_GET_CAPSET,
    VIO_GPU_GET_CAPSET_INFO, VIO_GPU_RESOURCE_CREATE_3D, VIO_GPU_RESOURCE_FLUSH,
    VIO_GPU_SET_SCANOUT, VIO_GPU_SUBMIT_3D, VIRGL_CCMD_BIND_OBJECT, VIRGL_CCMD_BIND_SAMPLER_STATES,
    VIRGL_CCMD_BIND_SHADER, VIRGL_CCMD_CLEAR, VIRGL_CCMD_CREATE_OBJECT, VIRGL_CCMD_DRAW_VBO,
    VIRGL_CCMD_RESOURCE_INLINE_WRITE, VIRGL_CCMD_SET_FRAMEBUFFER_STATE,
    VIRGL_CCMD_SET_SAMPLER_VIEWS, VIRGL_CCMD_SET_SCISSOR_STATE, VIRGL_CCMD_SET_VERTEX_BUFFERS,
    VIRGL_CCMD_SET_VIEWPORT_STATE, VIRGL_OBJ_BLEND, VIRGL_OBJ_DSA, VIRGL_OBJ_RASTERIZER,
    VIRGL_OBJ_SAMPLER_STATE, VIRGL_OBJ_SAMPLER_VIEW, VIRGL_OBJ_SHADER, VIRGL_OBJ_SURFACE,
    VIRGL_OBJ_VERTEX_ELEMENTS, VIRGL_PRIM_TRIANGLE_STRIP, VIRGL_SHADER_FRAGMENT,
    VIRGL_SHADER_VERTEX,
};

// ---- virgl resource formats (`virgl_hw.h` `enum virgl_formats`) ----
/// `VIRGL_FORMAT_B8G8R8X8_UNORM` — render-target surface and the scanout
/// texture format (matches the 2D resource's `VIO_GPU_FMT_B8G8R8X8`).
pub const VIRGL_FMT_B8G8R8X8: u32 = 2;
/// `VIRGL_FORMAT_R32G32_FLOAT` — the uv vertex element (2 f32).
pub const VIRGL_FMT_R32G32_FLOAT: u32 = 29;
/// `VIRGL_FORMAT_R32G32B32A32_FLOAT` — the position vertex element (4 f32).
pub const VIRGL_FMT_R32G32B32A32_FLOAT: u32 = 31;

// ---- pipe constants (mesa `p_defines.h`) ----
/// `PIPE_CLEAR_COLOR0` — `CLEAR.buffers` selects the colour target.
pub const PIPE_CLEAR_COLOR0: u32 = 1 << 2;
/// `VIRGL_BIND_RENDER_TARGET` — `RESOURCE_CREATE_3D` wire bind bit.
pub const VIRGL_BIND_RENDER_TARGET: u32 = 1 << 1;
/// `VIRGL_BIND_VERTEX_BUFFER` — VBO wire bind bit.
pub const VIRGL_BIND_VERTEX_BUFFER: u32 = 1 << 4;
/// `PIPE_BUFFER` — `RESOURCE_CREATE_3D.target` for a raw buffer (VBO).
pub const PIPE_BUFFER: u32 = 0;
/// `PIPE_TEXTURE_2D` — `RESOURCE_CREATE_3D.target` + sampler-view target.
pub const PIPE_TEXTURE_2D: u32 = 2;
/// `PIPE_TEX_WRAP_CLAMP_TO_EDGE`.
pub const TEX_WRAP_CLAMP_TO_EDGE: u32 = 2;
/// `PIPE_TEX_FILTER_LINEAR`.
pub const TEX_FILTER_LINEAR: u32 = 1;
/// `PIPE_TEX_MIPFILTER_NONE`.
pub const TEX_MIPFILTER_NONE: u32 = 0;
/// `PIPE_BLENDFACTOR_ONE` — opaque blend src factor.
pub const PIPE_BLENDFACTOR_ONE: u32 = 1;
/// `PIPE_SWIZZLE_*` identity packing (X|Y|Z|W at 3 bits each).
pub const SWIZZLE_IDENTITY: u32 = (1 << 3) | (2 << 6) | (3 << 9);

/// Resource handles the execbuffer's objects hang off (the virtio-level
/// `RESOURCE_CREATE_3D` ids `VioVirgl` creates + attaches to ctx 1).
/// `RES_RT` is a **dedicated offscreen render target** — deliberately *not*
/// the scanout resource — so the virgl raster never clobbers `vio_fb` before
/// the present. `RES_SCAN` is the existing 2D scanout resource `VioScan`
/// created: the composite samples it (the committed `__scan_fb` frame) — no
/// extra texture upload, the canonical virgl compositor dataflow.
pub const RES_RT: u32 = 4; // offscreen render target
pub const RES_VBO: u32 = 3; // vertex buffer
pub const RES_SCAN: u32 = 1; // the 2D scanout resource — the composite texture
/// Object handles inside the stream (independent of the virtio resource ids).
pub const OBJ_SURFACE: u32 = 1;
pub const OBJ_VS: u32 = 2;
pub const OBJ_FS: u32 = 3;
pub const OBJ_VERTELEM: u32 = 4;
pub const OBJ_SVIEW: u32 = 5;
pub const OBJ_SSTATE: u32 = 6;
pub const OBJ_BLEND: u32 = 7;
pub const OBJ_DSA: u32 = 8;
pub const OBJ_RAST: u32 = 9;
/// virgl context id `VioVirgl` creates; rides `ctrl_hdr.ctx_id`.
pub const CTX_ID: u32 = 1;

/// Complete `VIRTIO_GPU_CAPSET_VIRGL` v1 wire layout for the bounded model.
/// Zero capability fields intentionally grant no general GLSL profile: the
/// quad model is not a driver-compatible renderer. The client reserves the
/// complete response, including when a real device supplies its capabilities.
pub const CAPSET_WORDS: &[u32] = &[
    1, // max_version
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // sampler formats
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // render formats
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // depth/stencil formats
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // vertex formats
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // capability bits, GLSL and limits
];

/// Vertex stride: `{pos.xyzw, uv.xy}` — 6 f32 = 24 B. Pos carries `w=1` so
/// `OUT[0]` is a complete clip position; a 2-component uv element reads
/// `(u,v,0,1)` which `TEX` samples on `.xy`.
pub const VERT_STRIDE: u32 = 24;
/// Vertex count: one fullscreen quad as a two-triangle strip.
pub const VERT_COUNT: u32 = 4;
/// VBO bytes (`VERT_STRIDE * VERT_COUNT`).
pub const VBO_BYTES: u32 = VERT_STRIDE * VERT_COUNT;

fn f32bits(f: f32) -> u32 {
    f.to_bits()
}

// ---- TGSI text shaders ----
// virglrenderer 1.0.0 accepts **TGSI text**, not binary tokens —
// `vrend_create_shader` runs `tgsi_text_translate` on a NUL-terminated
// string (the `tgsi_dump` canonical form, exactly what a mesa guest emits
// before submit; the binary-token wire was retired in 0.9.0). Both
// programs below follow that grammar: processor header, `DCL` block,
// labelled instructions, `END`.

/// Vertex shader — a fullscreen passthrough: clip position from vertex
/// element 0 (the `R32G32B32A32_FLOAT` attrib), uv varying from element 1
/// (`R32G32_FLOAT`). VS inputs take their binding from the vertex-elements
/// object, so `IN[*]` carries no semantic (the text parser refuses one on
/// a VS input).
const TGSI_VS: &str = "\
VERT
DCL IN[0]
DCL IN[1]
DCL OUT[0], POSITION
DCL OUT[1], GENERIC[0]
  0: MOV OUT[0], IN[0]
  1: MOV OUT[1], IN[1]
  2: END
";

/// Fragment shader — samples the bound 2D sampler view (`RES_SCAN`, the
/// committed scanout texture) at the perspective-interpolated uv from
/// `VS OUT[1]` (`GENERIC[0]` pairs the varying on both sides).
const TGSI_FS: &str = "\
FRAG
DCL IN[0], GENERIC[0], PERSPECTIVE
DCL OUT[0], COLOR
DCL SAMP[0]
DCL SVIEW[0], 2D, UNORM
  0: TEX OUT[0], IN[0], SAMP[0], 2D
  1: END
";

/// One virgl command: `[VIRGL_CMD0(cmd,obj,body.len()), body...]`.
fn cmd(out: &mut Vec<u32>, c: u32, obj: u32, body: &[u32]) {
    out.push(virgl_cmd0(c, obj, body.len() as u32));
    out.extend_from_slice(body);
}

/// `CREATE_OBJECT(SHADER)` body — `[handle, type, offlen, num_tokens,
/// num_so_outputs, text…]`; vrend reads the payload at `shader_offset = 6`,
/// so the `num_so_outputs` dword is mandatory even when zero
/// (`vrend_decode_create_shader`). The payload is **TGSI text**: `offlen`
/// (`VIRGL_OBJ_SHADER_OFFSET`) carries the full byte length including the
/// NUL for a new shader, and vrend rejects the packet when `(offlen + 3)/4`
/// dwords don't cover the body's text span (`vrend_create_shader`'s
/// `expected_token_count < pkt_length` check). `num_tokens` only bounds a
/// scratch translate buffer — a generous hint. The text is NUL-terminated
/// then zero-padded to a dword boundary; the padding guarantees a `\0` in
/// the last 4 bytes, which `vrend_create_shader` requires before
/// `tgsi_text_translate`.
fn shader_obj(handle: u32, shader_type: u32, text: &str) -> Vec<u32> {
    let mut bytes = Vec::with_capacity(text.len() + 4);
    bytes.extend_from_slice(text.as_bytes());
    bytes.push(0);
    while bytes.len() % 4 != 0 {
        bytes.push(0);
    }
    let mut v = Vec::with_capacity(5 + bytes.len() / 4);
    v.extend_from_slice(&[
        handle,
        shader_type,
        text.len() as u32 + 1,
        300, // translate scratch bound — both programs expand to <100 tokens
        0,
    ]);
    for c in bytes.chunks_exact(4) {
        v.push(u32::from_le_bytes([c[0], c[1], c[2], c[3]]));
    }
    v
}

/// The byte-exact textured-quad execbuffer as little-endian bytes (`size` for
/// `virtio_gpu_cmd_submit` counts bytes; virgl reads `size/4` dwords). The
/// sampler view binds `RES_SCAN` — the committed 2D scanout surface — so the
/// draw composites the guest's presented frame onto `RES_RT`.
pub fn execbuf(w: u32, h: u32) -> Vec<u8> {
    let mut s: Vec<u32> = Vec::new();
    // Render-target surface over virtio resource RES_RT.
    cmd(
        &mut s,
        VIRGL_CCMD_CREATE_OBJECT,
        VIRGL_OBJ_SURFACE,
        &[OBJ_SURFACE, RES_RT, VIRGL_FMT_B8G8R8X8, 0, 0],
    );
    // Vertex + fragment shaders — TGSI text programs (the virgl wire
    // format; `vrend_create_shader` runs `tgsi_text_translate`).
    let vs = shader_obj(OBJ_VS, VIRGL_SHADER_VERTEX, TGSI_VS);
    cmd(&mut s, VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJ_SHADER, &vs);
    let fs = shader_obj(OBJ_FS, VIRGL_SHADER_FRAGMENT, TGSI_FS);
    cmd(&mut s, VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJ_SHADER, &fs);
    // Vertex layout: elem0 pos.xyzw off 0 (`R32G32B32A32_FLOAT`), elem1 uv.xy
    // off 16 (`R32G32_FLOAT`), both on vertex-buffer index 0. Body is
    // `[handle][src_offset, instance_divisor, vb_index, src_format]×n`
    // (`VIRGL_OBJ_VERTEX_ELEMENTS_V0_*`).
    cmd(
        &mut s,
        VIRGL_CCMD_CREATE_OBJECT,
        VIRGL_OBJ_VERTEX_ELEMENTS,
        &[
            OBJ_VERTELEM,
            0,
            0,
            0,
            VIRGL_FMT_R32G32B32A32_FLOAT,
            16,
            0,
            0,
            VIRGL_FMT_R32G32_FLOAT,
        ],
    );
    // Texture view onto the *scanout* resource (the composite source):
    // `[handle, res, format|target<<24, layer, level, swizzle]`
    // (`VIRGL_OBJ_SAMPLER_VIEW_*` — `format_data` packs the pipe target).
    cmd(
        &mut s,
        VIRGL_CCMD_CREATE_OBJECT,
        VIRGL_OBJ_SAMPLER_VIEW,
        &[
            OBJ_SVIEW,
            RES_SCAN,
            VIRGL_FMT_B8G8R8X8 | (PIPE_TEXTURE_2D << 24),
            0,
            0,
            SWIZZLE_IDENTITY,
        ],
    );
    // Linear, clamp-to-edge sampler: `[handle, S0, lod_bias, min_lod,
    // max_lod, border×4]` (`VIRGL_OBJ_SAMPLER_STATE_*`; lod fields are f32).
    let s0 = TEX_WRAP_CLAMP_TO_EDGE
        | (TEX_WRAP_CLAMP_TO_EDGE << 3)
        | (TEX_WRAP_CLAMP_TO_EDGE << 6)
        | (TEX_FILTER_LINEAR << 9)
        | (TEX_MIPFILTER_NONE << 11)
        | (TEX_FILTER_LINEAR << 13);
    cmd(
        &mut s,
        VIRGL_CCMD_CREATE_OBJECT,
        VIRGL_OBJ_SAMPLER_STATE,
        &[OBJ_SSTATE, s0, 0, 0, f32bits(32.0), 0, 0, 0, 0],
    );
    // Opaque blend / dsa / rasterizer so the draw has a complete state set.
    // BLEND body is `[handle, S0, S1, S2(cbuf0..7)]` — 11 dwords; cbuf0
    // carries src/dst=ONE/ZERO plus the colour mask (without `COLORMASK` the
    // draw writes nothing). DSA is 5 dwords (depth/stencil all off);
    // rasterizer is 9 (all-zero state: fill both, cull none).
    let blend_s2 = (PIPE_BLENDFACTOR_ONE << 4) | (PIPE_BLENDFACTOR_ONE << 17) | (0xf << 27);
    cmd(
        &mut s,
        VIRGL_CCMD_CREATE_OBJECT,
        VIRGL_OBJ_BLEND,
        &[OBJ_BLEND, 0, 0, blend_s2, 0, 0, 0, 0, 0, 0, 0],
    );
    cmd(
        &mut s,
        VIRGL_CCMD_CREATE_OBJECT,
        VIRGL_OBJ_DSA,
        &[OBJ_DSA, 0, 0, 0, 0],
    );
    cmd(
        &mut s,
        VIRGL_CCMD_CREATE_OBJECT,
        VIRGL_OBJ_RASTERIZER,
        &[OBJ_RAST, 0, 0, 0, 0, 0, 0, 0, 0],
    );
    // Bind the state objects — a created-but-unbound object is inert.
    // `BIND_OBJECT` body = `[handle]`, type in the command header.
    cmd(
        &mut s,
        VIRGL_CCMD_BIND_OBJECT,
        VIRGL_OBJ_BLEND,
        &[OBJ_BLEND],
    );
    cmd(&mut s, VIRGL_CCMD_BIND_OBJECT, VIRGL_OBJ_DSA, &[OBJ_DSA]);
    cmd(
        &mut s,
        VIRGL_CCMD_BIND_OBJECT,
        VIRGL_OBJ_RASTERIZER,
        &[OBJ_RAST],
    );
    // Bind shaders, vertex layout, sampler state; attach the texture view.
    // `BIND_SHADER` body = `[handle, PIPE_SHADER_*]`; `BIND_SAMPLER_STATES`
    // and `SET_SAMPLER_VIEWS` = `[shader_type, start_slot, handles…]` — all
    // slot 0 on the fragment stage.
    cmd(
        &mut s,
        VIRGL_CCMD_BIND_SHADER,
        0,
        &[OBJ_VS, VIRGL_SHADER_VERTEX],
    );
    cmd(
        &mut s,
        VIRGL_CCMD_BIND_SHADER,
        0,
        &[OBJ_FS, VIRGL_SHADER_FRAGMENT],
    );
    cmd(
        &mut s,
        VIRGL_CCMD_BIND_OBJECT,
        VIRGL_OBJ_VERTEX_ELEMENTS,
        &[OBJ_VERTELEM],
    );
    cmd(
        &mut s,
        VIRGL_CCMD_BIND_SAMPLER_STATES,
        0,
        &[VIRGL_SHADER_FRAGMENT, 0, OBJ_SSTATE],
    );
    cmd(
        &mut s,
        VIRGL_CCMD_SET_SAMPLER_VIEWS,
        0,
        &[VIRGL_SHADER_FRAGMENT, 0, OBJ_SVIEW],
    );
    // Upload the vertex buffer (fullscreen quad: `{x,y,0,1,u,v}` per vertex,
    // triangle strip) via an inline write. IW body = `[res, level, usage,
    // stride, layer_stride, x,y,z,w,h,d, data…]`; for a buffer the box is in
    // bytes (`w` = byte count). Both resources use `Y_0_TOP`, including
    // the source created by QEMU's CREATE_2D path. Transfers already handle
    // that orientation; UV follows clip XY without an additional V flip.
    // A source created without Y_0_TOP is not the guest's scanout contract.
    let quad: [f32; 24] = [
        -1.0, -1.0, 0.0, 1.0, 0.0, 0.0, 1.0, -1.0, 0.0, 1.0, 1.0, 0.0, -1.0, 1.0, 0.0, 1.0, 0.0,
        1.0, 1.0, 1.0, 0.0, 1.0, 1.0, 1.0,
    ];
    let mut vb: Vec<u32> = vec![RES_VBO, 0, 0, 0, 0, 0, 0, 0, VBO_BYTES, 1, 1];
    vb.extend(quad.iter().map(|f| f32bits(*f)));
    cmd(&mut s, VIRGL_CCMD_RESOURCE_INLINE_WRITE, 0, &vb);
    // Vertex buffer 0 → RES_VBO: `[stride, offset, res]×n`
    // (`VIRGL_SET_VERTEX_BUFFER_*`).
    cmd(
        &mut s,
        VIRGL_CCMD_SET_VERTEX_BUFFERS,
        0,
        &[VERT_STRIDE, 0, RES_VBO],
    );
    // Scissor + viewport + framebuffer.
    cmd(
        &mut s,
        VIRGL_CCMD_SET_SCISSOR_STATE,
        0,
        &[0, 0, (w & 0xffff) | (h << 16)],
    );
    cmd(
        &mut s,
        VIRGL_CCMD_SET_VIEWPORT_STATE,
        0,
        &[
            0,
            f32bits(w as f32 / 2.0),
            f32bits(h as f32 / 2.0),
            f32bits(1.0),
            f32bits(w as f32 / 2.0),
            f32bits(h as f32 / 2.0),
            f32bits(0.0),
        ],
    );
    cmd(
        &mut s,
        VIRGL_CCMD_SET_FRAMEBUFFER_STATE,
        0,
        &[1, 0, OBJ_SURFACE],
    );
    // Clear then draw the textured quad (two-triangle strip → 4 verts).
    cmd(
        &mut s,
        VIRGL_CCMD_CLEAR,
        0,
        &[
            PIPE_CLEAR_COLOR0, // buffers
            f32bits(0.05),     // color r
            f32bits(0.05),     // color g
            f32bits(0.10),     // color b
            f32bits(1.0),      // color a
            0,                 // depth double lo  (1.0 = 0x3ff0_0000_0000_0000)
            0x3ff0_0000,       // depth double hi
            0,                 // stencil
        ],
    );
    cmd(
        &mut s,
        VIRGL_CCMD_DRAW_VBO,
        0,
        &[
            0,
            VERT_COUNT,
            VIRGL_PRIM_TRIANGLE_STRIP,
            0,
            1,
            0,
            0,
            0,
            0,
            0,
            VERT_COUNT - 1,
            0,
        ],
    );
    let mut bytes = Vec::with_capacity(s.len() * 4);
    for dw in s {
        bytes.extend_from_slice(&dw.to_le_bytes());
    }
    bytes
}

/// The full M4 virgl stream for a spec — `(execbuf, reqtab, w, h)` at the
/// proxy geometry. Exported for the `g6b virgl-dump` tool so the host-side
/// `libvirglrenderer` harness (`out/virgl/`) always feeds the byte-exact
/// stream the guest would submit — never a hand-copied stale blob.
pub fn stream(spec: &g6b_spec::BoardSpec) -> (Vec<u8>, Vec<u8>, u32, u32) {
    let gp = crate::analyze::g6b_spec_proxy(spec);
    (execbuf(gp.0, gp.1), reqtab(gp.0, gp.1), gp.0, gp.1)
}

/// `REQTAB` record flag: this request submits `__virgl_cmd` as the second OUT
/// descriptor (`VioVirgl` calls `VioCmdBuf` instead of `VioCmd`).
pub const REQFLAG_BUF: u32 = 1;

/// A `virtio_gpu_ctrl_hdr` (24 bytes): `type`@0, `ctx_id`@16.
fn ctrl_hdr(ty: u32, ctx: u32) -> Vec<u8> {
    let mut v = vec![0u8; 24];
    v[0..4].copy_from_slice(&ty.to_le_bytes());
    v[16..20].copy_from_slice(&ctx.to_le_bytes());
    v
}

/// Append one request record `[req_len][resp_len][flags][req…]`.
fn push_rec(out: &mut Vec<u8>, req: &[u8], resp_len: u32, flags: u32) {
    out.extend_from_slice(&(req.len() as u32).to_le_bytes());
    out.extend_from_slice(&resp_len.to_le_bytes());
    out.extend_from_slice(&flags.to_le_bytes());
    out.extend_from_slice(req);
}

/// `virtio_gpu_resource_create_3d` body (48 B): `{resource_id, target,
/// format, bind, w, h, depth, array_size, last_level, nr_samples, flags,
/// padding}` — the wire order is *target then format* (QEMU
/// `virtio_gpu.h`), and `flags` carries `VIRTIO_GPU_RESOURCE_FLAG_Y_0_TOP`
/// on the render target so the scanout reads the guest's top-down rows
/// correctly.
fn create3d(res: u32, target: u32, format: u32, bind: u32, w: u32, h: u32, flags: u32) -> Vec<u8> {
    let mut r = ctrl_hdr(VIO_GPU_RESOURCE_CREATE_3D, CTX_ID);
    for v in [res, target, format, bind, w, h, 1, 1, 0, 0, flags, 0] {
        r.extend_from_slice(&v.to_le_bytes());
    }
    r
}

/// `virtio_gpu_ctx_attach_resource` body — `{resource_id, pad}`.
fn attach(res: u32) -> Vec<u8> {
    let mut r = ctrl_hdr(VIO_GPU_CTX_ATTACH_RESOURCE, CTX_ID);
    r.extend_from_slice(&res.to_le_bytes());
    r.extend_from_slice(&0u32.to_le_bytes());
    r
}

/// `VioVirgl`'s ctrlq request table: CAPSET_INFO → CAPSET → CTX_CREATE →
/// CREATE_3D(RES_RT render target, RES_VBO vertex buffer) →
/// CTX_ATTACH(RES_RT, RES_VBO, RES_SCAN) → SUBMIT_3D(execbuf) →
/// SET_SCANOUT(RES_RT) → RESOURCE_FLUSH(RES_RT), terminated by a
/// `req_len == 0` sentinel. Each record is length-prefixed
/// (`[req_len][resp_len][flags][req]`) so `VioVirgl` is a compact
/// copy-and-submit loop rather than ~200 per-dword `sw` ops.
///
/// `RES_SCAN` (the 2D scanout resource `VioScan` created, id 1) is attached
/// to the virgl ctx so the execbuffer's sampler view can composite the
/// committed `__scan_fb` frame — that is why `VioVirgl` runs **after**
/// `VioPaint` (the `TRANSFER_TO_HOST_2D` upload must have landed). The
/// trailing `SET_SCANOUT`+`FLUSH` moves the console onto the GPU-rastered
/// `RES_RT`; on a non-virgl device every record fails closed (`ERR_*`) and
/// the 2D scanout is untouched. The `__virgl_out` readback pair
/// (`RESOURCE_ATTACH_BACKING` + `TRANSFER_FROM_HOST_3D`) is sw-built in
/// `vio.rs::virgl_node` — it needs the resolved BSS address a static record
/// can't carry.
pub fn reqtab(w: u32, h: u32) -> Vec<u8> {
    let capset_bytes = CAPSET_WORDS.len() as u32 * 4;
    let mut out = Vec::new();
    // GET_CAPSET_INFO — body{capset_index=0, pad}.
    let mut r = ctrl_hdr(VIO_GPU_GET_CAPSET_INFO, 0);
    r.extend_from_slice(&0u32.to_le_bytes());
    r.extend_from_slice(&0u32.to_le_bytes());
    push_rec(&mut out, &r, 40, 0);
    // GET_CAPSET — body{capset_id=VIRGL, capset_version=1}; resp = hdr + blob.
    let mut r = ctrl_hdr(VIO_GPU_GET_CAPSET, 0);
    r.extend_from_slice(&crate::encode::VIO_GPU_CAPSET_VIRGL.to_le_bytes());
    r.extend_from_slice(&1u32.to_le_bytes());
    push_rec(&mut out, &r, 24 + capset_bytes, 0);
    // CTX_CREATE — body{nlen, context_init, debug_name[64]="main"}.
    let mut r = ctrl_hdr(VIO_GPU_CTX_CREATE, CTX_ID);
    r.extend_from_slice(&4u32.to_le_bytes());
    r.extend_from_slice(&0u32.to_le_bytes());
    let mut name = [0u8; 64];
    name[..4].copy_from_slice(b"main");
    r.extend_from_slice(&name);
    push_rec(&mut out, &r, 24, 0);
    // RES_RT — the offscreen render target (w×h B8G8R8X8, RENDER_TARGET).
    // `Y_0_TOP` so the scanout treats guest rows as top-down.
    push_rec(
        &mut out,
        &create3d(
            RES_RT,
            PIPE_TEXTURE_2D,
            VIRGL_FMT_B8G8R8X8,
            VIRGL_BIND_RENDER_TARGET,
            w,
            h,
            1, // VIRTIO_GPU_RESOURCE_FLAG_Y_0_TOP
        ),
        24,
        0,
    );
    // RES_VBO — a raw buffer resource for the quad verts (PIPE_BUFFER,
    // VERTEX_BUFFER; `width` is the byte size).
    push_rec(
        &mut out,
        &create3d(
            RES_VBO,
            PIPE_BUFFER,
            0,
            VIRGL_BIND_VERTEX_BUFFER,
            VBO_BYTES,
            1,
            0,
        ),
        24,
        0,
    );
    // CTX_ATTACH_RESOURCE ×3 — RES_RT, RES_VBO, and RES_SCAN (the 2D
    // scanout resource, already created by `VioScan`, becomes samplable by
    // ctx 1 for the composite).
    for res in [RES_RT, RES_VBO, RES_SCAN] {
        push_rec(&mut out, &attach(res), 24, 0);
    }
    // SUBMIT_3D — body{size=execbuf bytes, num_in_fences=0}; REQFLAG_BUF.
    let mut r = ctrl_hdr(VIO_GPU_SUBMIT_3D, CTX_ID);
    r[4..8].copy_from_slice(&1u32.to_le_bytes());
    r[8..16].copy_from_slice(&1u64.to_le_bytes());
    let eb = execbuf(w, h).len() as u32;
    r.extend_from_slice(&eb.to_le_bytes());
    r.extend_from_slice(&0u32.to_le_bytes());
    push_rec(&mut out, &r, 24, REQFLAG_BUF);
    // SET_SCANOUT — move scanout 0 onto RES_RT (rect {0,0,w,h}); the console
    // then shows the GPU-composited texture.
    let mut r = ctrl_hdr(VIO_GPU_SET_SCANOUT, 0);
    for v in [0, 0, w, h, 0, RES_RT] {
        r.extend_from_slice(&v.to_le_bytes());
    }
    push_rec(&mut out, &r, 24, 0);
    // RESOURCE_FLUSH — present RES_RT's rendered content to the scanout.
    let mut r = ctrl_hdr(VIO_GPU_RESOURCE_FLUSH, 0);
    for v in [0, 0, w, h, RES_RT, 0] {
        r.extend_from_slice(&v.to_le_bytes());
    }
    push_rec(&mut out, &r, 24, 0);
    // Sentinel — `req_len == 0` ends the loop (the `__virgl_out` readback
    // pair follows in `vio.rs::virgl_node`).
    out.extend_from_slice(&0u32.to_le_bytes());
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(bytes: &[u8]) -> Vec<u32> {
        assert_eq!(bytes.len() % 4, 0);
        bytes
            .chunks_exact(4)
            .map(|b| u32::from_le_bytes(b.try_into().unwrap()))
            .collect()
    }

    fn commands(bytes: &[u8]) -> Vec<(u32, u32, Vec<u32>)> {
        let data = words(bytes);
        let mut out = Vec::new();
        let mut pos = 0;
        while pos < data.len() {
            let header = data[pos];
            let end = pos + 1 + (header >> 16) as usize;
            assert!(end <= data.len());
            out.push((
                header & 255,
                (header >> 8) & 255,
                data[pos + 1..end].to_vec(),
            ));
            pos = end;
        }
        out
    }

    fn requests(bytes: &[u8]) -> Vec<Vec<u32>> {
        let data = words(bytes);
        let mut out = Vec::new();
        let mut pos = 0;
        while data[pos] != 0 {
            let len = data[pos] as usize;
            assert_eq!(len % 4, 0);
            let start = pos + 3;
            pos = start + len / 4;
            assert!(pos < data.len());
            out.push(data[start..pos].to_vec());
        }
        assert_eq!(pos + 1, data.len());
        out
    }

    #[test]
    fn p0_y0_top_composite_does_not_flip_uv_twice() {
        let stream = commands(&execbuf(64, 32));
        let (_, _, upload) = stream
            .iter()
            .find(|(cmd, _, body)| *cmd == 9 && body[0] == RES_VBO)
            .unwrap();
        for vertex in upload[11..].chunks_exact(6) {
            let x = f32::from_bits(vertex[0]);
            let y = f32::from_bits(vertex[1]);
            assert_eq!(f32::from_bits(vertex[4]), (x + 1.0) * 0.5);
            assert_eq!(f32::from_bits(vertex[5]), (y + 1.0) * 0.5);
        }
    }

    #[test]
    fn p0_submit_is_fenced_before_scanout() {
        let records = requests(&reqtab(64, 32));
        let submit = records.iter().position(|r| r[0] == 0x0207).unwrap();
        let scanout = records.iter().position(|r| r[0] == 0x0103).unwrap();
        assert!(submit < scanout);
        assert_eq!(records[submit][1] & 1, 1);
        assert_ne!(
            u64::from(records[submit][2]) | (u64::from(records[submit][3]) << 32),
            0
        );
    }

    #[test]
    fn p0_capset_has_v1_wire_layout_without_a_glsl_grant() {
        assert_eq!(CAPSET_WORDS.len(), 77);
        assert_eq!(CAPSET_WORDS[0], 1);
        assert_eq!(CAPSET_WORDS[66], 0);
    }

    #[test]
    fn p0_capset_request_can_receive_the_complete_v1_response() {
        let data = words(&reqtab(64, 32));
        let capset = 3 + data[0] as usize / 4;
        assert_eq!(data[capset + 1], 24 + 308);
        assert!(data[capset + 1] as i64 <= crate::vio::VIO_RSP_LEN);
        let request = &data[capset + 3..];
        assert_eq!(request[0], 0x0109);
        assert_eq!(&request[6..8], &[1, 1]);
    }

    #[test]
    fn p0_virtio_gpu_feature_bits_match_device_spec() {
        assert_eq!(
            [
                crate::encode::VIO_GPU_F_VIRGL,
                crate::encode::VIO_GPU_F_RESOURCE_BLOB,
                crate::encode::VIO_GPU_F_CONTEXT_INIT,
            ],
            [1, 8, 16]
        );
    }

    #[test]
    fn p0_resource_creation_uses_virgl_wire_bind_flags() {
        let records = requests(&reqtab(64, 32));
        let resources: Vec<_> = records.iter().filter(|r| r[0] == 0x0204).collect();
        assert_eq!(resources.len(), 2);
        let rt = resources.iter().find(|r| r[6] == RES_RT).unwrap();
        assert_eq!(&rt[7..12], &[2, 2, 2, 64, 32]);
        let vbo = resources.iter().find(|r| r[6] == RES_VBO).unwrap();
        assert_eq!(&vbo[7..12], &[0, 0, 16, 96, 1]);
    }

    #[test]
    fn p0_clear_selects_color_not_depth() {
        let stream = commands(&execbuf(64, 32));
        let (_, _, clear) = stream.iter().find(|(cmd, _, _)| *cmd == 7).unwrap();
        assert_eq!(clear.len(), 8);
        assert_eq!(clear[0], 4);
        assert_eq!(&clear[5..8], &[0, 0x3ff0_0000, 0]);
    }

    #[test]
    fn p0_shader_payloads_are_nul_terminated_tgsi_text() {
        let stream = commands(&execbuf(64, 32));
        let shaders: Vec<_> = stream
            .iter()
            .filter(|(cmd, obj, _)| *cmd == 1 && *obj == 4)
            .collect();
        assert_eq!(shaders.len(), 2);
        for ((_, _, body), stage) in shaders.iter().zip([0, 1]) {
            assert_eq!(body[1], stage);
            assert_eq!(body[4], 0);
            let bytes: Vec<_> = body[5..].iter().flat_map(|w| w.to_le_bytes()).collect();
            let length = body[2] as usize;
            assert!(length > 1 && length <= bytes.len());
            assert_eq!(length.div_ceil(4), body.len() - 5);
            assert!(bytes[length - 1..].iter().all(|b| *b == 0));
            let text = std::str::from_utf8(&bytes[..length - 1]).unwrap();
            assert!(text.starts_with(if stage == 0 { "VERT\n" } else { "FRAG\n" }));
            assert!(text.ends_with("END\n"));
            assert!(!text.as_bytes().contains(&0));
            assert!(stream
                .iter()
                .any(|(cmd, _, binding)| *cmd == 31 && binding == &[body[0], stage]));
        }
    }

    #[test]
    fn p0_state_objects_are_bound_before_draw() {
        let stream = commands(&execbuf(64, 32));
        let draw = stream.iter().position(|(cmd, _, _)| *cmd == 8).unwrap();
        for (object, handle) in [
            (1, OBJ_BLEND),
            (2, OBJ_RAST),
            (3, OBJ_DSA),
            (5, OBJ_VERTELEM),
        ] {
            let create = stream
                .iter()
                .position(|(cmd, obj, body)| *cmd == 1 && *obj == object && body[0] == handle)
                .unwrap();
            let bind = stream
                .iter()
                .position(|(cmd, obj, body)| *cmd == 2 && *obj == object && body == &[handle])
                .unwrap();
            assert!(create < bind && bind < draw);
        }
    }
}
