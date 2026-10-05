# CVA6 uncore — controller & PHY integration outlines

This tree is a **scaffold and blueprint**, not RTL. It is the uncore counterpart to the core
extension points one level up (`architecture/README.md`): it reserves, for each desktop-class
subsystem, *where* an external controller lands in `corev_apu`, *how* it splits into on-die
controller vs board/analog PHY, and *what* gates it must pass before it is wired into a flist.

> ### Scaffold contract (read first)
> - **Nothing here is compiled.** No file under `architecture/` is referenced by any flist, synthesis,
>   or `pd/` script. These outlines cannot break elaboration, simulation, synthesis, or tape-out.
> - **No RTL is moved or added by these docs.** They describe integration seams that already exist in
>   `corev_apu/` and point at controllers fetched on demand by the `build-platform` `vendor` command.
> - **`.md` only** — tier T (MIT) per `DOCS_UNDER_TIER`; no inline SPDX header, no code contract changed.

---

## How the three layers fit together

| Layer | File(s) | Answers |
|---|---|---|
| **Mechanism** | `AGENTS-vendor.md` | How a controller is fetched / updated / scanned. |
| **Substructure** | `AGENTS-core-platform-vendor-actives.md` | Which controllers/PHY exist and where they attach. |
| **RTL outline** | `architecture/uncore/*.md` (this tree) | Per-domain top module, bus, PHY split, config gate, verification, DTS. |
| **Uncore philosophy** | `AGENTS-corev-apu.md` | SystemVerilog preconditions for the whole uncore. |

---

## Map of uncore outlines

| Outline | Domain | Catalog ids | On-die vs board/PHY |
|---|---|---|---|
| `ddr4-controller.md` | memory | `litedram` | Controller on-die; DDR PHY = FPGA MIG / ASIC hard macro; DIMM on board |
| `dram-channel-scaling.md` | memory (I3) | `litedram` × N | **Shared** N-channel stripe on the DRAM slave: core pipelines, L2/L3, `NrCores`, and island DMA. Stability plan for `DramChannels`. |
| `ethernet-controller.md` | network | `verilog-ethernet`, `liteeth`, `corundum`, `ariane-ethernet` | MAC on-die; PHY = external chip |
| `pcie-root-complex.md` | interconnect | `verilog-pcie`, `litepcie` | Glue on-die; SerDes/link = hard IP; NVMe/GPU are endpoints |
| `pcie-endpoint.md` | interconnect | `verilog-pcie`, `litepcie` | **Inverse role:** LibreCore *is* the endpoint (CPU+AI card); BAR/config target on-die; SerDes = hard IP |
| `storage-controllers.md` | storage | `litesata`, `litesdcard` (+ NVMe over PCIe) | Controller on-die; SerDes/level-shift external |
| `hdmi-display.md` | display | `hdmi` | Default-off 640×480 r5g6b5 scanout through the 10× shift; opt-in simple-framebuffer at 0x8ef00000, not in the default DTB; connector on the board |
| `apu-graphics.md` | graphics APU | (in-tree `corev_apu/apu`) | **Lane map.** SoC box versus private fixtures; execbuffer through byte 960; scene chain beside the one-descriptor avail walker; gates A0–A7. Module call-graph: `corev_apu/apu/AGENTS-impl-interplays.md` |
| `apu-vulkan-engine.md` | graphics APU | `specs/venus-protocol` (lazy pin), in-tree `corev_apu/apu` | **Engine structure for the stock-client (hardware Venus) route.** Generated vn_protocol decoder (`gen_vn_tables.py` → `g6lc_apu_vn_pkg.sv`), `tc_sram` object table, recorded command buffers, direct-SPIR-V SIMT shader core with AI dot PEs behind a MatHelper port, tile-based raster; catalog-leaf review and increments 2–5 |
| `apu-native-exec.md` | graphics APU | (in-tree `corev_apu/apu`) | Native exec leaf: one FPnew lane, four lockstep quad contexts, `LDC` 32-bit payload, uniform BR, local LSU; default-off |
| `apu-testharness-attach.md` | graphics APU | (in-tree `corev_apu/apu`) | PLIC splice + opt-in diagnostic xbar windows; trusted production source/RAM protection still open |
| `apu-fw-exec.md` | graphics APU | (in-tree `corev_apu/apu`) | Firmware mailbox bound to native exec; testharness `ExecEn && !MemEn` |
| `apu-testharness-bus.md` | graphics APU | (in-tree `corev_apu/apu`) | AXI4-64 adapter + opt-in testharness xbar ports + idle DMA export (`+define+G6LC_APU`) |
| `apu-testharness-load.md` | graphics APU | (in-tree `corev_apu/apu`) | Testharness load compositor: DRAM hole + hart-1 boot PC + 14-rule OpenSBI-visible map |
| `apu-firmware-domain.md` | graphics APU | (in-tree `corev_apu/apu`) | OpenSBI domain / PMP NAPOT + opt-in `ariane-g6lc-apu.dts`; not SMT2 firmware |
| `apu-resident-fw.md` | graphics APU | `software/apu-fw` | Hart-1 mailbox images, plus the leaf chronicle of the private virtio prefix. Structure is `apu-graphics.md` |
| `apu-firmware-ram.md` | graphics APU | (in-tree `corev_apu/apu`) | Testharness firmware RAM at `0x90000000` / 256 KiB; idx 12; I$ INCR fills |
| `apu-cva6-fetch.md` | graphics APU | (in-tree `corev_apu/apu`) | CVA6 fetch of `apu_fw.hex`; cluster PerCoreBoot; cookies `0x600D000A` / `0x600D000B`; resident `apu_tgsi_cc.hex`; DRAM-lo OpenSBI load-addr fetch |
| `apu-tgsi.md` | graphics APU | `software/apu-fw` | TGSI text subset → native exec; `IMM[n]` via `LDC`; separate `apu_tgsi_fw` image; not TEX; not in `apu_fw.elf` |

---

## APU completion review (2026-09-23)

Read `apu-graphics.md` before the leaf outlines. It is the structure: the tracked
SoC box (`g6lc_apu_attach` → `g6lc_apu_soc` → `g6lc_apu_sys`, `Flist.apu_soc`)
versus the untracked private command and surface units, which `g6lc_apu_sys`
does not instantiate. The module default is `ApuOff`. The diagnostic testharness
passes `ApuHarness`. Both leave the graphics enables at 0.

The frozen execbuffer command list ends at the draw (count 4, triangle
strip, byte 960, `g6lc_apu_vgpu_drw`). Decoding that list does not
rasterize. A 64 by 64 box is not the scissor in this stream. The
scene response is 24 bytes at `64'h8800A800`. Context 1, the two 3D
resources, and the three attaches are recorded with it. The avail
walker rejects a descriptor chain. `g6lc_apu_vgpu_cmd` rejects
`SUBMIT_3D`. Capset info and capset get record `INVALID_PARAMETER`.
Scanout 0 and the flush record resource 4 at 640 by 480 and do not
present a frame. A separate walker accepts the scene's three-descriptor
chain, publishes one local used element, and writes that element to
`64'h8800_D000` and `used.idx` 1 to `64'h8800_E002`. `g6lc_apu_vgpu_avail`
still rejects `NEXT`. The clear color is stored at the four corners of
the 64 by 64 ceiling, and that word stands for all 4096 samples.
The 24 quad floats match the NDC square. Viewport scales 320 and 240
put that square over 0..640 by 0..480, so every ceiling sample is
covered. The stored color stays `32'hFF1A0D0D`. The vertex text is
the 32-dword VERT passthrough at byte 48. The fragment text is the
35-dword TEX program at byte 200. That program is bound to sampler
view 5 on resource 1 and sampler state 6. Resource 1 is a 640 by 480
`B8G8R8X8` image. Its top 640 by 64 band is read as 5,120 beats and
the image is not stored. Ceiling `(0,0)` is that corner texel. `(1,0)` is the half blend
`32'hD2008000`. `x = 8` spans the beat and is `32'h8091A2B3`. `y = 1`,
`x = 0` is `32'h53010202` and `y = 1`, `x = 1` is `32'h6B024303`. On that
row, `x = 2` is `32'h42024203` and `x = 7` is `32'h1A222B33`. `x = 8`
spans the beat and is `32'h434C545D`. `y = 2`, `x = 0` is `32'h79797A7A`
and `y = 2`, `x = 1` is `32'h42424343`. Every point of the 64 by 64
ceiling can be sampled. `(0,3)` is `32'h78787878`. The ceiling is
written and read back as 512 beats at `32'h88040000`. Beat 0 is
`32'hA5000000` and beat 24 is `32'h78787878`. The scene header and the
960-byte execbuffer are fetched. The first command word is
`32'h00050801`. The `DRAW_VBO` at byte 908 is recognized: count 4,
triangle strip, and it is not executed. The 24 NDC floats at byte 696
are read. The first is -1 and the last is +1. They are not transformed.
The viewport at byte 824 places that square on 0..640 by 0..480.
The scissor at byte 808 is that same rectangle. No pixel is clipped.
The clear at byte 872 packs to `32'hFF1A0D0D`. No pixel is written.
The framebuffer at byte 856 names one color buffer, surface 1.
No memory is attached. The vertex-buffer set at byte 792 is stride
24, offset 0, resource 3. No vertices are fetched. The inline write
at byte 648 names that resource and 96 bytes. The floats are not kept.
The sampler view at byte 632 names fragment slot 0 and handle 5.
The sampler state at byte 616 names fragment slot 0 and handle 6.
The vertex-element bind at byte 608 names handle 4.
The fragment shader at byte 596 names handle 3.
The vertex shader at byte 584 names handle 2.
The rasterizer bind at byte 576 names handle 9.
The depth-stencil bind at byte 568 names handle 8.
The blend bind at byte 560 names handle 7.
The rasterizer object at byte 520 names handle 9. Its eight state words are 0.
The depth-stencil object at byte 496 names handle 8. Its four state words are 0.
The blend object at byte 448 names handle 7 and color word `32'h78020010`.
The sampler-state object at byte 408 names handle 6, wrap word `32'h00002292`, and max LOD `32'h42000000`.
The sampler view at byte 380 names handle 5, resource 1, format `32'h02000002`, and swizzle `32'h00000688`.
The vertex-element object at byte 340 names handle 4, with format 31 at offset 0 and format 29 at offset 16.
The fragment-shader object at byte 176 names handle 3, fragment stage, length 140, and text dword `32'h47415246`. The vertex-shader object at byte 24 names handle 2, vertex stage, length 125, and text dword `32'h54524556`. The surface object at byte 0 names handle 1, resource 4, and format 2.
Guest descriptors at `64'h8800E100` link the header, the 960-byte execbuffer, and the 24-byte response. Avail index 1 at `64'h8800E200` names descriptor 0. The completed-opcode list at `64'h8800E300` is count 0 and capset id 0. The virgl capset stays refused. A 64 by 64 guest window at `64'h88020000` is 512 beats of clear word `32'hFF1A0D0D`. The guest response at `64'h8800A800` is `OK_NODATA` with fence `64'h1122334455667788`. The used element at `64'h8800E400` is descriptor 0 and length 24. The used index at `64'h8800E480` is 1. The used-buffer interrupt reason at `64'h8800E500` is `32'h1`. Ack lowers the pin. The guest ack at `64'h8800E510` is `32'h1`, and the status word at `64'h8800E500` is then `32'h0`. All 512 beats of the window are that clear word. That window is copied to `64'h88030000`, a 64 by 64 rectangle of 16384 bytes. `(1,0)` is byte 4 and row 1 starts at byte 256. The clear word sits in memory as the bytes 0D 0D 1A FF, so byte 0 is red. Row 1 at `64'h88030100` starts with that same red byte. `(1,1)` is byte 260, `(2,3)` is byte 776, and `(0,63)` is byte 16128. `(63,0)` is byte 252 at `64'h880300E0`. `(7,0)` is byte 28, lane 7 of `64'h88030000`. `(8,0)` is byte 32 and `(15,0)` is byte 60, both in `64'h88030020`. `(56,0)` is byte 224, lane 0 of `64'h880300E0`, and `(63,0)` stays byte 252, lane 7 of that beat. `(16,0)` is byte 64 and `(23,0)` is byte 92, both in `64'h88030040`. `(24,0)` is byte 96 and `(31,0)` is byte 124, both in `64'h88030060`. `(32,0)` is byte 128 and `(39,0)` is byte 156, both in `64'h88030080`. `(40,0)` is byte 160 and `(47,0)` is byte 188, both in `64'h880300A0`. `(48,0)` is byte 192 and `(55,0)` is byte 220, both in `64'h880300C0`. `(63,63)` is byte 16380, lane 7 of `64'h88033FE0`. The linear sample pair is written as fragment color at `64'h88050000`. `(0,0)` is the clamp texel `32'hA5000000`. `(1,0)` is the half blend `32'hD2008000`. Those 512 ceiling sample beats are copied to `64'h88060000`. That window is a 64 by 64 rectangle. `(1,0)` in it is the half blend `32'hD2008000`. `(0,0)` is the clamp texel `32'hA5000000`. That rectangle is copied to `64'h88070000` as `TRANSFER_FROM_HOST_3D` of resource 4. That guest buffer is a 64 by 64 rectangle. Offset in that guest rectangle is `y * 256 + x * 4`. `(1,0)` is byte 4. `(0,0)` is the clamp texel `32'hA5000000`. `(63,63)` is byte 16380 at `64'h88073FE0`. The `TRANSFER_FROM_HOST_3D` box is `(0,0,64,64)` of resource 4 at 640 by 480. Packed stride is 256. `RESOURCE_ATTACH_BACKING` of that buffer is length 16384. The 24-byte virtio `OK_NODATA` of that transfer is at `64'h880A0000` with fence 2. The used element is at `64'h880B0000` with id 1 and `used.idx` 2. The used-buffer interrupt reason `32'h1` is at `64'h880C0000`. The guest ack of that interrupt is at `64'h880C0010`. The guest descriptor chain of that transfer is at `64'h880D0000`. TEX of sampler view 5 at `(0,0)` is `32'hA5000000`. Beat 0 of the scene window at `64'h88020000` is that pair. Beat 0 of the guest readback at `64'h88030000` is that pair. A posted walker accepts `NEXT` for that transfer chain at avail index 2. Guest QueueNotify of control queue 0 is at `64'h880D0200`. Guest `virtq_avail.idx` after that notify is 2 at `64'h880D0100`. Guest `virtq_avail.ring[0]` names descriptor 0 at `64'h880D0104`. Guest `virtq_desc` 0 is the attach at `64'h88090000` with `NEXT` to 1. Guest `virtq_desc` 1 is the transfer at `64'h88080000` with `NEXT` to 2. Guest `virtq_desc` 2 is the `WRITE` of the 24-byte response at `64'h880A0000`. Guest `OK_NODATA` after that `WRITE` is fence 2 at `64'h880A0000`. Guest used element after that `OK_NODATA` is id 1 / `used.idx` 2. Guest used-buffer interrupt after that index is reason `32'h1` at `64'h880C0000`. Guest ack of that interrupt is `32'h1` at `64'h880C0010`. Scene `virtq_avail.idx` after that ack is 1 at `64'h8800E200`. Scene `virtq_avail.ring[0]` names descriptor 0 at `64'h8800E204`. Scene `virtq_desc` 0 is the 32-byte header at `64'h8800A000` with `NEXT` to 1. Scene `virtq_desc` 1 is the 960-byte execbuffer at `64'h8800B000` with `NEXT` to 2. Scene `virtq_desc` 2 is the `WRITE` of the 24-byte response at `64'h8800A800`. The shader is not run.
No blend is applied. No depth test is run. No triangle is walked. The shader is not run. No vertices are fetched. No texture is bound.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. The image
is not kept in registers. Scanout 0 names that
resource at 640 by 480, and the band flush does not present a frame.
The triangle is not walked.
Leaf counts stay in `apu-resident-fw.md`.

Gates, from the API-neutral plan: A0 is reference traffic. A1 is a partial
substrate in the SoC box. A2 is bring-up cookies and hart fetch. A3 is the
command subset above, plus one TGSI compiler for which `TEX` returns `-26`.
A4 is lab samples and a 64×64 byte memory, not the scene path. A5–A7 are open.
A5 is the first time the 64×64 `gles2-min` readback counts, and it requires
A2+A3+A4 with pixels from this device. `FeatureVirgl` stays outside
`APU_IMPL_FEATURES`. HDMI remains `hdmi-display.md`: a default-off 640×480
`r5g6b5` model, not a booted guest and not this 3D surface.

`apu-firmware-domain.md` still owns the persistent S-mode service and the
optional BIOS loader. `apu-native-exec.md` and `apu-tgsi.md` own the prototype
lane and the compiler subset. `apu-fw-exec.md` owns the mailbox bound to exec.
Cookies and DMEM fills are not Linux/Mesa GLES2 proof.

## What each outline contains

Every outline follows the same one-page shape (mirroring the core extension-point READMEs):

1. **Intent** — what the subsystem adds and why.
2. **Chosen controller(s)** — upstream repo, license, catalog id, `vendor` fetch line.
3. **Controller vs PHY split** — the on-die/board boundary (the decisive fact).
4. **Integration seam** — where it attaches in `corev_apu` (AXI/NoC, board wrapper, constraints).
5. **Config gating** — the `CVA6Cfg` / board-config knobs it should sit behind.
6. **Invariants** — ordering, reset, CDC, precise-trap, and DFT rules it must honour.
7. **Verification + software** — testbench, device tree, Linux driver, cross-validation.
8. **Scan pointers** — what `vendor scan <id>` should surface before integration.

## Promotion path (scaffold → integrated)

Identical to `architecture/README.md`: `vendor sync` the controller → config-gate it → implement the
`corev_apu` wrapper at the AXI seam → register in the `corev_apu`/FPGA flist → verify/test → observe
(RVFI/PMU/DTS) → document (bump `status` to `integrated`, update `AGENTS-specs-to-impl.md`). Vendoring
the source is **step zero**, not the finish line.
