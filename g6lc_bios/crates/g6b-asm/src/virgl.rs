// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! virgl execbuffer construction for `VioVirgl` — the M4 guest-GPU lane.
//!
//! [`execbuf`] emits a **real-encoded** virgl command stream (`VIRGL_CMD0`
//! framing: `cmd | obj<<8 | body_dwords<<16`, body dwords exclude the header)
//! for a textured-quad draw: object/state creation, sampler+texture, vertex
//! buffer, framebuffer/viewport/scissor, `CLEAR`, `DRAW_VBO`. The stream is
//! handed to `VIRTIO_GPU_CMD_SUBMIT_3D` as the OUT payload after the 32-byte
//! `virtio_gpu_cmd_submit` header.
//!
//! Scope honesty (see `architecture/DISPLAY.md`): the transport, capset
//! negotiation, context lifecycle and this execbuffer are real and
//! exec-model-verified end-to-end; the two TGSI shader bodies are a *bounded
//! minimal program* (header + processor + END) — the byte-exact TGSI
//! textured-sampling program and the real-GPU QEMU raster remain the open gate
//! pending a host with a DRM render node (`egl-headless,gl=on` refuses the
//! device on hosts without `/dev/dri/renderD*`).

#![allow(missing_docs)]

use crate::encode::{
    virgl_cmd0, VIO_GPU_CTX_ATTACH_RESOURCE, VIO_GPU_CTX_CREATE, VIO_GPU_GET_CAPSET,
    VIO_GPU_GET_CAPSET_INFO, VIO_GPU_RESOURCE_CREATE_3D, VIO_GPU_SUBMIT_3D, VIRGL_CCMD_BIND_OBJECT,
    VIRGL_CCMD_BIND_SAMPLER_STATES, VIRGL_CCMD_BIND_SHADER, VIRGL_CCMD_CLEAR,
    VIRGL_CCMD_CREATE_OBJECT, VIRGL_CCMD_DRAW_VBO, VIRGL_CCMD_RESOURCE_INLINE_WRITE,
    VIRGL_CCMD_SET_FRAMEBUFFER_STATE, VIRGL_CCMD_SET_SAMPLER_VIEWS, VIRGL_CCMD_SET_SCISSOR_STATE,
    VIRGL_CCMD_SET_VERTEX_BUFFERS, VIRGL_CCMD_SET_VIEWPORT_STATE, VIRGL_OBJ_BLEND, VIRGL_OBJ_DSA,
    VIRGL_OBJ_RASTERIZER, VIRGL_OBJ_SAMPLER_STATE, VIRGL_OBJ_SAMPLER_VIEW, VIRGL_OBJ_SHADER,
    VIRGL_OBJ_SURFACE, VIRGL_OBJ_VERTEX_ELEMENTS, VIRGL_PRIM_TRIANGLE_STRIP, VIRGL_SHADER_FRAGMENT,
    VIRGL_SHADER_VERTEX,
};

/// `VIRGL_FORMAT_B8G8R8X8_UNORM` — the virgl-side format enum for the
/// render-target surface and the texture (`virgl_formats.h`).
pub const VIRGL_FMT_B8G8R8X8: u32 = 6;
/// `PIPE_CLEAR_COLOR0` — `CLEAR.buffers` selects the colour target.
pub const PIPE_CLEAR_COLOR0: u32 = 1;
/// `PIPE_SHADER_*` read from `virgl_protocol.h`; see [`VIRGL_SHADER_VERTEX`].
/// `PIPE_BIND_RENDER_TARGET` — `RESOURCE_CREATE_3D`/`surface` bind bit.
pub const PIPE_BIND_RENDER_TARGET: u32 = 1 << 0;
/// `PIPE_BIND_SAMPLER_VIEW` — texture-resource bind bit.
pub const PIPE_BIND_SAMPLER_VIEW: u32 = 1 << 4;
/// `PIPE_BIND_VERTEX_BUFFER` — vbo bind bit.
pub const PIPE_BIND_VERTEX_BUFFER: u32 = 1 << 3;

/// Resource handles the execbuffer's objects hang off (the virtio-level
/// `RESOURCE_CREATE_3D` ids `VioVirgl` creates + attaches to ctx 1).
/// `RES_RT` is a **dedicated offscreen render target** — deliberately *not*
/// the scanout resource (id 1, `VioScan`'s) — so the virgl bring-up never
/// clobbers the committed 2D/display frame; the quad is verified in the
/// device-side `virgl_fb` surface (and readback is the gated follow-up).
pub const RES_RT: u32 = 4; // offscreen render target
pub const RES_TEX: u32 = 2; // texture
pub const RES_VBO: u32 = 3; // vertex buffer
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

/// Bounded `VIRTIO_GPU_CAPSET_VIRGL2` blob (`virgl_caps_v2`) the modelled
/// device answers `GET_CAPSET` with. Only the leading fields a bring-up guest
/// reads are populated; the rest stay 0 (the capset is a capability *report*,
/// not a command — the model fills a fixed, documented subset).
pub const CAPSET_WORDS: &[u32] = &[
    0xdead_beef, // wire marker (max_version is the real field the guest reads)
    2,           // max_version
    0,           // max_size high bits / reserved
    0,           // bset (capability bitset) — bounded model
    0,           // glsl_level
    0,           // features
];

/// 4×4 checkerboard texture (16 px, B8G8R8X8) — the quad's `u_dom` sampler.
/// Two alternating colours so a texture-byte kill test flips the pattern.
pub const TEX_W: u32 = 4;
pub const TEX_H: u32 = 4;
pub const TEX_A: u32 = 0x00ff_8040; // orange
pub const TEX_B: u32 = 0x0040_20ff; // blue

fn f32bits(f: f32) -> u32 {
    f.to_bits()
}

/// A minimal, structurally-valid TGSI program: header + processor token + a
/// single `END` instruction. The full textured-sampling TGSI is the
/// QEMU-gated follow-up (see the module doc); `vrend_decode_create_shader`
/// reads `type`/`num_tokens`/`offlen`/`shader_offset=6`, which this honours.
fn tgsi_stub(processor: u32) -> Vec<u32> {
    // header: header_size=1, body_size=3 (header + proc + END token).
    // processor token: type field in bits[3:0].
    // END token: tgsi_token{type=TGSI_TOKEN_TYPE_INSTRUCTION(0),
    //   nr_tokens=1, opcode=TGSI_OPCODE_END(21)} → (0<<4)|... opcode<<…
    //   tgsi_token layout: type:4, nr_tokens:8, opcode:... — we emit a single
    //   instruction token whose opcode = TGSI_OPCODE_END.
    let hdr = 0x0000_0301u32; // header_size=1, body_size=3
    let proc_tok = processor; // TGSI_PROCESSOR_* in low nibble
                              // tgsi_token: {type:4, nr_tokens:8, opcode:16-ish}. INSTRUCTION token with
                              // opcode END(21) — a minimal well-formed terminator.
    let end = 21u32 << 4; // opcode in the token's opcode field window
    vec![hdr, proc_tok, end]
}

/// One virgl command: `[VIRGL_CMD0(cmd,obj,body.len()), body...]`.
fn cmd(out: &mut Vec<u32>, c: u32, obj: u32, body: &[u32]) {
    out.push(virgl_cmd0(c, obj, body.len() as u32));
    out.extend_from_slice(body);
}

/// The bounded textured-quad execbuffer as little-endian bytes (`size` for
/// `virtio_gpu_cmd_submit` counts bytes; virgl reads `size/4` dwords).
pub fn execbuf(w: u32, h: u32) -> Vec<u8> {
    let mut s: Vec<u32> = Vec::new();
    // Render-target surface over virtio resource RES_RT.
    cmd(
        &mut s,
        VIRGL_CCMD_CREATE_OBJECT,
        VIRGL_OBJ_SURFACE,
        &[OBJ_SURFACE, RES_RT, VIRGL_FMT_B8G8R8X8, 0, 0],
    );
    // Vertex + fragment shaders (bounded TGSI stubs).
    let mut vs = vec![OBJ_VS, VIRGL_SHADER_VERTEX, 0, 0, 0]; // handle,type,off,offhi,ntok
    let vt = tgsi_stub(VIRGL_SHADER_VERTEX);
    vs[4] = vt.len() as u32;
    vs.extend_from_slice(&vt);
    cmd(&mut s, VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJ_SHADER, &vs);
    let mut fs = vec![OBJ_FS, VIRGL_SHADER_FRAGMENT, 0, 0, 0];
    let ft = tgsi_stub(VIRGL_SHADER_FRAGMENT);
    fs[4] = ft.len() as u32;
    fs.extend_from_slice(&ft);
    cmd(&mut s, VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJ_SHADER, &fs);
    // Vertex layout: (pos.xy, uv.xy) interleaved, 16B stride in RES_VBO.
    cmd(
        &mut s,
        VIRGL_CCMD_CREATE_OBJECT,
        VIRGL_OBJ_VERTEX_ELEMENTS,
        &[
            OBJ_VERTELEM,
            2, // num_elements
            0,
            16,
            VIRGL_FMT_B8G8R8X8,
            0, // elem0: pos off0 stride16
            8,
            16,
            VIRGL_FMT_B8G8R8X8,
            0, // elem1: uv off8 stride16
        ],
    );
    // Texture view onto RES_TEX + a linear clamp sampler.
    cmd(
        &mut s,
        VIRGL_CCMD_CREATE_OBJECT,
        VIRGL_OBJ_SAMPLER_VIEW,
        &[OBJ_SVIEW, RES_TEX, VIRGL_FMT_B8G8R8X8, 0, 0, 0, 0, 0, 0],
    );
    cmd(
        &mut s,
        VIRGL_CCMD_CREATE_OBJECT,
        VIRGL_OBJ_SAMPLER_STATE,
        &[OBJ_SSTATE, 0, 1, 1, 1, 1, 1, 0, 0],
    );
    // Opaque blend / dsa / rasterizer so the draw has a complete state set.
    cmd(
        &mut s,
        VIRGL_CCMD_CREATE_OBJECT,
        VIRGL_OBJ_BLEND,
        &[OBJ_BLEND, 0, 0, 0, 0, 0, 0, 0, 0],
    );
    cmd(
        &mut s,
        VIRGL_CCMD_CREATE_OBJECT,
        VIRGL_OBJ_DSA,
        &[OBJ_DSA, 0, 0, 0, 0, 0, 0, 0],
    );
    cmd(
        &mut s,
        VIRGL_CCMD_CREATE_OBJECT,
        VIRGL_OBJ_RASTERIZER,
        &[OBJ_RAST, 0, 0, 0, 0, 0, 0, 0, 0],
    );
    // Bind shaders, vertex layout, sampler state; attach the texture view.
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
    cmd(&mut s, VIRGL_CCMD_BIND_SAMPLER_STATES, 0, &[OBJ_SSTATE, 1]);
    cmd(
        &mut s,
        VIRGL_CCMD_SET_SAMPLER_VIEWS,
        0,
        &[VIRGL_SHADER_FRAGMENT, 1, OBJ_SVIEW],
    );
    // Upload the vertex buffer (two triangles, pos.xy+uv.xy per vertex) and
    // the 4×4 checkerboard texture via inline writes.
    let quad: [f32; 24] = [
        -1.0, -1.0, 0.0, 0.0, 1.0, -1.0, 1.0, 0.0, -1.0, 1.0, 0.0, 1.0, 1.0, -1.0, 1.0, 0.0, -1.0,
        1.0, 0.0, 1.0, 1.0, 1.0, 1.0, 1.0,
    ];
    let mut vb: Vec<u32> = vec![RES_VBO, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    vb.extend(quad.iter().map(|f| f32bits(*f)));
    cmd(&mut s, VIRGL_CCMD_RESOURCE_INLINE_WRITE, 0, &vb);
    let mut tex: Vec<u32> = vec![RES_TEX, 0, TEX_W * 4, 0, 0, 0, 0, 0, 0, TEX_W, TEX_H, 1];
    for y in 0..TEX_H {
        for x in 0..TEX_W {
            tex.push(if (x + y) % 2 == 0 { TEX_A } else { TEX_B });
        }
    }
    cmd(&mut s, VIRGL_CCMD_RESOURCE_INLINE_WRITE, 0, &tex);
    // Vertex buffer 0 → RES_VBO (stride 16).
    cmd(&mut s, VIRGL_CCMD_SET_VERTEX_BUFFERS, 0, &[0, RES_VBO, 16]);
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
    // Clear then draw the textured quad (two-triangle strip → 6 verts).
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
        &[0, 6, VIRGL_PRIM_TRIANGLE_STRIP, 0, 1, 0, 0, 0, 0, 0, 6, 0],
    );
    let mut bytes = Vec::with_capacity(s.len() * 4);
    for dw in s {
        bytes.extend_from_slice(&dw.to_le_bytes());
    }
    bytes
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

/// `VioVirgl`'s ctrlq request table: CAPSET_INFO → CAPSET → CTX_CREATE →
/// CTX_ATTACH_RESOURCE → SUBMIT_3D(execbuf) → TRANSFER_FROM_HOST_3D →
/// RESOURCE_FLUSH, terminated by a `req_len == 0` sentinel. Each record is
/// length-prefixed (`[req_len][resp_len][flags][req]`) so `VioVirgl` is a
/// compact copy-and-submit loop rather than ~200 per-dword `sw` ops. The
/// geometry is the codegen `proxy` scanout (w×h) — the same nominal mode the
/// 2D lane uses; runtime `DispSel` divergence is a documented bring-up bound.
pub fn reqtab(w: u32, h: u32) -> Vec<u8> {
    let capset_bytes = CAPSET_WORDS.len() as u32 * 4;
    let mut out = Vec::new();
    // GET_CAPSET_INFO — body{capset_index=0, pad}.
    let mut r = ctrl_hdr(VIO_GPU_GET_CAPSET_INFO, 0);
    r.extend_from_slice(&0u32.to_le_bytes());
    r.extend_from_slice(&0u32.to_le_bytes());
    push_rec(&mut out, &r, 40, 0);
    // GET_CAPSET — body{capset_id=VIRGL, capset_version=0}; resp = hdr + blob.
    let mut r = ctrl_hdr(VIO_GPU_GET_CAPSET, 0);
    r.extend_from_slice(&crate::encode::VIO_GPU_CAPSET_VIRGL.to_le_bytes());
    r.extend_from_slice(&0u32.to_le_bytes());
    push_rec(&mut out, &r, 24 + capset_bytes, 0);
    // CTX_CREATE — body{nlen, context_init, debug_name[64]="main"}.
    let mut r = ctrl_hdr(VIO_GPU_CTX_CREATE, CTX_ID);
    r.extend_from_slice(&4u32.to_le_bytes());
    r.extend_from_slice(&0u32.to_le_bytes());
    let mut name = [0u8; 64];
    name[..4].copy_from_slice(b"main");
    r.extend_from_slice(&name);
    push_rec(&mut out, &r, 24, 0);
    // RESOURCE_CREATE_3D — `virtio_gpu_resource_create_3d`:
    // {resource_id, format, target, bind, w, h, depth, array_size,
    //  last_level, nr_samples, size, padding} (body 48B → req 72B). RES_RT is
    // the offscreen render target the execbuffer's surface object binds.
    let mut r = ctrl_hdr(VIO_GPU_RESOURCE_CREATE_3D, CTX_ID);
    for v in [
        RES_RT,                  // resource_id
        VIRGL_FMT_B8G8R8X8,      // format
        2,                       // target = PIPE_TEXTURE_2D
        PIPE_BIND_RENDER_TARGET, // bind
        w,
        h,
        1, // depth
        1, // array_size
        0, // last_level
        0, // nr_samples
        0, // size (host picks)
        0, // padding
    ] {
        r.extend_from_slice(&v.to_le_bytes());
    }
    push_rec(&mut out, &r, 24, 0);
    // CTX_ATTACH_RESOURCE — body{resource_id=RES_RT, pad}.
    let mut r = ctrl_hdr(VIO_GPU_CTX_ATTACH_RESOURCE, CTX_ID);
    r.extend_from_slice(&RES_RT.to_le_bytes());
    r.extend_from_slice(&0u32.to_le_bytes());
    push_rec(&mut out, &r, 24, 0);
    // SUBMIT_3D — body{size=execbuf bytes, num_in_fences=0}; REQFLAG_BUF.
    let mut r = ctrl_hdr(VIO_GPU_SUBMIT_3D, CTX_ID);
    let eb = execbuf(w, h).len() as u32;
    r.extend_from_slice(&eb.to_le_bytes());
    r.extend_from_slice(&0u32.to_le_bytes());
    push_rec(&mut out, &r, 24, REQFLAG_BUF);
    // Sentinel — `req_len == 0` ends the loop. (TRANSFER_FROM_HOST_3D +
    // RESOURCE_FLUSH are the guest-readback/present step — the offscreen RT
    // is verified via the device-side `virgl_fb` surface; wiring a
    // `__virgl_out` guest backing is the bounded follow-up.)
    out.extend_from_slice(&0u32.to_le_bytes());
    out
}
