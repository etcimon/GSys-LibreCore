# Graphics lane — structure and current state

**Domain:** graphics uncore · **Status:** the ceiling is read back, the scene header and the 960-byte execbuffer are fetched, the DRAW_VBO at byte 908 is recognized, its 24 NDC floats are an inline write of resource 3, the vertex buffer is stride 24, the fragment sampler view at byte 632 names handle 5, the sampler state at byte 616 names handle 6, the vertex elements at byte 608 name handle 4, the fragment shader at byte 596 names handle 3, the vertex shader at byte 584 names handle 2, the rasterizer bind at byte 576 names handle 9, the depth-stencil bind at byte 568 names handle 8, the blend bind at byte 560 names handle 7, the rasterizer object at byte 520 names handle 9, the depth-stencil object at byte 496 names handle 8, the blend object at byte 448 names handle 7 and color word 32'h78020010, the sampler-state object at byte 408 names handle 6, the sampler view at byte 380 names handle 5, the vertex-element object at byte 340 names handle 4, the fragment-shader object at byte 176 names handle 3, the vertex-shader object at byte 24 names handle 2, the surface object at byte 0 names handle 1, guest descriptors at 64'h8800E100 link the header, the 960-byte execbuffer, and the 24-byte response, avail index 1 at 64'h8800E200 names descriptor 0, the completed-opcode list at 64'h8800E300 is count 0 and capset id 0, the virgl capset stays refused, a 64 by 64 guest window at 64'h88020000 is 512 beats of clear word 32'hFF1A0D0D, the guest response at 64'h8800A800 is OK_NODATA with fence 64'h1122334455667788, the used element at 64'h8800E400 is descriptor 0 and length 24, the used index at 64'h8800E480 is 1, the used-buffer interrupt reason at 64'h8800E500 is 32'h1 and ack lowers the pin, the guest ack at 64'h8800E510 is 32'h1 and the status word at 64'h8800E500 is then 32'h0, all 512 beats of the window are that clear word and are copied to 64'h88030000 as a 64 by 64 rectangle of 16384 bytes, with `(1,0)` at byte 4 and row 1 at byte 256, the clear word in memory is the bytes 0D 0D 1A FF so byte 0 is red, row 1 at 64'h88030100 starts with that red byte, (1,1) is byte 260, (2,3) is byte 776, and (0,63) is byte 16128, (63,0) is byte 252 at 64'h880300E0, (7,0) is byte 28, (8,0) is byte 32 and (15,0) is byte 60 in 64'h88030020, (56,0) is byte 224 lane 0 of 64'h880300E0 and (63,0) stays byte 252 lane 7 of that beat, (16,0) is byte 64 and (23,0) is byte 92 in 64'h88030040, (24,0) is byte 96 and (31,0) is byte 124 in 64'h88030060, (32,0) is byte 128 and (39,0) is byte 156 in 64'h88030080, (40,0) is byte 160 and (47,0) is byte 188 in 64'h880300A0, (48,0) is byte 192 and (55,0) is byte 220 in 64'h880300C0, (63,63) is byte 16380, the viewport and scissor are the 640 by 480 rectangle, the clear color is 32'hFF1A0D0D, and one color buffer names surface 1; no blend is applied; no texture is bound; avail still rejects NEXT; screenshot gate open
**Scaffold only** (`architecture/README.md`). This page is the map. Leaf counts live in
`apu-resident-fw.md` and `AGENTS-todo.md`. Gates A0–A7 are the API-neutral plan
`plan-5ddc97674e5bf9b0.md`. The frozen scene is `g6lc_bios/architecture/DISPLAY.md`.

Reviewed APU commit `d74010111` (“APU: default-off compositor exec, resident TGSI, P3 DMEM tile”)
is an ancestor of local master. It contains the SoC box below. The virtio command units,
the coverage/fragment/resource-surface units, their private flists, and `corev_apu/hdmi/`
are untracked working-tree files. They are not in that commit.

## 1. Intent

The device is API-neutral. Linux keeps virtio-gpu. Mesa keeps virgl. The BIOS is a second
client of the same device. EGL and GLESv2 stay in those clients, outside RTL and outside
`software/apu-fw`. The contract is virtio-gpu commands in and completed surface bytes out.

The picture the plan is aimed at is one headless readback of the reduced `gles2-min` scene:
`glReadPixels` of a 64×64 RGBA8 rectangle, saved as raw bytes and a PPM, with firmware,
program, driver, RTL, and config identity recorded in `DISPLAY.md` section 7. Those bytes
have to be produced by this device. A QEMU `virtio-gpu` or llvmpipe image of the same scene
is the reference. Gate A5 is the first time that readback counts, and A5 requires A2, A3,
and A4 together. A PPM of the current lab surface is a picture of that leaf.

The lane does not reopen the A1 substrate, HDMI qualification, the BIOS P0–P12 sequence, or
OpenWrt, and it does not add a second scene. `ai_island` (window `0x40000000`, PLIC source 8,
`AiCfg.MatrixEn`) is a different coprocessor. Graphics does not use that aperture, its
doorbell, or its INT8 tiles.

## 2. Where the code lives

| Layer | Path | What it is |
|---|---|---|
| SoC box | `corev_apu/apu/g6lc_apu_{attach,soc,sys,grant,axi_lite,top,virtio_mmio,control,sched,mbox,mem,queue,exec,exec_bind,fwram,xbar,th,th_load}.sv` | Tracked device. `Flist.apu_soc`. Default `ApuOff`. |
| Config | `corev_apu/include/g6lc_apu_cfg_pkg.sv` | `apu_cfg_t`. Graphics bits default to 0. `FeatureVirgl` is outside `APU_IMPL_FEATURES`. |
| Command and surface units | `corev_apu/apu/g6lc_apu_vgpu_*.sv`, `g6lc_apu_cover.sv`, `g6lc_apu_frag.sv`, `g6lc_apu_rsurf.sv` | Untracked. One private `Flist.apu_*` and `verif/tb/apu/` suite each, through the rasterizer bind. |
| Types | `corev_apu/apu/include/g6lc_apu_pkg.sv` | Virtio and virgl ids, record types, image ceiling. |
| Firmware | `software/apu-fw` | Hart-1 mailbox images and one TGSI subset compiler. |
| Scene and encoder | `g6lc_bios/architecture/DISPLAY.md`, `g6lc_bios/crates/g6b-asm/src/{encode,virgl}.rs` | Frozen P0 profile and the execbuffer the decoders match. |
| Guest probe | `g6lc_qemu/openwrt/patches/files/package/g6lc-egl-probe/src/g6lc_egl_probe.c` | The 64×64 readback the screenshot uses. |
| HDMI | `corev_apu/hdmi/`, outline `hdmi-display.md` | Separate scanout. Untracked RTL. |
| This tree | `architecture/uncore/apu-*.md` | One outline per substrate seam. This file is the lane map. |

`g6lc_apu_attach` is the SoC window and PLIC splice. Virtio `RESOURCE_ATTACH_BACKING` is the
private unit `g6lc_apu_vgpu_back`. `g6lc_apu_queue`, inside `g6lc_apu_mem`, is the older DMA
used ring and still takes a raw map. The private used-ring units are `g6lc_apu_vgpu_used`,
`g6lc_apu_vgpu_uwr`, and `g6lc_apu_vgpu_uidx`.

## 3. SoC box versus private fixtures

```text
Linux Mesa / BIOS virtio client
        │  EGL and GLESv2 stay here
        ▼
guest gpu@0x40001000 / 4 KiB, PLIC 9          control 0x40002000 / 4 KiB
        │                                      firmware RAM 0x90000000 / 256 KiB
        ▼
g6lc_apu_attach
  g6lc_apu_soc                         default ApuCfg = ApuOff
    g6lc_apu_grant                     testharness passes ApuHarness
    g6lc_apu_sys
      g6lc_apu_axi_lite
        g6lc_apu_top
          g6lc_apu_virtio_mmio         transport registers
        g6lc_apu_control
      g6lc_apu_sched                   one mailbox op to memory or to exec
        g6lc_apu_mem                   storage, DMA, g6lc_apu_queue
        g6lc_apu_exec_bind
          g6lc_apu_exec                one FPnew lane, local DMEM
```

`Flist.apu_soc` is the attach list (grant, sys, exec, firmware RAM, the load compositor).
The file header says it is not on the production testharness flist. `+define+G6LC_APU` is the
diagnostic testharness composition. Module defaults are `ApuOff`. `ariane_testharness.sv`
passes `ApuHarness` into `g6lc_apu_th_load`. Both configs leave `ExecEn` and every graphics
enable at 0. The command units are not instantiated on that path, so a Linux guest there
has no MMIO path into them.

Those units are elaborated only by their own testbenches. Each proven unit has a default-off
bit on `apu_cfg_t`, a private flist, `verif/tb/apu/tb_g6lc_apu_*.sv`, and `run-apu-*.sh`.
`Enable=0` keeps the fixture at ports and no cells. `apu_cfg_legal` does not treat the bits
as `FeatureVirgl`. Turning a bit on does not publish the virgl feature and does not add the
file to `Flist.apu_soc`.

Two virtio paths exist side by side:

| Path | What it accepts | What it refuses |
|---|---|---|
| `g6lc_apu_vgpu_avail` | One local avail slot whose descriptor is a 40-byte `RESOURCE_CREATE_2D` | `NEXT`, `WRITE`, `INDIRECT`. It does not read guest memory. |
| `g6lc_apu_vgpu_chn` | The scene chain only. Descriptor 0 links to 1 (header at `64'h8800A000`), 1 links to 2 (960 bytes at `64'h8800B000`), 2 is the 24-byte write at `64'h8800A800`. The avail index may advance by one. | `INDIRECT`, a jumped index, a short execbuffer. Does not read guest memory. |
| `g6lc_apu_vgpu_sub` | One `SUBMIT_3D` chain of descriptors 0, 1, and 2. Descriptor 0 is a 32-byte header read from `64'h8800A000`. Length 960 is accepted. Ceiling is 1024. | `INDIRECT`, a broken link, a second submit. Descriptor 1 is named and not read here. The response address is recorded; `g6lc_apu_vgpu_rsp` writes the 24 bytes. |
| `g6lc_apu_vgpu_cmd` | `RESOURCE_CREATE_2D` for `R8G8B8A8_UNORM`, including 64×64. Fence id is echoed. | `SUBMIT_3D` returns `INVALID_PARAMETER` and creates no resource. |

`g6lc_apu_vgpu_buf` is the unit that reads the execbuffer named by the recorded submit,
32 bytes per beat, into a 1024-byte memory. A 960-byte buffer is 30 beats at `64'h8800B000`.

## 4. Integration seam

| Window | Address | Owner |
|---|---|---|
| Guest virtio-mmio | `0x40001000` / 4 KiB, PLIC source 9 | `g6lc_apu_attach`. Default DTB status disabled. |
| Control mailbox | `0x40002000` / 4 KiB | Firmware hart only. AXI id and PROT are not a grant. |
| Firmware RAM | `0x90000000` / 256 KiB | Same hart. Sign-extended aliases are outside the window. |
| AI island | `0x40000000`, PLIC source 8 | `AiCfg.MatrixEn`. Not a graphics window. |
| HDMI framebuffer | `0x8ef00000`, 640×480 `r5g6b5`, stride 1280 | `g6lc-simplefb.dtsi`. No board DTS includes it. `HdmiEn` is independent of `ApuOff`. |

Testbench guest addresses (`64'h88001000` and the `64'h8800A000`–`64'h8800C000` block) are
stand-ins inside the virtio suites. They are not the HDMI framebuffer and not a DRAM map
the SoC publishes.

The exec cluster is one FPnew FP32/integer lane over four lockstep invocation contexts,
local DMEM, and `LDC`. Exec `LD`/`ST` stays in that DMEM. Enabled configs name 4 threads,
8 registers, 16 IMEM words, and 64 DMEM words. Host and CVA6 call one compiler,
`g6lc_apu_tgsi_compile`. `TEX` returns `-26` on both. `IN`, `OUT`, and `CONST` still share
register numbers. The compiler is not linked into the pre-encoded mini-hart image, and TGSI
text is not merged into `apu_fw`. Cookies `0x600D000A` and `0x600D000B` show hart fetch of
those images. They are not a virtqueue and not a readback.

## 5. Config gating

Shipped literals `ApuOff`, `ApuP1Transport`, `ApuHarness`, `ApuSchedBoth`, and
`ApuBadVirglGrant` keep every graphics enable at 0. `ApuHarness.ExecEn` stays 0.
`FeatureVirgl` sets desired feature bit 0, which is outside `APU_IMPL_FEATURES`, so an
enabled config that asks for it is illegal. The implemented feature mask is virtio
`VERSION_1` and `RING_RESET`.

Each graphics unit adds one trailing `apu_cfg_t` field. Adding a field means writing it
on all five literals. The bits do not change `apu_cfg_legal` and do not make virgl legal.
`HdmiEn` is a separate knob and does not follow `ApuOff`, `ExecEn`, or `MatrixEn`.

`NrHarts` stays 1 in the internal package. The firmware hart is a second physical core.
The lane does not edit `build-opensbi-smt2.sh`.

## 6. Proven prefix and the rest of the stream

The frozen execbuffer is a sequence of virgl commands. Header dword is
`cmd[7:0] | object<<8 | body_dwords<<16`. Length is body dwords, excluding the header.
Each proven unit reads one command at the previous unit’s `next` byte. TGSI text stays
in the buffer. A bind stores the handle. It does not change the earlier create record.

| Bytes | Command | Module | `next` | What the record is |
|---|---|---|---|---|
| 0..24 | `CREATE_OBJECT` surface, handle 1, resource 4, format `B8G8R8X8` | `g6lc_apu_vgpu_dec` | 24 | First command |
| 24..176 | `CREATE_OBJECT` shader, handle 2, stage vertex, text length 125 | `g6lc_apu_vgpu_sh` | 176 | Text at byte 48 (`VERT`) |
| 176..340 | `CREATE_OBJECT` shader, handle 3, stage fragment, text length 140 | `g6lc_apu_vgpu_fs` | 340 | Text at byte 200 (`FRAG`) |
| 340..380 | `CREATE_OBJECT` vertex elements, handle 4 | `g6lc_apu_vgpu_ve` | 380 | Position at offset 0, uv at offset 16 |
| 380..408 | `CREATE_OBJECT` sampler view, handle 5, resource 1 | `g6lc_apu_vgpu_sv` | 408 | Identity swizzle. No fetch |
| 408..448 | `CREATE_OBJECT` sampler state, handle 6 | `g6lc_apu_vgpu_ss` | 448 | Clamp-to-edge, linear, `max_lod` 32.0. No fetch |
| 448..496 | `CREATE_OBJECT` blend, handle 7, color buffer 0 `32'h78020010` | `g6lc_apu_vgpu_bl` | 496 | No draw |
| 496..520 | `CREATE_OBJECT` depth-stencil, handle 8, state words 0 | `g6lc_apu_vgpu_ds` | 520 | Depth and stencil stay off |
| 520..560 | `CREATE_OBJECT` rasterizer, handle 9, state words 0 | `g6lc_apu_vgpu_rz` | 560 | Fill both faces, cull none. No walk |
| 560..568 | `BIND_OBJECT` blend, handle 7 | `g6lc_apu_vgpu_bb` | 568 | No draw |
| 568..576 | `BIND_OBJECT` depth-stencil, handle 8 | `g6lc_apu_vgpu_db` | 576 | No depth test |
| 576..584 | `BIND_OBJECT` rasterizer, handle 9 | `g6lc_apu_vgpu_rb` | 584 | No triangle walk |
| 584..596 | `BIND_SHADER` vertex, handle 2, stage 0 | `g6lc_apu_vgpu_vsb` | 596 | Text stays in the buffer |
| 596..608 | `BIND_SHADER` fragment, handle 3, stage 1 | `g6lc_apu_vgpu_fsb` | 608 | Text stays in the buffer |
| 608..616 | `BIND_OBJECT` vertex elements, handle 4 | `g6lc_apu_vgpu_veb` | 616 | No draw |
| 616..632 | `BIND_SAMPLER_STATES`, fragment slot 0, handle 6 | `g6lc_apu_vgpu_ssb` | 632 | No texture fetch |
| 632..648 | `SET_SAMPLER_VIEWS`, fragment slot 0, handle 5 | `g6lc_apu_vgpu_svb` | 648 | No texture fetch |
| 648..792 | `RESOURCE_INLINE_WRITE`, resource 3, 96 bytes | `g6lc_apu_vgpu_iw` | 792 | Floats stay in the buffer |
| 792..808 | `SET_VERTEX_BUFFERS`, stride 24, offset 0, resource 3 | `g6lc_apu_vgpu_vb` | 808 | No vertex fetch |
| 808..824 | `SET_SCISSOR`, minimum 0, box 640 by 480 | `g6lc_apu_vgpu_sci` | 824 | No draw |
| 824..856 | `SET_VIEWPORT`, scales 320 and 240 | `g6lc_apu_vgpu_vp` | 856 | No transform |
| 856..872 | `SET_FRAMEBUFFER`, one color buffer, surface 1 | `g6lc_apu_vgpu_fbo` | 872 | No memory attach |
| 872..908 | `CLEAR`, color 0, words 0.05 / 0.05 / 0.10 / 1.0 | `g6lc_apu_vgpu_clr` | 908 | No pixel write |
| 908..960 | `DRAW_VBO`, count 4, triangle strip | `g6lc_apu_vgpu_drw` | 960 | No triangle walk |

Last proven remote result, 2026-09-23: `tb_g6lc_apu_vgpu_tail` 337 cases / 955 checks /
4733 clocks, errors=0. That one run checks the viewport, the framebuffer state, the clear,
and the draw. Each `Enable=0` fixture is 12 ports and no cells. `Enable=1` is 1,898 cells /
394 flip-flops (viewport), 1,590 / 265 (framebuffer), 2,103 / 522 (clear), and 2,224 / 555
(draw), no latches. Earlier leaf counts are in `apu-resident-fw.md`.

Byte 960 is the end of this frozen 640×480 execbuffer. The four records do not transform
a vertex, attach memory, write a pixel, or walk a triangle. The reduced readback is 64×64.
The scene pixels are a later draw on this device. `g6lc_apu_vgpu_avail` still rejects
`NEXT`, `WRITE`, and `INDIRECT`. `g6lc_apu_vgpu_chn` accepts the one scene chain beside it.

The control prefix around that submit is a separate record. `CTX_CREATE` keeps context 1
named `main`. Two `RESOURCE_CREATE_3D` records keep resource 4 at 640 by 480 and resource 3
at 96 bytes. Three `CTX_ATTACH` records keep resources 4, 3, and 1. `g6lc_apu_vgpu_rsp`
then writes 24 bytes at `64'h8800A800`: `OK_NODATA`, the fence bit, fence
`64'h1122334455667788`, and context 1. Remote 2026-09-23: `tb_g6lc_apu_vgpu_ctl` 27 cases /
88 checks / 375 clocks, errors=0. Enable=0 is ports and no cells. Enable=1 is 1,828 cells /
811 flip-flops (context), 2,239 / 748 (resources), 1,310 / 331 (attaches), and 939 / 200
(response), no latches. That write does not store a pixel.

`GET_CAPSET_INFO` index 0 and `GET_CAPSET` virgl id 1 version 1 record
`INVALID_PARAMETER`. No capset id is published and no blob is stored. `SET_SCANOUT`
keeps scanout 0 on resource 4, rectangle 0,0,640,480. A 64 by 64 rectangle records
nothing. `RESOURCE_FLUSH` keeps that same rectangle. Remote 2026-09-23:
`tb_g6lc_apu_vgpu_pre` 20 cases / 63 checks / 206 clocks, errors=0. Enable=1 is
681 cells / 265 flip-flops (info), 1,209 / 329 (capset), 1,135 / 522 (scanout), and
1,698 / 554 (flush), no latches. The scanout record is not `g6lc_hdmi_scanout`. The
flush does not present a frame.

`g6lc_apu_vgpu_chn` keeps that scene chain when the avail index advances by one onto
descriptor 0. `INDIRECT`, a jumped index, and a 32-byte execbuffer do not consume the
slot. `g6lc_apu_vgpu_cmx` links the chain to the recorded submit and the stored response.
`g6lc_apu_vgpu_sun` then stores descriptor 0, length 24, and advances a local `used.idx`
to 1 with IRQ. A cancel before that index does not publish. Remote 2026-09-23:
`tb_g6lc_apu_vgpu_chn` 26 cases / 75 checks / 115 clocks, errors=0. Enable=1 is
1,209 cells / 585 flip-flops (chain), 642 / 5 (link), and 106 / 24 (used element), no
latches. `g6lc_apu_vgpu_suw` then writes descriptor 0 and length 24 to `64'h8800D000`.
`g6lc_apu_vgpu_sux` writes `used.idx` 1 to `64'h8800E002`. Remote 2026-09-23:
`tb_g6lc_apu_vgpu_sunw` 11 cases / 56 checks / 61 clocks, errors=0. Enable=1 is
208 cells / 7 flip-flops (element) and 214 / 7 (index), no latches. Those addresses
are not `64'h8800_3000` and `64'h8800_4002`. `g6lc_apu_vgpu_avail` is unchanged.

The clear floats become RGBA8 `32'hFF1A0D0D` (byte 0 is red: 13, 13, 26, 255). After the
640 by 480 scissor, surface 1, and the four-vertex strip are recorded, that word is stored
at the four corners of the 64 by 64 ceiling: addresses 0, 252, 16128, and 16380. `(1,0)`
is not stored. `(64,0)` is outside the ceiling. Remote 2026-09-23: `tb_g6lc_apu_vgpu_pix`
16 cases / 60 checks / 71 clocks, errors=0. Enable=1 is 283 cells / 6 flip-flops (bytes),
328 / 38 (corners), and 518 / 50 (read), no latches. The interior is not written. The
triangle is not walked. This is not the screenshot.

That same word now stands for all 4096 samples of the ceiling. The samples are not stored
one by one. `(1,0)` reads address 4. `(2,3)` reads address 776. `(63,63)` reads 16380.
`(64,0)` records nothing. Remote 2026-09-23: `tb_g6lc_apu_vgpu_fil` 14 cases / 56 checks /
63 clocks, errors=0. Enable=1 is 234 cells / 38 flip-flops (fill) and 412 / 48 (read), no
latches. The corner reader still reports `(1,0)` as a miss of the four stored corners.
The triangle is not walked.

The 24 floats at bytes 696..791 match that NDC square: `{x, y, 0, 1, u, v}`
at `(-1,-1)`, `(1,-1)`, `(-1,1)`, and `(1,1)`. Viewport scales 320 and 240
map it onto 0..640 by 0..480, so every ceiling sample is covered. The stored
color stays `32'hFF1A0D0D`. The fragment shader is not run. This is not
`g6lc_apu_cover`. Remote 2026-09-23: `tb_g6lc_apu_vgpu_qd` 14 cases / 52
checks / 113 clocks, errors=0. Enable=1 is 697 cells / 22 flip-flops (quad),
255 / 70 (coverage), and 419 / 49 (sample), no latches. Enable=0 is 12, 11,
and 10 ports and no cells. `(1,0)` reads address 4 from the coverage record.
The corner reader still reports `(1,0)` as a miss of the four stored corners.

The vertex-shader text is 32 dwords at byte 48, length 125 including the NUL.
It is the VERT passthrough. The fragment-shader text is 35 dwords at byte 200,
length 140 including the NUL. It is the TEX program. A mismatched dword records
nothing. TEX is not executed, so a covered sample stays `32'hFF1A0D0D`. `(1,0)`
reads address 4. This is not `g6lc_apu_cover`. Remote 2026-09-23:
`tb_g6lc_apu_vgpu_vtx` 20 cases / 75 checks / 225 clocks, errors=0. Enable=1 is
751 cells / 12 flip-flops (vertex text), 809 / 13 (fragment text), and 423 / 49
(held sample), no latches. Enable=0 is 12, 13, and 11 ports and no cells. The
corner reader still reports `(1,0)` as a miss of the four stored corners.

That TEX program is bound to sampler view 5 on resource 1 and sampler state 6,
both on fragment slot 0. The view is `B8G8R8X8`, target 2D, identity swizzle.
The sampler is clamp-to-edge and linear, with no mip filter. Resource 1 has no
texel image on this path, so the sample is refused and the word stays
`32'hFF1A0D0D`. `(1,0)` reads address 4 with the refused bit set. This does not
fetch a texel. Remote 2026-09-23: `tb_g6lc_apu_vgpu_tbn` 15 cases / 57 checks /
67 clocks, errors=0. Enable=1 is 747 cells / 101 flip-flops (binding), 310 / 102
(refusal), and 452 / 49 (sample), no latches. Enable=0 is 14, 10, and 10 ports
and no cells. The corner reader still reports `(1,0)` as a miss of the four
stored corners.

Resource 1 is also the VioScan `RESOURCE_CREATE_2D`: format `B8G8R8X8` (2),
640 by 480. Format 67 and a 64-wide image record nothing. That is
`g6lc_apu_vgpu_cmd`, which was not re-run. The backing length is 1,228,800
bytes. The test address `32'h8800F000` is a stand-in, not `__scan_fb`, and not
`32'h88001000`. The transfer rectangle is the top band, 0,0,640 by 64. A
480-high rectangle records nothing. This band is not the 64 by 64 ceiling. No
byte is copied, so the refused word stays `32'hFF1A0D0D`. Remote 2026-09-23:
`tb_g6lc_apu_vgpu_s2d` 15 cases / 54 checks / 169 clocks, errors=0. Enable=1 is
245 cells / 11 flip-flops (create), 504 / 75 (backing), and 542 / 43 (transfer),
no latches. Enable=0 is 11, 12, and 14 ports and no cells.

`SET_SCANOUT` then names scanout 0 on resource 1 at 640 by 480. A 64 by 64
rectangle and resource 4 record nothing. `RESOURCE_FLUSH` of resource 1 keeps
the top band, 640 by 64. A 480-high flush records nothing. Neither record
presents a frame. This is not `g6lc_apu_vgpu_scn`, not `g6lc_apu_vgpu_flu`, and
not `g6lc_hdmi_scanout`. `(1,0)` still reads address 4 as `32'hFF1A0D0D`. Remote
2026-09-23: `tb_g6lc_apu_vgpu_ssc` 17 cases / 61 checks / 153 clocks, errors=0.
Enable=1 is 349 cells / 11 flip-flops (scanout), 432 / 11 (flush), and 486 / 48
(sample), no latches. Enable=0 is 12, 13, and 11 ports and no cells.

The top band is then read from the backing address. 640 by 64 is 163,840 bytes,
5,120 beats of 32. The image is not stored. Beat 0's low word is kept. The other
1,064,960 bytes of the 1,228,800-byte backing are not read. The ceiling word stays
`32'hFF1A0D0D`. TEX is not executed. Remote 2026-09-23: `tb_g6lc_apu_vgpu_bcp`
10 cases / 41 checks / 10,297 clocks, errors=0. Enable=1 is 802 cells / 118
flip-flops (copy) and 458 / 81 (report), no latches. Enable=0 is 20 and 9 ports
and no cells.

`(0,0)` of that band is then sampled. Clamp-to-edge linear at that corner uses
the one texel. `x` clamps to 639. `y` above 63 records nothing. A second tap is
not blended. Ceiling pixel `(0,0)` becomes that word, `32'hA5000000` in the
test. `(1,0)` and `(63,63)` stay `32'hFF1A0D0D`. The fill reader still returns
the clear word at `(0,0)`. TEX is not executed. Remote 2026-09-23:
`tb_g6lc_apu_vgpu_tap` 13 cases / 51 checks / 68 clocks, errors=0. Enable=1 is
1,471 cells / 105 flip-flops (texel), 189 / 37 (corner), and 355 / 49 (read),
no latches. Enable=0 is 24, 10, and 10 ports and no cells.

Row 0 then blends two taps in the first beat. `s = x - 1/2` with `u = x/640`.
`x = 0` stays `32'hA5000000`. `x = 1` is `32'hD2008000`, the half blend of texel
0 and texel 1, round half up per byte. `x = 7` is `32'h33445566`. `x` above 7
and `y` other than 0 record nothing. The earlier ceiling reader still returns
the clear word at `(1,0)`. TEX is not executed. Remote 2026-09-23:
`tb_g6lc_apu_vgpu_lin` 11 cases / 41 checks / 63 clocks, errors=0. Enable=1 is
2,000 cells / 84 flip-flops (blend) and 247 / 71 (pair), no latches. Enable=0
is 25 and 11 ports and no cells.

`x = 8` reads both beats. Texel 7 is `32'h55667788` and texel 8 is
`32'hAABBCCDD`. The half blend is `32'h8091A2B3`. `x = 0` stays `32'hA5000000`
and `x = 1` stays `32'hD2008000`. `x` above 15 records nothing. TEX is not
executed. Remote 2026-09-23: `tb_g6lc_apu_vgpu_spn` 11 cases / 39 checks / 68
clocks, errors=0. Enable=1 is 2,422 cells / 156 flip-flops (span) and 130 / 37
(store), no latches. Enable=0 is 25 and 10 ports and no cells.

`y = 1` mixes that row with row 1. `t = y - 1/2`, so the sample is halfway
between texel row 0 and texel row 1. `x = 0` is `32'h53010202`. `x = 1` is
`32'h6B024303`. The row-1 beat is `64'h8800FA00`. `y = 0`, `y` above 1, and
`x` above 1 record nothing. Row 0 stays `32'hA5000000` at `x = 0` and
`32'hD2008000` at `x = 1`. TEX is not executed. This is not a bilinear of the
ceiling and it is not the screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_vln`
11 cases / 41 checks / 60 clocks, errors=0. Enable=1 is 1,517 cells / 77
flip-flops (blend) and 237 / 71 (pair), no latches. Enable=0 is 26 and 10
ports and no cells.

`y = 1` then blends `x = 0..7`. Both taps of each row sit in beat 0. `x = 0`
stays `32'h53010202` and `x = 1` stays `32'h6B024303`. `x = 2` is
`32'h42024203`. `x = 7` is `32'h1A222B33`. `x` above 7 records nothing. The
image is not stored. TEX is not executed. This is not a bilinear of the
ceiling and it is not the screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_vbx`
12 cases / 53 checks / 78 clocks, errors=0. Enable=1 is 3,891 cells / 336
flip-flops (blend) and 129 / 37 (store), no latches. Enable=0 is 27 and 10
ports and no cells.

`y = 1` then blends through `x = 15`. `x = 8` reads beat 0 and beat 1 of
each row. Row 0 stays `32'h8091A2B3`. Row 1 texel 8 is `32'h0A0B0C0D`. The
vertical blend is `32'h434C545D`. `x = 0`, `x = 1`, and `x = 2` stay the
stored words. `x = 15` is `32'h0`. `x` above 15 records nothing. The image
is not stored. TEX is not executed. This is not a bilinear of the ceiling
and it is not the screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_vsp`
13 cases / 63 checks / 91 clocks, errors=0. Enable=1 is 3,388 cells / 185
flip-flops (blend) and 199 / 37 (store), no latches. Enable=0 is 28 and 12
ports and no cells.

`y = 2` mixes row 1 with row 2 for `x = 0..7`. `t = y - 1/2`. `x = 0` is
`32'h79797A7A`. `x = 1` is `32'h42424343`. `x = 7` is `32'h3C3C3C3C`. Row 2
is `64'h88010400`. `y = 1` and `x` above 7 record nothing. The `y = 1`
samples stay `32'h53010202` and `32'h6B024303`. The image is not stored.
TEX is not executed. This is not a bilinear of the ceiling and it is not
the screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_y2b` 12 cases / 55
checks / 73 clocks, errors=0. Enable=1 is 3,300 cells / 116 flip-flops
(blend) and 241 / 71 (pair), no latches. Enable=0 is 29 and 11 ports and
no cells.

Any point of the 64 by 64 ceiling can then be sampled from that band.
`x = 0` clamps to texel 0 and `y = 0` clamps to row 0. The stored colors
match. `(9,0)` is `32'h555E666F`. `(8,2)` is `32'h17171718`. `(0,3)` is
`32'h78787878` and is kept. `(63,63)` is `32'h0`. `x` or `y` above 63
records nothing. The image is not stored. One run checked all 4,096
points. TEX is not executed. This is not the screenshot. Remote
2026-09-23: `tb_g6lc_apu_vgpu_smp` 4,117 cases / 16,472 checks / 38,678
clocks, errors=0. Enable=1 is 4,351 cells / 221 flip-flops (sample) and
204 / 37 (store), no latches. Enable=0 is 30 and 10 ports and no cells.

That ceiling is then written to `32'h88040000`. Eight samples fill one
beat. The walk is 512 beats, 16,384 bytes, and the last beat is at
`64'h88043FE0`. Beat 0 is row 0 through `x = 7`. Beat 24 starts with
`32'h78787878`. The last beat is `32'h0`. The writer keeps the beat it
is sending, not the image. A failed sample writes nothing. This is not
`32'h8800C000`. TEX is not executed. This is not the screenshot. Remote
2026-09-23: `tb_g6lc_apu_vgpu_rbf` 7 cases / 35 checks / 39,646 clocks,
errors=0. Enable=1 is 5,129 cells / 620 flip-flops (write, including
the sampler) and 318 / 111 (record), no latches. Enable=0 is 37 and 10
ports and no cells.

Those 512 beats are then read back. Beat 0's low word is `32'hA5000000`.
Beat 24's low word is `32'h78787878`. The last beat is at `64'h88043FE0`.
The image is not kept. A failed beat stops the walk. A word that does not
match the record is refused. TEX is not executed. This is not the
screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_rdr` 7 cases / 30 checks /
1,066 clocks, errors=0. Enable=1 is 909 cells / 147 flip-flops (read) and
298 / 69 (pair), no latches. Enable=0 is 20 and 11 ports and no cells.

The accepted scene chain is then fetched from guest memory. The header
at `64'h8800A000` is `SUBMIT_3D`, context 1, size 960. The execbuffer is
30 beats at `64'h8800B000`. The first word is `32'h00050801`, the surface
`CREATE_OBJECT`. The last beat is at `64'h8800B3A0`. The 960 bytes are
not kept. The response at `64'h8800A800` is not read. `g6lc_apu_vgpu_avail`
still rejects `NEXT`. TEX is not executed. This is not the screenshot.
Remote 2026-09-23: `tb_g6lc_apu_vgpu_fet` 8 cases / 33 checks / 113 clocks,
errors=0. Enable=1 is 834 cells / 81 flip-flops (fetch) and 210 / 69
(record), no latches. Enable=0 is 19 and 10 ports and no cells.

The `DRAW_VBO` at byte 908 of that execbuffer is then read. Beat 28 at
`64'h8800B380` carries the header in bits `[127:96]`, `32'h000C0008`.
Count is 4 and the primitive is a triangle strip. Beat 29 at
`64'h8800B3A0` carries one instance and max index 3. The low twelve
bytes of beat 28 are the clear tail and are not checked. The 960 bytes
are not kept. The draw is not executed. This is not `g6lc_apu_vgpu_drw`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed. This
is not the screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_drd` 13
cases / 59 checks / 81 clocks, errors=0. Enable=1 is 839 cells / 139
flip-flops (read) and 241 / 69 (record), no latches. Enable=0 is 19
and 10 ports and no cells.

The 24 NDC floats that draw names are then read from byte 696. Beat 21
at `64'h8800B2A0` holds the inline-write length and the first two
floats. Beats 22 and 23 hold the middle sixteen. Beat 24 at
`64'h8800B300` holds the last six. The corners are `(-1,-1)`, `(1,-1)`,
`(-1,1)`, and `(1,1)`. The first float is `32'hbf800000` and the last
is `32'h3f800000`. The 96 bytes are not kept. The vertex-buffer command
after the floats is not part of this read. This does not transform a
vertex and does not execute the draw. This is not `g6lc_apu_vgpu_qd`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed. This
is not the screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_qdr` 14
cases / 63 checks / 97 clocks, errors=0. Enable=1 is 1,109 cells / 143
flip-flops (read) and 387 / 69 (record), no latches. Enable=0 is 20
and 11 ports and no cells.

The viewport of that draw is then read from byte 824. Beat 25 at
`64'h8800B320` carries the header `32'h00070004`. Beat 26 at
`64'h8800B340` carries scale 320 and scale 240. NDC −1 lands at 0 and
NDC +1 lands at 640 and 480. This is not a floating-point multiply and
not a rasterizer. The scissor in the low 24 bytes of beat 25 is not
part of this command. This is not `g6lc_apu_vgpu_vp`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed. This
is not the screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_vwx` 13
cases / 59 checks / 80 clocks, errors=0. Enable=1 is 1,000 cells / 140
flip-flops (read) and 566 / 133 (record), no latches. Enable=0 is 21
and 12 ports and no cells.

The scissor of that draw is then read from byte 808. It shares beat 25
at `64'h8800B320` with the viewport. The header is `32'h0003000F`. The
box is `32'h01E00280`, 640 by 480, the same edges as the window. No
pixel is clipped. The vertex-buffer tail and the viewport header in
that beat are not part of this command. This is not `g6lc_apu_vgpu_sci`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed. This
is not the screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_cxr` 13
cases / 59 checks / 71 clocks, errors=0. Enable=1 is 851 cells / 73
flip-flops (read) and 461 / 37 (record), no latches. Enable=0 is 22
and 13 ports and no cells.

The clear of that rectangle is then read from byte 872. Beat 27 at
`64'h8800B360` carries the header `32'h00080007` and the floats
`32'h3d4ccccd`, `32'h3d4ccccd`, `32'h3dcccccd`, and `32'h3f800000`.
Beat 28 at `64'h8800B380` carries depth `32'h3ff00000` and is also
the draw beat. The packed word is `32'hFF1A0D0D`, byte 0 red. This
does not convert a float and does not write a pixel. The framebuffer
tail and the draw header in those beats are not part of this command.
This is not `g6lc_apu_vgpu_clr`. `g6lc_apu_vgpu_avail` still rejects
`NEXT`. TEX is not executed. This is not the screenshot. Remote
2026-09-23: `tb_g6lc_apu_vgpu_cwr` 13 cases / 59 checks / 78 clocks,
errors=0. Enable=1 is 1,185 cells / 140 flip-flops (read) and 524 /
101 (record), no latches. Enable=0 is 23 and 11 ports and no cells.

The framebuffer that clear follows is then read from byte 856. Beat 26
at `64'h8800B340` carries the header `32'h00030005` and one color
buffer. Beat 27 at `64'h8800B360` carries surface handle 1. The clear
word `32'hFF1A0D0D` stays with that surface. This does not attach
memory and does not write a pixel. The viewport body and the clear in
those beats are not part of this command. This is not
`g6lc_apu_vgpu_fbo`. `g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX
is not executed. This is not the screenshot. Remote 2026-09-23:
`tb_g6lc_apu_vgpu_fbr` 13 cases / 59 checks / 78 clocks, errors=0.
Enable=1 is 1,130 cells / 171 flip-flops (read) and 452 / 101
(record), no latches. Enable=0 is 24 and 11 ports and no cells.

The vertex-buffer set that follows the floats is then read from byte
792. Beat 24 at `64'h8800B300` carries the header `32'h00030006` and
stride 24. Beat 25 at `64'h8800B320` carries offset 0 and resource 3.
This does not fetch vertices. The last quad float and the scissor in
those beats are not part of this command. This is not
`g6lc_apu_vgpu_vb`. `g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX
is not executed. This is not the screenshot. Remote 2026-09-23:
`tb_g6lc_apu_vgpu_vbf` 14 cases / 63 checks / 87 clocks, errors=0.
Enable=1 is 1,246 cells / 203 flip-flops (read) and 452 / 101
(record), no latches. Enable=0 is 25 and 11 ports and no cells.

The inline write that holds those floats is then read from byte 648.
Beat 20 at `64'h8800B280` carries the header `32'h00230009` and
resource 3. Beat 21 at `64'h8800B2A0` carries the length 96 and the
first float. The 96 bytes are not kept. This does not fetch vertices.
The sampler-view handle and the second float in those beats are not
part of this check. This is not `g6lc_apu_vgpu_iw`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed. This
is not the screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_iwr` 13
cases / 59 checks / 78 clocks, errors=0. Enable=1 is 1,405 cells /
139 flip-flops (read) and 449 / 69 (record), no latches. Enable=0 is
26 and 12 ports and no cells.

The sampler view that precedes that write is then read from byte 632.
Beat 19 at `64'h8800B260` carries the header `32'h0003000A` and the
fragment stage. Beat 20 at `64'h8800B280` carries slot 0 and
sampler-view handle 5. No texture is bound. The sampler-state handle
and the inline-write header in those beats are not part of this
command. This is not `g6lc_apu_vgpu_svb`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed. This
is not the screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_svr` 15
cases / 67 checks / 91 clocks, errors=0. Enable=1 is 1,644 cells /
204 flip-flops (read) and 612 / 101 (record), no latches. Enable=0 is
27 and 12 ports and no cells.

The sampler state that precedes that view is then read from byte 616.
It shares beat 19 at `64'h8800B260`. The header is `32'h00030012`.
The stage is fragment, the slot is 0, and the handle is 6. No
texture is bound. The vertex-element bind and the sampler-view
header in that beat are not part of this command. This is not
`g6lc_apu_vgpu_ssb`. `g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX
is not executed. This is not the screenshot. Remote 2026-09-23:
`tb_g6lc_apu_vgpu_ssr` 15 cases / 67 checks / 85 clocks, errors=0.
Enable=1 is 1,926 cells / 201 flip-flops (read) and 778 / 101
(record), no latches. Enable=0 is 28 and 13 ports and no cells.

The vertex-element bind that precedes that state is then read from
byte 608. It is the first eight bytes of beat 19 at `64'h8800B260`.
The header is `32'h00010502` and the handle is 4. No vertices are
fetched. The sampler-state words in that beat are not part of this
command. This is not `g6lc_apu_vgpu_veb`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed. This
is not the screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_ver` 13
cases / 59 checks / 71 clocks, errors=0. Enable=1 is 1,965 cells /
137 flip-flops (read) and 651 / 69 (record), no latches. Enable=0 is
29 and 13 ports and no cells.

The fragment shader bind that precedes those elements is then read
from byte 596. It is the last twelve bytes of beat 18 at
`64'h8800B240`. The header is `32'h0002001F`, the handle is 3, and
the stage is fragment. The shader is not run. The vertex-shader
words in that beat are not part of this command. This is not
`g6lc_apu_vgpu_fsb`. `g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX
is not executed. This is not the screenshot. Remote 2026-09-23:
`tb_g6lc_apu_vgpu_fsr` 14 cases / 63 checks / 78 clocks, errors=0.
Enable=1 is 2,141 cells / 137 flip-flops (read) and 691 / 69
(record), no latches. Enable=0 is 30 and 13 ports and no cells.

The vertex shader bind that precedes that fragment bind is then read
from byte 584. It shares beat 18 at `64'h8800B240`. The header is
`32'h0002001F`, the handle is 2, and the stage is vertex. The shader
is not run. The fragment-shader words in that beat are not part of
this command. This is not `g6lc_apu_vgpu_vsb`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed. This
is not the screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_vsr` 14
cases / 63 checks / 78 clocks, errors=0. Enable=1 is 2,401 cells /
137 flip-flops (read) and 745 / 69 (record), no latches. Enable=0 is
31 and 13 ports and no cells.

The rasterizer bind that precedes that vertex shader is then read
from byte 576. It is the first eight bytes of beat 18 at
`64'h8800B240`. The header is `32'h00010202` and the handle is 9.
No triangle is walked. The vertex-shader words in that beat are not
part of this command. This is not `g6lc_apu_vgpu_rb`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed. This
is not the screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_rzr` 13
cases / 59 checks / 71 clocks, errors=0. Enable=1 is 2,568 cells /
137 flip-flops (read) and 682 / 69 (record), no latches. Enable=0 is
32 and 13 ports and no cells.

The depth-stencil bind that precedes that rasterizer is then read
from byte 568. It is the last eight bytes of beat 17 at
`64'h8800B220`. The header is `32'h00010302` and the handle is 8.
No depth test is run. The blend bind in that beat is not part of
this command. This is not `g6lc_apu_vgpu_db`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed. This
is not the screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_dbr` 13
cases / 59 checks / 71 clocks, errors=0. Enable=1 is 2,769 cells /
137 flip-flops (read) and 686 / 69 (record), no latches. Enable=0 is
33 and 13 ports and no cells.

The blend bind that precedes that depth-stencil bind is then read
from byte 560. It is sixteen bytes into beat 17 at `64'h8800B220`.
The header is `32'h00010102` and the handle is 7. No blend is
applied. The depth-stencil words in that beat are not part of this
command. This is not `g6lc_apu_vgpu_bb`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed. This
is not the screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_bbr` 13
cases / 59 checks / 71 clocks, errors=0. Enable=1 is 2,972 cells /
137 flip-flops (read) and 687 / 69 (record), no latches. Enable=0 is
34 and 13 ports and no cells.

The rasterizer object that precedes that blend bind is then read from
byte 520. Beat 16 at `64'h8800B200` carries the header `32'h00090201`
and handle 9. Beat 17 at `64'h8800B220` carries the last four state
words. All eight state words are 0. They are not kept. No triangle is
walked. The depth-stencil tail in beat 16 and the blend bind in beat
17 are not part of this command. This is not `g6lc_apu_vgpu_rz`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed. This
is not the screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_rcr` 15
cases / 67 checks / 89 clocks, errors=0. Enable=1 is 3,536 cells /
139 flip-flops (read) and 700 / 69 (record), no latches. Enable=0 is
35 and 13 ports and no cells.

The depth-stencil object that precedes that rasterizer is then read
from byte 496. Beat 15 at `64'h8800B1E0` carries the header
`32'h00050301` and handle 8. Beat 16 at `64'h8800B200` carries the
last two state words. All four state words are 0. They are not kept.
No depth test is run. The blend tail in beat 15 and the rasterizer
object in beat 16 are not part of this command. This is not
`g6lc_apu_vgpu_ds`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed. This
is not the screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_dcr` 15
cases / 67 checks / 89 clocks, errors=0. Enable=1 is 3,734 cells /
140 flip-flops (read) and 700 / 69 (record), no latches. Enable=0 is
36 and 13 ports and no cells.

The blend object that precedes that depth-stencil object is then read
from byte 448. Beat 14 at `64'h8800B1C0` carries the header
`32'h000B0101`, handle 7, and color word `32'h78020010`. Beat 15 at
`64'h8800B1E0` carries the last four body words, and they are 0. Those
zero words are not kept. No blend is applied. The depth-stencil object
in beat 15 is not part of this command. This is not `g6lc_apu_vgpu_bl`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed. This
is not the screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_blr` 16
cases / 71 checks / 96 clocks, errors=0. Enable=1 is 4,308 cells /
203 flip-flops (read) and 838 / 101 (record), no latches. Enable=0 is
37 and 13 ports and no cells.

The sampler-state object that precedes that blend object is then read
from byte 408. Beat 12 at `64'h8800B180` carries the header
`32'h00090701` and handle 6. Beat 13 at `64'h8800B1A0` carries wrap
word `32'h00002292` and max LOD `32'h42000000`. The other body words
are 0. They are not kept. No texture is bound. The sampler-view tail
in beat 12 is not part of this command. This is not
`g6lc_apu_vgpu_ss`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed. This
is not the screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_scr` 17
cases / 75 checks / 109 clocks, errors=0. Enable=1 is 4,899 cells /
267 flip-flops (read) and 951 / 133 (record), no latches. Enable=0 is
38 and 13 ports and no cells.

The sampler view that precedes that sampler-state object is then read
from byte 380. Beat 11 at `64'h8800B160` carries the header
`32'h00060601`. Beat 12 at `64'h8800B180` carries handle 5, resource
1, format word `32'h02000002`, and swizzle `32'h00000688`. Two body
words are 0. They are not kept. No texture is bound. The
vertex-element tail in beat 11 and the sampler-state words in beat 12
are not part of this command. This is not `g6lc_apu_vgpu_sv`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed. This
is not the screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_svc` 18
cases / 79 checks / 120 clocks, errors=0. Enable=1 is 5,267 cells /
332 flip-flops (read) and 1,046 / 165 (record), no latches. Enable=0
is 39 and 13 ports and no cells.

The vertex-element object that precedes that sampler view is then
read from byte 340. Beat 10 at `64'h8800B140` carries the header
`32'h00090501`, handle 4, and offset 0. Beat 11 at `64'h8800B160`
carries format 31, offset 16, and format 29. Four divisor words are
0. They are not kept. No vertices are fetched. The shader text in
beat 10 and the sampler-view header in beat 11 are not part of this
command. This is not `g6lc_apu_vgpu_ve`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed. This
is not the screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_vec` 19
cases / 83 checks / 125 clocks, errors=0. Enable=1 is 5,868 cells /
395 flip-flops (read) and 1,135 / 197 (record), no latches. Enable=0
is 40 and 13 ports and no cells.

Fragment-shader, vertex-shader, and surface objects that head that
execbuffer are then read in one run. The fragment shader at byte 176
is header `32'h00280401`, handle 3, fragment stage, length 140, and
text dword `32'h47415246`. The vertex shader at byte 24 is header
`32'h00250401`, handle 2, vertex stage, length 125, and text dword
`32'h54524556`. The surface at byte 0 is header `32'h00050801`,
handle 1, resource 4, and format 2. The rest of each shader text
stays in the execbuffer. Neither shader is run. No framebuffer is
painted. No vertices are fetched. No texture is bound. This is not
`g6lc_apu_vgpu_fs` or `g6lc_apu_vgpu_sh`. `g6lc_apu_vgpu_avail` still
rejects `NEXT`. TEX is not executed. This is not the screenshot.
Remote 2026-09-23: `tb_g6lc_apu_vgpu_obj` 53 cases / 221 checks / 317
clocks, errors=0. Enable=1 is 6,794 cells / 396 flip-flops (fragment
read), 1,140 / 197 (fragment record), 7,311 / 395 (vertex read),
1,017 / 197 (vertex record), 6,753 / 265 (surface read), and 840 /
133 (surface record), no latches. Enable=0 is 41, 13, 42, 13, 43, and
13 ports and no cells.

The same scene is then read as three guest descriptors at
`64'h8800E100` and one avail slot at `64'h8800E200`. Descriptor 0 is
the header and links to 1. Descriptor 1 is the 960-byte execbuffer and
links to 2. Descriptor 2 is the 24-byte response. Avail index 1 names
descriptor 0. INDIRECT, a broken link, and a jumped index record
nothing. This is not `g6lc_apu_vgpu_avail` and not `g6lc_apu_vgpu_chn`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed. This
is not the screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_nxc` 16
cases / 71 checks / 109 clocks, errors=0. Enable=1 is 1,959 cells /
396 flip-flops (read) and 921 / 197 (record), no latches. Enable=0 is
22 and 13 ports and no cells.

The completed-opcode list is then read at `64'h8800E300`. The count
is 0 and the capset id is 0. A nonzero count or virgl id 1 records
nothing. No caps blob is stored. The answer is `OK_NODATA`. The virgl
capset request stays `INVALID_PARAMETER`. This is not
`g6lc_apu_vgpu_cap`. `FeatureVirgl` stays off. `g6lc_apu_vgpu_avail`
still rejects `NEXT`. TEX is not executed. This is not the screenshot.
Remote 2026-09-23: `tb_g6lc_apu_vgpu_ols` 13 cases / 59 checks / 71
clocks, errors=0. Enable=1 is 1,055 cells / 137 flip-flops (read) and
557 / 101 (record), no latches. Enable=0 is 24 and 13 ports and no cells.

The scene clear word is then written across a 64 by 64 guest window
at `64'h88020000`. Each beat is eight copies of `32'hFF1A0D0D`. 512
beats is 16384 bytes. The bytes are not kept in registers. A 64-high
scissor records nothing. The first beat and the last beat at
`64'h88023FE0` read back as that word. `(1,0)` is byte 4 of the first
beat. This is not `g6lc_apu_vgpu_rbf`, not `g6lc_apu_vgpu_frd`, and
not `g6lc_apu_vgpu_pxr`. The shader is not run. This is not the
screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not
executed. Remote 2026-09-23: `tb_g6lc_apu_vgpu_gpw` 16 cases / 73
checks / 1112 clocks, errors=0. Enable=1 is 766 cells / 18 flip-flops
(write), 1,212 / 75 (read), and 873 / 165 (record), no latches.
Enable=0 is 23, 22, and 13 ports and no cells.

The guest completion is then written. The 24-byte response at
`64'h8800A800` is `OK_NODATA`, fence `64'h1122334455667788`, and
context 1. The used element at `64'h8800E400` is descriptor 0 and
length 24. The used index at `64'h8800E480` is 1. A 64-high scissor
writes nothing. The response bytes are not kept. This is not
`g6lc_apu_vgpu_rsp`, not `g6lc_apu_vgpu_suw`, and not
`g6lc_apu_vgpu_sux`. The shader is not run. This is not the
screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not
executed. Remote 2026-09-23: `tb_g6lc_apu_vgpu_gcw` 22 cases / 96
checks / 127 clocks, errors=0. Enable=1 is 995 cells / 14 flip-flops
(write), 1,867 / 365 (read), and 1,318 / 181 (record), no latches.
Enable=0 is 22, 24, and 15 ports and no cells.

The used-buffer interrupt is then raised. The reason at
`64'h8800E500` is `32'h1`. Ack lowers the pin and leaves the record.
A cancel before the beat writes nothing and the pin stays low. A
64-high scissor writes nothing. This is not `g6lc_apu_vgpu_sun` and
not `g6lc_apu_vgpu_used`. The pin is not PLIC source 9. The shader
is not run. This is not the screenshot. `g6lc_apu_vgpu_avail` still
rejects `NEXT`. TEX is not executed. Remote 2026-09-23:
`tb_g6lc_apu_vgpu_viw` 20 cases / 89 checks / 102 clocks, errors=0.
Enable=1 is 888 cells / 24 flip-flops (write), 897 / 88 (read), and
607 / 53 (record), no latches. Enable=0 is 26, 23, and 13 ports and
no cells.

The guest then acks that reason. The word at `64'h8800E510` is
`32'h1`, and the status word at `64'h8800E500` is written as `32'h0`.
A config-only ack and a zero ack write nothing. A cancel before the
read writes nothing. This does not drive the viw pin. The shader is
not run. This is not the screenshot. `g6lc_apu_vgpu_avail` still
rejects `NEXT`. TEX is not executed. Remote 2026-09-23:
`tb_g6lc_apu_vgpu_vaw` 22 cases / 96 checks / 122 clocks, errors=0.
Enable=1 is 862 cells / 7 flip-flops (ack), 816 / 155 (read), and
709 / 85 (record), no latches. Enable=0 is 34, 22, and 13 ports and
no cells.

All 512 beats of the window at `64'h88020000` are then read. Each
beat is eight copies of `32'hFF1A0D0D`. `(0,0)` is the low word of
beat 0. `(1,0)` is byte 4 of that beat. `(63,63)` is the top lane of
the last beat. The image is not kept. A 64-high scissor reads
nothing. `x` or `y` of 64 records nothing. This is not
`g6lc_apu_vgpu_gpr`. The shader is not run. This is not the
screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not
executed. Remote 2026-09-23: `tb_g6lc_apu_vgpu_wfr` 21 cases / 86
checks / 2149 clocks, errors=0. Enable=1 is 1,660 cells / 210
flip-flops (read), 674 / 117 (record), and 299 / 51 (point), no
latches. Enable=0 is 23, 12, and 11 ports and no cells.

That window is then copied to `64'h88030000`. 512 beats are read
and written. A beat that is not the clear word stops the copy. One
beat is held between the read and the write. The image is not kept.
This is not Mesa `glReadPixels` and not the ceiling at
`32'h88040000`. The shader is not run. This is not the screenshot.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed.
Remote 2026-09-23: `tb_g6lc_apu_vgpu_gbw` 19 cases / 84 checks /
2153 clocks, errors=0. Enable=1 is 2,227 cells / 412 flip-flops
(copy), 1,080 / 75 (read), and 935 / 181 (record), no latches.
Enable=0 is 33, 20, and 12 ports and no cells.

The buffer is a 64 by 64 rectangle, stride 256, format `B8G8R8X8`,
16384 bytes. A 640 by 480 request records nothing. `(1,0)` is byte
4 of the beat at `64'h88030000`. `(63,63)` is the top lane of
`64'h88033FE0`. Both are the clear word. `x` or `y` of 64 reads
nothing. This is not Mesa `glReadPixels`. The shader is not run.
This is not the screenshot. `g6lc_apu_vgpu_avail` still rejects
`NEXT`. TEX is not executed. Remote 2026-09-23:
`tb_g6lc_apu_vgpu_gbd` 18 cases / 78 checks / 91 clocks, errors=0.
Enable=1 is 261 cells / 6 flip-flops (rectangle), 1,363 / 102
(lane), and 829 / 115 (record), no latches. Enable=0 is 11, 22, and
11 ports and no cells.

The byte offset of a point is `y * 256 + x * 4`. Row 1 starts at
byte 256, address `64'h88030100`. `(1,0)` is byte 4. `(63,63)`
starts at byte 16380, and the next byte is 16384. The lane at each
of those offsets is the clear word. `x` or `y` of 64 records
nothing. The shader is not run. This is not the screenshot.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed.
Remote 2026-09-23: `tb_g6lc_apu_vgpu_gof` 19 cases / 85 checks /
101 clocks, errors=0. Enable=1 is 406 cells / 20 flip-flops
(offset), 1,501 / 166 (lane), and 540 / 99 (record), no latches.
Enable=0 is 12, 21, and 11 ports and no cells.

The clear word `32'hFF1A0D0D` sits in that buffer as the bytes
0D 0D 1A FF. Byte 0 is red `8'h0D`. Green is `8'h0D`. Blue is
`8'h1A`. The high byte is `8'hFF`. `(0,0)` and `(1,0)` are the
low two words of the beat at `64'h88030000`. `(63,63)` is the
top lane of `64'h88033FE0`. A first byte of `8'hFF` records
nothing. The image is not kept. The shader is not run. This is
not the screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`.
TEX is not executed. Remote 2026-09-23: `tb_g6lc_apu_vgpu_byr`
17 cases / 71 checks / 86 clocks, errors=0. Enable=1 is 1,083
cells / 11 flip-flops (channels), 145 / 37 (record), and 125 /
45 (first byte), no latches. Enable=0 is 22, 10, and 10 ports
and no cells.

Row 1 of that buffer is the beat at `64'h88030100`. Byte 0 of
that beat is the same red `8'h0D`. The format tag is `B8G8R8X8`.
A blue first byte `8'h1A` or a high byte `8'hFF` records nothing.
A 480-high rectangle reads nothing. This is later than the
base-beat channels and it is not `g6lc_apu_vgpu_gof`. The image
is not kept. The shader is not run. This is not the screenshot.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed.
Remote 2026-09-23: `tb_g6lc_apu_vgpu_ryr` 22 cases / 91 checks /
107 clocks, errors=0. Enable=1 is 877 cells / 9 flip-flops
(row), 260 / 69 (record), and 211 / 77 (first byte), no latches.
Enable=0 is 21, 10, and 10 ports and no cells.

`(1,1)` is byte 260, lane 1 of the beat at `64'h88030100`.
`(2,3)` is byte 776, lane 2 of the beat at `64'h88030300`.
`(0,63)` is byte 16128, lane 0 of the beat at `64'h88033F00`.
Each lane is the bytes 0D 0D 1A FF. A blue or high byte in the
named lane stops the read. No triangle is walked. The image is
not kept. The shader is not run. This is not the screenshot.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed.
Remote 2026-09-24: `tb_g6lc_apu_vgpu_tpr` 23 cases / 95 checks /
124 clocks, errors=0. Enable=1 is 956 cells / 12 flip-flops
(points), 418 / 117 (record), and 318 / 125 (first byte), no
latches. Enable=0 is 21, 10, and 10 ports and no cells.

`(63,0)` is byte 252, lane 7 of the beat at `64'h880300E0`.
Byte 0 of that lane is red `8'h0D`. `(0,63)` stays byte 16128.
A swapped offset reads nothing. The image is not kept. The
shader is not run. This is not the screenshot.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed.
Remote 2026-09-24: `tb_g6lc_apu_vgpu_x6r` 21 cases / 87 checks /
103 clocks, errors=0. Enable=1 is 971 cells / 9 flip-flops
(corner), 371 / 99 (record), and 283 / 107 (first byte), no
latches. Enable=0 is 21, 10, and 10 ports and no cells.

`(63,63)` is byte 16380, lane 7 of the beat at `64'h88033FE0`.
Byte 0 of that lane is red `8'h0D`. The next byte is 16384.
`(63,0)` stays byte 252 and `(0,63)` stays byte 16128. A swapped
offset reads nothing. The image is not kept. The shader is not
run. This is not the screenshot. `g6lc_apu_vgpu_avail` still
rejects `NEXT`. TEX is not executed. Remote 2026-09-24:
`tb_g6lc_apu_vgpu_tcr` 22 cases / 91 checks / 107 clocks,
errors=0. Enable=1 is 1,032 cells / 9 flip-flops (corner), 380 /
99 (record), and 295 / 107 (first byte), no latches. Enable=0 is
22, 10, and 10 ports and no cells.

`(7,0)` is byte 28, lane 7 of the base beat at `64'h88030000`.
`(63,0)` is byte 252 at `64'h880300E0` and is not this point.
Putting offset 28 on `(63,0)` reads nothing. The image is not
kept. The shader is not run. This is not the screenshot.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed.
Remote 2026-09-24: `tb_g6lc_apu_vgpu_p7r` 21 cases / 87 checks /
103 clocks, errors=0. Enable=1 is 1,002 cells / 9 flip-flops
(point), 369 / 99 (record), and 277 / 107 (first byte), no
latches. Enable=0 is 22, 10, and 10 ports and no cells.

`(8,0)` is byte 32, lane 0 of the beat at `64'h88030020`.
`(15,0)` is byte 60, lane 7 of that same beat. `(7,0)` stays
byte 28 in the base beat. Putting offset 32 on `(7,0)` reads
nothing. The image is not kept. The shader is not run. This is
not the screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`.
TEX is not executed. Remote 2026-09-24: `tb_g6lc_apu_vgpu_b1r`
21 cases / 87 checks / 103 clocks, errors=0. Enable=1 is 955
cells / 9 flip-flops (beat), 399 / 115 (record), and 313 / 123
(first byte), no latches. Enable=0 is 21, 10, and 10 ports and
no cells.

`(56,0)` is byte 224, lane 0 of the beat at `64'h880300E0`.
`(63,0)` stays byte 252, lane 7 of that same beat. Putting offset
224 on `(63,0)`, or on the beat-1 record, reads nothing. Both
lanes are the bytes 0D 0D 1A FF. The image is not kept. The
shader is not run. This is not the screenshot.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed.
Remote 2026-09-24: `tb_g6lc_apu_vgpu_b7r` 21 cases / 87 checks /
103 clocks, errors=0. Enable=1 is 1,016 cells / 9 flip-flops
(beat), 421 / 115 (record), and 321 / 123 (first byte), no
latches. Enable=0 is 22, 10, and 10 ports and no cells.

`(16,0)` is byte 64, lane 0 of the beat at `64'h88030040`.
`(23,0)` is byte 92, lane 7 of that same beat. Putting offset 64
on `(56,0)` reads nothing. Both lanes are the bytes 0D 0D 1A FF.
The image is not kept. The shader is not run. This is not the
screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is
not executed. Remote 2026-09-24: `tb_g6lc_apu_vgpu_b2r` 21 cases /
87 checks / 103 clocks, errors=0. Enable=1 is 983 cells / 9
flip-flops (beat), 413 / 115 (record), and 313 / 123 (first
byte), no latches. Enable=0 is 21, 10, and 10 ports and no cells.

`(24,0)` is byte 96, lane 0 of the beat at `64'h88030060`.
`(31,0)` is byte 124, lane 7 of that same beat. Putting offset
96 on `(16,0)` reads nothing. Both lanes are the bytes 0D 0D 1A
FF. The image is not kept. The shader is not run. This is not
the screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX
is not executed. Remote 2026-09-24: `tb_g6lc_apu_vgpu_b3r` 21
cases / 87 checks / 103 clocks, errors=0. Enable=1 is 976 cells
/ 9 flip-flops (beat), 417 / 115 (record), and 317 / 123 (first
byte), no latches. Enable=0 is 21, 10, and 10 ports and no cells.

`(32,0)` is byte 128, lane 0 of the beat at `64'h88030080`.
`(39,0)` is byte 156, lane 7 of that same beat. Putting offset
128 on `(24,0)` reads nothing. Both lanes are the bytes 0D 0D 1A
FF. The image is not kept. The shader is not run. This is not
the screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX
is not executed. Remote 2026-09-24: `tb_g6lc_apu_vgpu_b4r` 21
cases / 87 checks / 103 clocks, errors=0. Enable=1 is 979 cells
/ 9 flip-flops (beat), 413 / 115 (record), and 313 / 123 (first
byte), no latches. Enable=0 is 21, 10, and 10 ports and no cells.

`(40,0)` is byte 160, lane 0 of the beat at `64'h880300A0`.
`(47,0)` is byte 188, lane 7 of that same beat. Putting offset
160 on `(32,0)` reads nothing. Both lanes are the bytes 0D 0D 1A
FF. The image is not kept. The shader is not run. This is not
the screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX
is not executed. Remote 2026-09-24: `tb_g6lc_apu_vgpu_b5r` 21
cases / 87 checks / 103 clocks, errors=0. Enable=1 is 976 cells
/ 9 flip-flops (beat), 417 / 115 (record), and 317 / 123 (first
byte), no latches. Enable=0 is 21, 10, and 10 ports and no cells.

`(48,0)` is byte 192, lane 0 of the beat at `64'h880300C0`.
`(55,0)` is byte 220, lane 7 of that same beat. Putting offset
192 on `(40,0)` reads nothing. Both lanes are the bytes 0D 0D 1A
FF. The image is not kept. The shader is not run. This is not
the screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX
is not executed. Remote 2026-09-24: `tb_g6lc_apu_vgpu_b6r` 21
cases / 87 checks / 103 clocks, errors=0. Enable=1 is 980 cells
/ 9 flip-flops (beat), 417 / 115 (record), and 317 / 123 (first
byte), no latches. Enable=0 is 21, 10, and 10 ports and no cells.

`tb_g6lc_apu_vgpu_cmd` was 15/62/73 after the rasterizer-bind field and was not
re-run after `VsbEn` through `B6xEn`.

## 7. Lab surface, gates, verification

The lab surface is a second set of private units, also absent from `g6lc_apu_sys`.

| Unit | Role |
|---|---|
| `g6lc_apu_cover` | One sample against one triangle. Signed 16-bit edges, +x right, +y up. Color is copied through. |
| `g6lc_apu_frag` | RGBA8 byte memory. Address `y * stride + x * 4`. Byte 0 is red. Ceiling 64×64, stride 256, 16384 bytes. |
| `g6lc_apu_rsurf` | One covered sample copied out of a resource image of the same shape. |
| `g6lc_apu_vgpu_rdb` | One `TRANSFER_FROM_HOST_3D` of that image. Guest stores are 32-byte beats. The 64×64 image is 512 beats at `64'h8800C000`. |
| `g6lc_apu_vgpu_xfer` | One stored backing entry into the resource. One matching beat. Lengths above 32 are not a multi-beat copy here. |

`use_image` together with `use_texel` or a texel write is a fault. `use_prog` together with
any of those is a fault. Program color is the compiler word `32'hAA000000` plus an FP32
immediate: 0 is opaque black `32'hFF000000`, 0.5 is gray `32'hFF808080`, 1.0 is white
`32'hFFFFFFFF`. An immediate of 2.0 does not write. The lab image keeps solid
`32'hFF0000FF` at `(0,0)`, program gray at `(1,0)`, texel `32'hFF80FF40` at `(2,0)`, gray
at `(0,32)`, and white at `(63,63)`. `y = 64` does not write. Sample `(1,0)` of the 4×2
resource ramp is `32'hA7A6A5A4`. `RESOURCE_CREATE_2D` records 64×64 and rejects a 128-wide
resource. `TEX` still returns `-26`.

| Gate | Plan exit | Where this tree is |
|---|---|---|
| A0 External contract | Pinned traffic, formats, errors, truthful capsets | Reference captured. QEMU 10.0.0 / virglrenderer 1.0.0, guest OpenWrt 24.10.2 / Linux 6.6.93 / Mesa 21.3. Hardware obligations open. |
| A1 Substrate | Address, source, epoch, drain, leases, truthful geometry | Partial, in the SoC box. Outlines `apu-testharness-bus.md`, `apu-firmware-ram.md`, `apu-native-exec.md`. L2 line fills are untagged. Scatter-gather and `g6lc_apu_queue` still take raw maps. |
| A2 Persistent service | OpenSBI S-mode service, protected hart, restart | Bring-up only. Cookies and hart fetch. `apu-firmware-domain.md`, `apu-cva6-fetch.md`. |
| A3 Protocol and compiler | A virtqueue, virgl resources, the same words on host and CVA6 | Subset. One compiler. Ordinary commands in the private units (create, fence, local used element and IRQ, one avail slot, one backing entry, one backing read, used-element write, `used.idx` store). One `SUBMIT_3D` checker, one execbuffer read, and the command list through byte 960. That list does not rasterize. Context 1, the two 3D resources, the three attaches, and the 24-byte scene response are recorded. Capset info and capset get are refused. Scanout and flush of resource 4 at 640 by 480 are recorded and do not present. `g6lc_apu_vgpu_avail` still rejects a descriptor chain. A separate walker accepts the scene chain and publishes one local used element. |
| A4 Resource-backed graphics | Vertex through fragment into one surface, cache-visible | Lab samples and a 64×64 byte memory exist. They are not the scene’s vertex, coverage, sampler, and fragment path. |
| A5 First picture | Unchanged Linux/Mesa EGL/GLES2 on this RTL, pixels from the program | Open. Requires A2, A3, and A4. Private fixtures are not that guest. |
| A6 Profile | CTS/dEQP, isolation, recovery | Open. |
| A7 Presentation | HDMI and DP, each with bandwidth, CDC, DFT, and a board PHY | Scanout model only: 640×480 `r5g6b5`, line buffer, video TMDS, 10× shift. `hdmi-display.md`. A booted simpledrm guest, a connector, and a PHY are open. |

Remote suites run under WSL through `verif/regress/remote/testharness_proxy.py` on the
testharness host. Verilator is v5.008. A sync line of rc=0 is not the suite result.
The CVA6 cookies were not re-run for the command prefix or the byte-memory split.

## 8. Pointers

| Question | Read |
|---|---|
| Leaf counts and the command each unit checks | `apu-resident-fw.md`, `AGENTS-todo.md` |
| Attach, bus, RAM, firmware, exec, TGSI | the other `apu-*.md` outlines in this directory |
| Scene, command bytes, screenshot identity | `g6lc_bios/architecture/DISPLAY.md` |
| Plan gates and the screenshot objective | `plan-5ddc97674e5bf9b0.md` sections 5 and 6 |
| HDMI scanout | `hdmi-display.md` |
| Snapshot beside the other SoC planes | `architecture/current-stage.md` |
