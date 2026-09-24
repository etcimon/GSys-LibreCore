# APU resident firmware

**Domain:** graphics uncore · **Status:** bring-up images; production command service remains open

The firmware is an independently built device-control program in
`software/apu-fw`, not part of the BIOS UI, Linux virtio-gpu driver or Mesa.
Its permitted work is bounded decoding/validation, resource management,
queue scheduling and shader compilation. Vertex processing, rasterization,
texture sampling, fragment shading and pixel generation execute on APU RTL.

## What the committed images prove

| Image | Actual behavior at `d74010111` |
|---|---|
| `apu_fw.elf` / `apu_fw.hex` | Programs a TID+IADD native job; peeks 10/11; cookie `0x600D000A` |
| `apu_tgsi_fw.elf` / `apu_tgsi.hex` | Pre-encoded MOV shader job; cookie `0x600D000B`; no compiler |
| `apu_tgsi_cc.elf` / `apu_tgsi_cc.hex` | Same compiler as the host. Mutated MOV, IMM `.yyyy`, and `IF`/`TEX` → `-26`, then the MOV job; cookie `0x600D000B` |

A mini-hart model and directed CVA6 tests fetch these images from firmware
RAM. They are not a protected S-mode service, virtqueue decoder or stock-driver
renderer. Host and CVA6 now call one TGSI compiler for this subset.
`IN`/`OUT`/`CONST` still share register numbers. See `apu-tgsi.md`.

`g6lc_apu_vgpu_cmd` decodes one 40-byte virtio-gpu control payload. The low
32 bits are the little-endian type. `RESOURCE_CREATE_2D` (`0x0101`) records
a resource when the id is nonzero, the format is `R8G8B8A8_UNORM` (67), and
the size fits the local 64×64 image. A 128-wide resource is rejected.
An 8×4 resource, a 16×8 resource, a 32×16 resource, a 64×32 resource,
and a 64×64 resource are recorded. `VIRTIO_GPU_FLAG_FENCE` copies `fence_id`
onto the response, including an error. `SUBMIT_3D` (`0x0207`) returns
`INVALID_PARAMETER` and does not create a resource. Two slots are the table.
`ProtoEn` defaults to 0 and does not make virgl legal. The unit is not on
the testharness flist. It does not read an avail ring, write a used element,
or raise an interrupt. Remote 2026-09-22: `tb_g6lc_apu_vgpu_cmd` 15 cases /
62 checks / 73 clocks, errors=0. The command unit records the size and
does not store image bytes. Its enabled synthesis was not rerun for
the beat split. The CVA6
cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_used` publishes one local `virtq_used` element for that
response. The element is stored first. `used.idx` advances on the next
cycle, and that advance is the publication. IRQ rises with the index and
stays high until ack. A cancel after the element and before the index
does not publish and does not raise IRQ. The queue length is 8. The
response length is 24 bytes. After a fenced `RESOURCE_CREATE_2D`, descriptor
4 is element 0 and the index becomes 1. `UsedEn` defaults to 0. The unit
does not read an avail ring and does not write guest memory. Remote
2026-09-22: `tb_g6lc_apu_vgpu_used` 5 cases / 31 checks / 37 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 16 ports and no cells;
Enable=1 is 1,342 cells / 613 flip-flops.

`g6lc_apu_vgpu_avail` walks one local avail-ring slot. The queue length
is 8. The driver may publish only the next index, and a jumped index
does not post. An empty ring returns no command. One walk returns
descriptor 4 and its 40-byte `RESOURCE_CREATE_2D` command. Those bytes
decode to `OK_NODATA` with fence `64'h1122334455667788` and resource 7,
and the local used ring publishes that descriptor as element 0.
`NEXT`, `WRITE`, and `INDIRECT` fault and do not consume the slot. A
length other than 40 faults the same way. A later post is not reached
while that fault stays at the head. The walk does not follow a chain
and does not read guest memory. `AvailEn` defaults to 0 and does not
make virgl legal. The unit is not on the testharness flist. Remote
2026-09-22: `tb_g6lc_apu_vgpu_avail` 17 cases / 77 checks / 93 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and no cells;
Enable=1 is 7,731 cells / 3,356 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_sub` accepts one `SUBMIT_3D` (`0x0207`) chain of
descriptors 0, 1, and 2. Descriptor 0 carries `NEXT` and the 32-byte
`virtio_gpu_cmd_submit` header. Descriptor 1 carries `NEXT` and names
the execbuffer. Descriptor 2 carries `WRITE` and is the 24-byte
response. The header is read from guest memory. The execbuffer is not
read, and the response is not written. `INDIRECT`, a command
descriptor marked `WRITE`, a broken link, a zero or oversized buffer,
and a bad address are `INVALID_PARAMETER` and issue no read. A header
whose type is not `SUBMIT_3D`, whose size disagrees with descriptor 1,
or whose flags are not a plain fence is `INVALID_PARAMETER` after the
read. A failed or mismatched read is `ERR_UNSPEC` and records nothing.
A second submit is `ERR_UNSPEC` and does not replace the first. The
recorded submit keeps context 3 and a 32-byte buffer at
`64'h8800_B000`, or context 1 and 960 bytes at the same address after
reset. The header address is `64'h8800_A000`. The response address is
`64'h8800_A800`. The buffer ceiling is 1024 bytes. This is not a draw.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. `g6lc_apu_vgpu_cmd` still
returns `INVALID_PARAMETER` for `SUBMIT_3D` and does not create a
resource. `SubEn` defaults to 0 and does not make virgl legal. The
unit is not on the testharness flist. Remote 2026-09-23:
`tb_g6lc_apu_vgpu_sub` 19 cases / 147 checks / 97 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 19 ports and no cells;
Enable=1 is 4,400 cells / 521 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_buf` reads the execbuffer named by that submit. The
bytes arrive 32 at a time and stay in a byte memory. `valid` rises
after the last good beat. A failed beat leaves `valid` clear, and the
read can be retried. A second read is a fault and does not replace
the buffer. No recorded submit returns empty and issues no read. A
zero, oversized, unaligned, or wrapping buffer is a fault. The 40-byte
buffer is two beats; byte 0 is the offset and byte 36 is the last
stored word, and the next word stays 0. The 960-byte buffer is 30
beats at `64'h8800_B000`, with the last word at byte 956. The commands
in the buffer are not decoded. The response is not written. This is
not a draw. `BufEn` defaults to 0 and does not make virgl legal. The
unit is not on the testharness flist. Remote 2026-09-23:
`tb_g6lc_apu_vgpu_buf` 12 cases / 100 checks / 132 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 21 ports and no cells;
Enable=1 is 597,069 cells / 8,646 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_dec` reads the first command in that buffer. The header
word is `cmd | object<<8 | body_dwords<<16`. The frozen stream starts
with `CREATE_OBJECT` of a surface: command 1, object 8, five body
words. Those words are handle 1, resource 4, format `B8G8R8X8` (2),
and two zeros. The following command begins at byte 24. A NOP records
command 0 and a next offset of 4. Bytes after the first command stay
unread. A body that runs past the buffer, a surface whose handle is 0,
and a surface whose length is not 5 record nothing. A second decode
does not replace the first. This is not a draw. `DecEn` defaults to 0
and does not make virgl legal. The unit is not on the testharness
flist. Remote 2026-09-23: `tb_g6lc_apu_vgpu_dec` 12 cases / 46 checks /
102 clocks, errors=0. Fixture synth, no latches: Enable=0 is 11 ports
and no cells; Enable=1 is 1,064 cells / 364 flip-flops. The CVA6
cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_sh` reads the shader create that follows that surface.
The command is `CREATE_OBJECT` of a shader. The body is the handle,
the stage, the TGSI text length including the trailing NUL, the token
bound, and a zero stream-out count. The text length must account for
every body word after those five. The frozen vertex shader is handle
2, stage 0, length 125, and token bound 300. Its text starts at byte
48 with `VERT`, and the next command starts at byte 176. The text
stays in the execbuffer. A NOP, a buffer that ends at the surface, and
a length that does not match the body record nothing. A second decode
does not replace the first. This is not a draw. `ShEn` defaults to 0
and does not make virgl legal. The unit is not on the testharness
flist. Remote 2026-09-23: `tb_g6lc_apu_vgpu_sh` 14 cases / 56 checks /
133 clocks, errors=0. Fixture synth, no latches: Enable=0 is 12 ports
and no cells; Enable=1 is 2,516 cells / 480 flip-flops. The CVA6
cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_fs` reads the fragment shader create that follows that
vertex shader. The stage is 1. The frozen shader is handle 3, text
length 140 including the NUL, and token bound 300. Its text starts at
byte 200 with `FRAG`, and the next command starts at byte 340. The
text stays in the execbuffer. The vertex shader record stays in
place. A buffer that ends on the vertex shader, and a length that
does not match the body, record nothing. A second decode does not
replace the first. This is not a draw. `FsEn` defaults to 0 and does
not make virgl legal. The unit is not on the testharness flist.
Remote 2026-09-23: `tb_g6lc_apu_vgpu_fs` 18 cases / 71 checks / 212
clocks, errors=0. Fixture synth, no latches: Enable=0 is 12 ports
and no cells; Enable=1 is 2,428 cells / 480 flip-flops. The CVA6
cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_ve` reads the vertex-elements object that follows that
fragment shader. The object is handle 4 and holds two attributes on
vertex buffer 0. Position is `R32G32B32A32_FLOAT` at offset 0. The uv
is `R32G32_FLOAT` at offset 16. Both instance divisors are 0. The next
command starts at byte 380. The fragment shader record stays in place.
A buffer that ends on the fragment shader, and a body that is not two
attributes, record nothing. A second decode does not replace the
first. This is not a draw. `VeEn` defaults to 0 and does not make
virgl legal. The unit is not on the testharness flist. Remote
2026-09-23: `tb_g6lc_apu_vgpu_ve` 22 cases / 87 checks / 273 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 12 ports and no
cells; Enable=1 is 2,003 cells / 555 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_sv` reads the sampler view that follows that
vertex-elements object. The view is handle 5 over resource 1, the
scanout resource. The format is `B8G8R8X8` (2) and the target is 2D.
Layer and level are 0. The swizzle is identity `32'h00000688`. The
next command starts at byte 408. The vertex-elements record stays in
place. A buffer that ends on the vertex elements, a body that is not
six words, and a swizzle other than identity record nothing. A second
decode does not replace the first. This is not a texture sample and
not a draw. `SvEn` defaults to 0 and does not make virgl legal. The
unit is not on the testharness flist. Remote 2026-09-23:
`tb_g6lc_apu_vgpu_sv` 32 cases / 117 checks / 428 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 12 ports and no cells;
Enable=1 is 1,880 cells / 426 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_ss` reads the sampler state that follows that sampler
view. The state is handle 6. Wrap on S, T, and R is clamp-to-edge.
Min and mag filters are linear, and there is no mip filter
(`32'h00002292`). `lod_bias` and `min_lod` are 0. `max_lod` is 32.0
(`32'h42000000`). The four border words are 0. The next command
starts at byte 448. The sampler-view record stays in place. A buffer
that ends on the sampler view, a body that is not nine words, and a
state word other than this sampler record nothing. A second decode
does not replace the first. This is not a texture sample and not a
draw. `SsEn` defaults to 0 and does not make virgl legal. The unit is
not on the testharness flist. Remote 2026-09-23:
`tb_g6lc_apu_vgpu_ss` 37 cases / 125 checks / 498 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 12 ports and no cells;
Enable=1 is 2,066 cells / 491 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_bl` reads the blend object that follows that sampler
state. The object is handle 7. Color buffer 0 is `32'h78020010`:
source factor ONE at bits 4 and 17, and color mask `0xf` at bit 27.
The destination-factor fields, `S0`, `S1`, and the other seven color
buffers are 0. The next command starts at byte 496. The
sampler-state record stays in place. A buffer that ends on the sampler
state, a body that is not eleven words, and a different color-buffer
word record nothing. A second decode does not replace the first. This
is not a draw. `BlEn` defaults to 0 and does not make virgl legal. The
unit is not on the testharness flist. Remote 2026-09-23:
`tb_g6lc_apu_vgpu_bl` 42 cases / 136 checks / 584 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 12 ports and no cells;
Enable=1 is 2,153 cells / 523 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_ds` reads the depth-stencil object that follows that
blend object. The object is handle 8. The four state words are 0, so
depth and stencil stay off. The next command starts at byte 520. The
blend record stays in place. A buffer that ends on the blend object, a
body that is not five words, and a nonzero state word record nothing.
A second decode does not replace the first. This is not a depth test
and not a draw. `DsEn` defaults to 0 and does not make virgl legal.
The unit is not on the testharness flist. Remote 2026-09-23:
`tb_g6lc_apu_vgpu_ds` 47 cases / 146 checks / 658 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 12 ports and no cells;
Enable=1 is 1,713 cells / 298 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_rz` reads the rasterizer object that follows that
depth-stencil object. The object is handle 9. The eight state words
are 0, which this stream uses for fill-both and cull-none. The next
command starts at byte 560. The depth-stencil record stays in place.
A buffer that ends on the depth-stencil object, a body that is not
nine words, and a nonzero state word record nothing. A second decode
does not replace the first. This does not walk a triangle. `RzEn`
defaults to 0 and does not make virgl legal. The unit is not on the
testharness flist. Remote 2026-09-23: `tb_g6lc_apu_vgpu_rz` 52 cases /
155 checks / 726 clocks, errors=0. Fixture synth, no latches:
Enable=0 is 12 ports and no cells; Enable=1 is 1,993 cells / 427
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_bb` reads the blend bind that follows that rasterizer
object. The command is `BIND_OBJECT` for the blend type, and the body
names handle 7. The next command starts at byte 568. The rasterizer
record and the blend object stay in place. A buffer that ends on the
rasterizer, a body that is not one word, and a handle other than 7
record nothing. A second decode does not replace the first. This does
not draw. `BbEn` defaults to 0 and does not make virgl legal. The unit
is not on the testharness flist. Remote 2026-09-23:
`tb_g6lc_apu_vgpu_bb` 57 cases / 162 checks / 780 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 12 ports and no cells;
Enable=1 is 1,418 cells / 167 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_db` reads the depth-stencil bind that follows that
blend bind. The command is `BIND_OBJECT` for the depth-stencil type,
and the body names handle 8. Depth and stencil stay off. The next
command starts at byte 576. The blend bind stays in place. A buffer
that ends on the blend bind, a body that is not one word, and a handle
other than 8 record nothing. A second decode does not replace the
first. This does not test depth. `DbEn` defaults to 0 and does not
make virgl legal. The unit is not on the testharness flist. Remote
2026-09-23: `tb_g6lc_apu_vgpu_db` 62 cases / 167 checks / 818 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 12 ports and no
cells; Enable=1 is 1,417 cells / 167 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_rb` reads the rasterizer bind that follows that
depth-stencil bind. The command is `BIND_OBJECT` for the rasterizer
type, and the body names handle 9. Fill stays both faces and cull
stays none. The next command starts at byte 584. The depth-stencil
bind stays in place. A buffer that ends on the depth-stencil bind, a
body that is not one word, and a handle other than 9 record nothing.
A second decode does not replace the first. This does not walk a
triangle. `RbEn` defaults to 0 and does not make virgl legal. The unit
is not on the testharness flist. Remote 2026-09-23:
`tb_g6lc_apu_vgpu_rb` 67 cases / 174 checks / 858 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 12 ports and no cells;
Enable=1 is 1,417 cells / 167 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_vsb` reads the vertex-shader bind that follows that
rasterizer bind. The command is `BIND_SHADER`, the object field is 0,
and the body is handle 2 then stage 0. The TGSI text stays in the
execbuffer. The next command starts at byte 596. The rasterizer bind
stays in place. A buffer that ends on the rasterizer bind, a body that
is not two words, another handle, and a stage other than vertex record
nothing. A second decode does not replace the first. This does not
translate the shader. `VsbEn` defaults to 0 and does not make virgl
legal. The unit is not on the testharness flist. Remote 2026-09-23:
`tb_g6lc_apu_vgpu_vsb` 86 cases / 226 checks / 1105 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 12 ports and no cells;
Enable=1 is 1,489 cells / 208 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_fsb` reads the fragment-shader bind that follows that
vertex-shader bind. The command is `BIND_SHADER`, the object field is 0,
and the body is handle 3 then stage 1. The TGSI text stays in the
execbuffer. The next command starts at byte 608. The vertex-shader bind
stays in place. A buffer that ends on the vertex-shader bind, a body
that is not two words, another handle, and a stage other than fragment
record nothing. A second decode does not replace the first. This does
not translate the shader. `FsbEn` defaults to 0 and does not make virgl
legal. The unit is not on the testharness flist. Remote 2026-09-23:
`tb_g6lc_apu_vgpu_fsb` 92 cases / 240 checks / 1154 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 12 ports and no cells;
Enable=1 is 1,491 cells / 208 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_veb` reads the vertex-elements bind that follows that
fragment-shader bind. The command is `BIND_OBJECT` for the
vertex-elements type, and the body names handle 4. The next command
starts at byte 616. The fragment-shader bind stays in place. A buffer
that ends on the fragment-shader bind, a body that is not one word, and
a handle other than 4 record nothing. A second decode does not replace
the first. This does not draw. `VebEn` defaults to 0 and does not make
virgl legal. The unit is not on the testharness flist. Remote
2026-09-23: `tb_g6lc_apu_vgpu_veb` 82 cases / 215 checks / 982 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 12 ports and no cells;
Enable=1 is 1,417 cells / 167 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_ssb` reads the sampler-state bind that follows that
vertex-elements bind. The command is `BIND_SAMPLER_STATES`. The body is
fragment stage, slot 0, and sampler-state handle 6. The next command
starts at byte 632. The vertex-elements bind stays in place. A buffer
that ends on the vertex-elements bind, a body that is not three words,
another handle, and a stage other than fragment record nothing. A
second decode does not replace the first. This does not sample a
texture. `SsbEn` defaults to 0 and does not make virgl legal. The unit
is not on the testharness flist. Remote 2026-09-23:
`tb_g6lc_apu_vgpu_ssb` 104 cases / 273 checks / 1260 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 12 ports and no cells;
Enable=1 is 1,599 cells / 273 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_svb` reads the sampler-view set that follows that
sampler-state bind. The command is `SET_SAMPLER_VIEWS`. The body is
fragment stage, slot 0, and sampler-view handle 5. The next command
starts at byte 648. The sampler-state bind stays in place. A buffer
that ends on the sampler-state bind, a body that is not three words,
another handle, and a stage other than fragment record nothing. A
second decode does not replace the first. This does not sample a
texture. `SvbEn` defaults to 0 and does not make virgl legal. The unit
is not on the testharness flist. Remote 2026-09-23:
`tb_g6lc_apu_vgpu_svb` 110 cases / 290 checks / 1320 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 12 ports and no cells;
Enable=1 is 1,599 cells / 273 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_iw` reads the vertex inline write that follows that
sampler-view set. The command is `RESOURCE_INLINE_WRITE`. The body names
resource 3, a 96-byte box, and the first float is `-1.0`. The other
floats stay in the execbuffer. The next command starts at byte 792. The
sampler-view set stays in place. A buffer that ends on the sampler-view
set, a body that is not 35 words, another resource, and a first float
other than `-1.0` record nothing. A second decode does not replace the
first. This does not fetch vertices. `IwEn` defaults to 0 and does not
make virgl legal. The unit is not on the testharness flist. Remote
2026-09-23: `tb_g6lc_apu_vgpu_iw` 116 cases / 319 checks / 1500 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 12 ports and no cells;
Enable=1 is 1,464 cells / 110 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_vb` reads the vertex-buffer set that follows that inline
write. The command is `SET_VERTEX_BUFFERS`. The body is stride 24,
offset 0, and resource 3. The next command starts at byte 808. The
inline write stays in place. A buffer that ends on the inline write, a
body that is not three words, another stride, and another resource
record nothing. A second decode does not replace the first. This does
not fetch vertices. `VbEn` defaults to 0 and does not make virgl legal.
The unit is not on the testharness flist. Remote 2026-09-23:
`tb_g6lc_apu_vgpu_vb` 122 cases / 343 checks / 1638 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 12 ports and no cells;
Enable=1 is 1,624 cells / 297 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_sci` reads the scissor that follows that vertex-buffer
set. The command is `SET_SCISSOR`. The minimum is 0. The box word is
width 640 in the low half and height 480 in the high half. The next
command starts at byte 824. The vertex-buffer set stays in place. A
buffer that ends on the vertex-buffer set, a body that is not three
words, a nonzero minimum, and a 64 by 64 box record nothing. A second
decode does not replace the first. This does not draw. `SciEn` defaults
to 0 and does not make virgl legal. The unit is not on the testharness
flist. Remote 2026-09-23: `tb_g6lc_apu_vgpu_sci` 128 cases / 359 checks /
1696 clocks, errors=0. Fixture synth, no latches: Enable=0 is 12 ports
and no cells; Enable=1 is 1,564 cells / 233 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_vp` reads the viewport that follows that scissor. The
command is `SET_VIEWPORT`. The body is a zero slot, scale x 320.0
(`32'h43a00000`), scale y 240.0 (`32'h43700000`), scale z 1.0, the same
x and y as translates, and translate z 0. The record keeps scale x and
scale y. The next command starts at byte 856. The scissor stays in
place. A buffer that ends on the scissor, a body that is not seven
words, and another scale record nothing. A second decode does not
replace the first. This does not transform vertices. `VpEn` defaults to
0 and does not make virgl legal. The unit is not on the testharness
flist. Remote 2026-09-23, one run shared with the framebuffer, the
clear, and the draw: `tb_g6lc_apu_vgpu_tail` 337 cases / 955 checks /
4733 clocks, errors=0. Fixture synth, no latches: Enable=0 is 12 ports
and no cells; Enable=1 is 1,898 cells / 394 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_fbo` reads the framebuffer state that follows that
viewport. The command is `SET_FRAMEBUFFER`. The body is one color
buffer, no depth surface, and surface handle 1. The record keeps the
color-buffer count and the surface handle. The next command starts at
byte 872. The viewport stays in place. A buffer that ends on the
viewport, a body that is not three words, and another surface record
nothing. A second decode does not replace the first. This does not
attach memory. `FboEn` defaults to 0 and does not make virgl legal.
The unit is not on the testharness flist. The same remote run,
`tb_g6lc_apu_vgpu_tail`, errors=0. Fixture synth, no latches: Enable=0
is 12 ports and no cells; Enable=1 is 1,590 cells / 265 flip-flops.
The CVA6 cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_clr` reads the clear that follows that framebuffer
state. The command is `CLEAR`. The buffers word is color 0 (`32'd4`).
Red and green are 0.05 (`32'h3d4ccccd`), blue is 0.10
(`32'h3dcccccd`), and alpha is 1.0. The depth low word is 0, the depth
high word is `32'h3ff00000`, and the stencil word is 0. The record
keeps the buffers word and the four color words. The next command
starts at byte 908. The framebuffer state stays in place. A buffer
that ends on the framebuffer state, a body that is not eight words,
and another red word record nothing. A second decode does not replace
the first. This does not write pixels. `ClrEn` defaults to 0 and does
not make virgl legal. The unit is not on the testharness flist. The
same remote run, `tb_g6lc_apu_vgpu_tail`, errors=0. Fixture synth, no
latches: Enable=0 is 12 ports and no cells; Enable=1 is 2,103 cells /
522 flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_drw` reads the draw that follows that clear. The command
is `DRAW_VBO`. The count is 4 and the primitive is a triangle strip
(`32'd5`). The fifth body word is 1 and the eleventh is 3. The other
body words are 0. The record keeps the count and the primitive. This
command ends at byte 960, which is the end of the frozen 640 by 480
execbuffer. The clear stays in place. A buffer that ends on the clear,
a body that is not twelve words, and another primitive record nothing.
A second decode does not replace the first. This does not walk a
triangle. `DrwEn` defaults to 0 and does not make virgl legal. The unit
is not on the testharness flist. The same remote run,
`tb_g6lc_apu_vgpu_tail`, errors=0. Fixture synth, no latches: Enable=0
is 12 ports and no cells; Enable=1 is 2,224 cells / 555 flip-flops.
The CVA6 cookie was not re-run. The TEX opcode still returns `-26`.
`tb_g6lc_apu_vgpu_cmd` was 15 cases / 62 checks / 73 clocks and was not
re-run after `VsbEn` through `DrwEn`.

`g6lc_apu_vgpu_ctx` reads `CTX_CREATE` for context 1. The debug name is
`main` and the name length is 4. The next control record starts at byte
96. A short buffer, another name, and another context record nothing.
A second decode does not replace the first. This is not an OS context.
`CtxEn` defaults to 0 and does not make virgl legal. The unit is not on
the testharness flist. Remote 2026-09-23, one run shared with the two
3D resources, the three attaches, and the response:
`tb_g6lc_apu_vgpu_ctl` 27 cases / 88 checks / 375 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 11 ports and no cells;
Enable=1 is 1,828 cells / 811 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_c3d` reads the two `RESOURCE_CREATE_3D` records after
that context. Resource 4 is a 640 by 480 `B8G8R8X8` render target with
`Y_0_TOP`. Resource 3 is a 96-byte vertex buffer. The next record
starts at byte 240. A 64-wide target and a repeated resource record
nothing. A third create does not replace the pair. This does not
allocate memory. `C3dEn` defaults to 0 and does not make virgl legal.
The unit is not on the testharness flist. The same remote run,
`tb_g6lc_apu_vgpu_ctl`, errors=0. Fixture synth, no latches: Enable=0
is 12 ports and no cells; Enable=1 is 2,239 cells / 748 flip-flops.
The CVA6 cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_att` reads the three `CTX_ATTACH` records. The order is
resource 4, resource 3, then resource 1. The control prefix ends at
byte 336. An early attach and another resource record nothing. A fourth
attach does not replace the three. This does not map guest memory.
`AttEn` defaults to 0 and does not make virgl legal. The unit is not
on the testharness flist. The same remote run, `tb_g6lc_apu_vgpu_ctl`,
errors=0. Fixture synth, no latches: Enable=0 is 12 ports and no cells;
Enable=1 is 1,310 cells / 331 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_rsp` writes the 24-byte response at `64'h8800_A800` when
those attaches are recorded, the scene submit names context 1 and 960
bytes at `64'h8800_B000`, and the draw keeps count 4 and a triangle
strip. The header is `OK_NODATA`, the fence bit, fence
`64'h1122_3344_5566_7788`, and context 1. A failed beat leaves the
response clear and can be retried. A second store does not replace the
first. This does not store a pixel. Capset, scanout, and flush are not
this record. `RspEn` defaults to 0 and does not make virgl legal. The
unit is not on the testharness flist. The same remote run,
`tb_g6lc_apu_vgpu_ctl`, errors=0. Fixture synth, no latches: Enable=0
is 20 ports and no cells; Enable=1 is 939 cells / 200 flip-flops.
The CVA6 cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_nfo` reads `GET_CAPSET_INFO` for index 0. The recorded
answer is `INVALID_PARAMETER`. A nonzero index records nothing. A
second decode does not replace the refusal. This does not publish a
capset id. `NfoEn` defaults to 0 and does not make virgl legal. The
unit is not on the testharness flist. Remote 2026-09-23, one run
shared with the capset get, the scanout, and the flush:
`tb_g6lc_apu_vgpu_pre` 20 cases / 63 checks / 206 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 11 ports and no cells;
Enable=1 is 681 cells / 265 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_cap` reads `GET_CAPSET` for virgl id 1, version 1, after
that refusal. The recorded answer is `INVALID_PARAMETER`. No capset
blob is stored. Another version records nothing. A second decode does
not replace the refusal. `CapEn` defaults to 0 and does not make virgl
legal. The unit is not on the testharness flist. The same remote run,
`tb_g6lc_apu_vgpu_pre`, errors=0. Fixture synth, no latches: Enable=0
is 12 ports and no cells; Enable=1 is 1,209 cells / 329 flip-flops.
The CVA6 cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_scn` reads `SET_SCANOUT` after the scene response and
the three attaches. Scanout 0 names resource 4 and the rectangle
0,0,640,480. A 64 by 64 rectangle records nothing. A second decode
does not replace the first. This is not `g6lc_hdmi_scanout` and it
does not change a video mode. `ScnEn` defaults to 0 and does not make
virgl legal. The unit is not on the testharness flist. The same remote
run, `tb_g6lc_apu_vgpu_pre`, errors=0. Fixture synth, no latches:
Enable=0 is 13 ports and no cells; Enable=1 is 1,135 cells / 522
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_flu` reads `RESOURCE_FLUSH` of that scanout. The record
keeps resource 4 and 640 by 480. Another resource records nothing. A
second decode does not replace the first. This does not present a
frame. `FluEn` defaults to 0 and does not make virgl legal. The unit
is not on the testharness flist. The same remote run,
`tb_g6lc_apu_vgpu_pre`, errors=0. Fixture synth, no latches: Enable=0
is 12 ports and no cells; Enable=1 is 1,698 cells / 554 flip-flops.
The CVA6 cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_chn` accepts the scene submit as descriptors 0, 1, and 2.
The driver may publish only the next avail index, and that index names
descriptor 0. Descriptor 0 is `NEXT` to 1 and is the 32-byte header at
`64'h8800_A000`. Descriptor 1 is `NEXT` to 2 and is the 960-byte
execbuffer at `64'h8800_B000`. Descriptor 2 is `WRITE`, length 24, at
`64'h8800_A800`. `INDIRECT`, a jumped index, and a 32-byte execbuffer
do not consume the slot. A second walk keeps the first chain. This
does not read guest memory. `g6lc_apu_vgpu_avail` still rejects
`NEXT`, `WRITE`, and `INDIRECT`. `ChnEn` defaults to 0 and does not
make virgl legal. The unit is not on the testharness flist. Remote
2026-09-23, one run shared with the link and the used element:
`tb_g6lc_apu_vgpu_chn` 26 cases / 75 checks / 115 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 11 ports and no cells;
Enable=1 is 1,209 cells / 585 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_cmx` links that chain to the recorded submit and the
stored response. The buffer is 960 bytes at `64'h8800_B000` and the
response is `64'h8800_A800` with context 1 and the scene fence. A
32-byte submit links nothing. A second link keeps the first. `CmxEn`
defaults to 0 and does not make virgl legal. The unit is not on the
testharness flist. The same remote run, `tb_g6lc_apu_vgpu_chn`,
errors=0. Fixture synth, no latches: Enable=0 is 11 ports and no
cells; Enable=1 is 642 cells / 5 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_sun` stores one local used element for that link.
Descriptor 0, length 24, is stored first. `used.idx` then advances to
1 and IRQ rises with the index. A cancel after the element and before
the index does not publish. An ack drops IRQ. A second publish keeps
the first element. This does not write guest memory and it is not
`g6lc_apu_vgpu_used`. `SunEn` defaults to 0 and does not make virgl
legal. The unit is not on the testharness flist. The same remote run,
`tb_g6lc_apu_vgpu_chn`, errors=0. Fixture synth, no latches: Enable=0
is 16 ports and no cells; Enable=1 is 106 cells / 24 flip-flops.
The CVA6 cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_suw` writes that local element to guest memory. The store
is 8 bytes at `64'h8800_D000`: descriptor 0 in the low half and length
24 in the high half. A failed beat leaves the element unwritten and
can be retried. A second store does not replace the first. This is not
the `CREATE_2D` element at `64'h8800_3000` and it is not
`g6lc_apu_vgpu_uwr`. `SuwEn` defaults to 0 and does not make virgl
legal. The unit is not on the testharness flist. Remote 2026-09-23,
one run shared with the index store: `tb_g6lc_apu_vgpu_sunw` 11 cases /
56 checks / 61 clocks, errors=0. Fixture synth, no latches: Enable=0
is 17 ports and no cells; Enable=1 is 208 cells / 7 flip-flops. The
CVA6 cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_sux` writes the scene `used.idx` after that element.
The store is the 16-bit index 1 at `64'h8800_E002`. The separation
from the element is the same as `64'h8800_3000` to `64'h8800_4002`,
and the address is not `64'h8800_4002`. A failed beat can be retried.
A second store does not replace the first. This is not
`g6lc_apu_vgpu_uidx`. `SuxEn` defaults to 0 and does not make virgl
legal. The unit is not on the testharness flist. The same remote run,
`tb_g6lc_apu_vgpu_sunw`, errors=0. Fixture synth, no latches: Enable=0
is 18 ports and no cells; Enable=1 is 214 cells / 7 flip-flops. The
CVA6 cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_u8` turns the frozen clear into RGBA8. Red and green
0.05 become 13, blue 0.10 becomes 26, and alpha 1.0 becomes 255, round
half up. The word is `32'hFF1A0D0D`, byte 0 red. Another red word
records nothing. This is not a general float converter and it does not
store a pixel. `U8En` defaults to 0 and does not make virgl legal. The
unit is not on the testharness flist. Remote 2026-09-23, one run
shared with the corners and the read: `tb_g6lc_apu_vgpu_pix` 16 cases /
60 checks / 71 clocks, errors=0. Fixture synth, no latches: Enable=0
is 9 ports and no cells; Enable=1 is 283 cells / 6 flip-flops. The
CVA6 cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_pix` stores that word at the four corners of the 64 by
64 ceiling after the 640 by 480 scissor, surface 1, and the
four-vertex strip are recorded. The addresses are 0, 252, 16128, and
16380, which is `y * 256 + x * 4`. The interior is not written. The
triangle is not walked. A second store keeps the first. `PixEn`
defaults to 0 and does not make virgl legal. The unit is not on the
testharness flist. The same remote run, `tb_g6lc_apu_vgpu_pix`,
errors=0. Fixture synth, no latches: Enable=0 is 12 ports and no
cells; Enable=1 is 328 cells / 38 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_pxr` reads one of those corners. `(1,0)` is a miss.
`(64,0)` is outside the ceiling and records nothing. A second read of
`(0,0)` returns the same word. `PxrEn` defaults to 0 and does not make
virgl legal. The unit is not on the testharness flist. The same remote
run, `tb_g6lc_apu_vgpu_pix`, errors=0. Fixture synth, no latches:
Enable=0 is 10 ports and no cells; Enable=1 is 518 cells / 50
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_fil` lets that clear word stand for every sample of the
64 by 64 ceiling. The four corners are already stored and the scissor
is 640 by 480, which contains the ceiling. The record is one word and
a count of 4096. The samples are not stored one by one. A 64-high
scissor and another color record nothing. A second fill keeps the
first. The triangle is not walked. `FilEn` defaults to 0 and does not
make virgl legal. The unit is not on the testharness flist. Remote
2026-09-23, one run shared with the sample read: `tb_g6lc_apu_vgpu_fil`
14 cases / 56 checks / 63 clocks, errors=0. Fixture synth, no latches:
Enable=0 is 10 ports and no cells; Enable=1 is 234 cells / 38
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_frd` reads one sample of that fill. `(1,0)` is address
4 and returns `32'hFF1A0D0D`. `(2,3)` is address 776. `(63,63)` is
16380. `(64,0)` and `(0,64)` record nothing. The address is
`y * 256 + x * 4`. `g6lc_apu_vgpu_pxr` still reports `(1,0)` as a miss
of the corner record. `FrdEn` defaults to 0 and does not make virgl
legal. The unit is not on the testharness flist. The same remote run,
`tb_g6lc_apu_vgpu_fil`, errors=0. Fixture synth, no latches: Enable=0
is 10 ports and no cells; Enable=1 is 412 cells / 48 flip-flops. The
CVA6 cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_qd` checks the 24 floats of the fullscreen quad. They
start at byte 696, after the inline-write prefix, and end at byte 791.
Each vertex is `{x, y, 0, 1, u, v}`. The four vertices are `(-1,-1)`,
`(1,-1)`, `(-1,1)`, and `(1,1)`, with `u,v` at the same corners. A
mismatched float records nothing. A second check keeps the first. This
is not a transform. `QdEn` defaults to 0 and does not make virgl legal.
The unit is not on the testharness flist. Remote 2026-09-23, one run
shared with the coverage record and the sample read:
`tb_g6lc_apu_vgpu_qd` 14 cases / 52 checks / 113 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 12 ports and no cells;
Enable=1 is 697 cells / 22 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_cv` records that this NDC square, mapped by viewport
scales 320 and 240, covers window 0..640 by 0..480. The 64 by 64
ceiling is inside that rectangle, so every one of its 4096 samples is
covered. The stored color stays `32'hFF1A0D0D`. The fragment shader is
not run. This is not `g6lc_apu_cover`. A bad scale records nothing. A
second cover keeps the first. `CvEn` defaults to 0 and does not make
virgl legal. The unit is not on the testharness flist. The same remote
run, `tb_g6lc_apu_vgpu_qd`, errors=0. Fixture synth, no latches:
Enable=0 is 11 ports and no cells; Enable=1 is 255 cells / 70
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_cvr` reads one covered sample. `(1,0)` is address 4 and
returns `32'hFF1A0D0D` with the covered bit set. `(2,3)` is address
776. `(63,63)` is 16380. `(64,0)` records nothing. The address is
`y * 256 + x * 4`. `g6lc_apu_vgpu_pxr` still reports `(1,0)` as a miss
of the four stored corners. `CvrEn` defaults to 0 and does not make
virgl legal. The unit is not on the testharness flist. The same remote
run, `tb_g6lc_apu_vgpu_qd`, errors=0. Fixture synth, no latches:
Enable=0 is 10 ports and no cells; Enable=1 is 419 cells / 49
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_vst` checks the 32 dwords of the frozen vertex shader.
They start at byte 48. The length is 125, including the trailing NUL,
and the next command starts at byte 176. The text is the VERT
passthrough. The first dword is `32'h54524556`. A mismatched dword
records nothing. A second check keeps the first. This is not a
translate. `VstEn` defaults to 0 and does not make virgl legal. The
unit is not on the testharness flist. Remote 2026-09-23, one run
shared with the fragment text and the held sample:
`tb_g6lc_apu_vgpu_vtx` 20 cases / 75 checks / 225 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 12 ports and no cells;
Enable=1 is 751 cells / 12 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_fst` checks the 35 dwords of the frozen fragment shader.
They start at byte 200. The length is 140, including the trailing NUL,
and the next command starts at byte 340. The text is the TEX program.
The first dword is `32'h47415246`. A mismatched dword records nothing.
TEX is not executed. A second check keeps the first. `FstEn` defaults
to 0 and does not make virgl legal. The unit is not on the testharness
flist. The same remote run, `tb_g6lc_apu_vgpu_vtx`, errors=0. Fixture
synth, no latches: Enable=0 is 13 ports and no cells; Enable=1 is 809
cells / 13 flip-flops. The CVA6 cookie was not re-run. The TEX opcode
still returns `-26`.

`g6lc_apu_vgpu_hld` reads one covered sample while that fragment text
is the TEX program. The word stays `32'hFF1A0D0D`. `(1,0)` is address
4. `(2,3)` is 776. `(63,63)` is 16380. `(64,0)` records nothing.
`g6lc_apu_vgpu_pxr` still reports `(1,0)` as a miss of the four stored
corners. This is not `g6lc_apu_cover`. The triangle is not walked.
`HldEn` defaults to 0 and does not make virgl legal. The unit is not
on the testharness flist. The same remote run, `tb_g6lc_apu_vgpu_vtx`,
errors=0. Fixture synth, no latches: Enable=0 is 11 ports and no
cells; Enable=1 is 423 cells / 49 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_tbn` ties that TEX program to the sampler objects. The
fragment shader bind is handle 3, and the next command starts at byte
608. The sampler view is handle 5 over resource 1, format `B8G8R8X8`,
target 2D, identity swizzle, next byte 408. The sampler state is
handle 6, wrap clamp-to-edge, linear min and mag, no mip filter
(`32'h00002292`), `max_lod` 32.0, next byte 448. Both are bound on
fragment slot 0, and those binds end at bytes 632 and 648. A missing
TEX bit, another resource, or another handle records nothing. A second
link keeps the first. This does not fetch a texel. `TbnEn` defaults to
0 and does not make virgl legal. The unit is not on the testharness
flist. Remote 2026-09-23, one run shared with the refusal and the
sample read: `tb_g6lc_apu_vgpu_tbn` 15 cases / 57 checks / 67 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 14 ports and no
cells; Enable=1 is 747 cells / 101 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_den` refuses that sample. Resource 1 has no texel image
on this path. The record is refused, resource 1, the clear word
`32'hFF1A0D0D`, and a count of 4096. A different color records nothing.
A second refusal keeps the first. This does not fetch a texel. `DenEn`
defaults to 0 and does not make virgl legal. The unit is not on the
testharness flist. The same remote run, `tb_g6lc_apu_vgpu_tbn`,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and no
cells; Enable=1 is 310 cells / 102 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_dnr` reads one refused sample. `(1,0)` is address 4 and
returns `32'hFF1A0D0D` with the refused bit set. `(2,3)` is 776.
`(63,63)` is 16380. `(64,0)` records nothing. The address is
`y * 256 + x * 4`. `g6lc_apu_vgpu_pxr` still reports `(1,0)` as a miss
of the four stored corners. This is not `g6lc_apu_cover`. The triangle
is not walked. `DnrEn` defaults to 0 and does not make virgl legal.
The unit is not on the testharness flist. The same remote run,
`tb_g6lc_apu_vgpu_tbn`, errors=0. Fixture synth, no latches: Enable=0
is 10 ports and no cells; Enable=1 is 452 cells / 49 flip-flops. The
CVA6 cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_s2d` reads the VioScan `RESOURCE_CREATE_2D` for resource
1. The format is `B8G8R8X8` (2) and the size is 640 by 480. Format 67
and a 64-wide image record nothing. Those belong to
`g6lc_apu_vgpu_cmd`, which is unchanged. No pixels are stored. A second
decode keeps the first. `S2dEn` defaults to 0 and does not make virgl
legal. The unit is not on the testharness flist. Remote 2026-09-23,
one run shared with the backing entry and the transfer:
`tb_g6lc_apu_vgpu_s2d` 15 cases / 54 checks / 169 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 11 ports and no cells;
Enable=1 is 245 cells / 11 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_sbk` reads one backing entry for that resource. The
length is 1,228,800 bytes, which is 640 by 480 by 4. The address must
be nonzero and 4-byte aligned, and it must not be `32'h88001000` or
`32'h88002000`. The test presents `32'h8800F000`. That stand-in is not
the BIOS `__scan_fb` address. The bytes are not read. A second decode
keeps the first. `SbkEn` defaults to 0 and does not make virgl legal.
The unit is not on the testharness flist. The same remote run,
`tb_g6lc_apu_vgpu_s2d`, errors=0. Fixture synth, no latches: Enable=0
is 12 ports and no cells; Enable=1 is 504 cells / 75 flip-flops. The
CVA6 cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_sxf` reads the `TRANSFER_TO_HOST_2D` of that resource.
The rectangle is 0,0,640 by 64, the top band. A 480-high rectangle
records nothing. This band is not the 64 by 64 ceiling. No byte is
copied. The refused clear word stays `32'hFF1A0D0D`. A second decode
keeps the first. `SxfEn` defaults to 0 and does not make virgl legal.
The unit is not on the testharness flist. The same remote run,
`tb_g6lc_apu_vgpu_s2d`, errors=0. Fixture synth, no latches: Enable=0
is 14 ports and no cells; Enable=1 is 542 cells / 43 flip-flops. The
CVA6 cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_ssc` reads the VioScan `SET_SCANOUT`. Scanout 0 names
resource 1 at 640 by 480. A 64 by 64 rectangle and resource 4 record
nothing. Nothing is presented. This is not `g6lc_apu_vgpu_scn` and not
`g6lc_hdmi_scanout`. A second decode keeps the first. `SscEn` defaults
to 0 and does not make virgl legal. The unit is not on the testharness
flist. Remote 2026-09-23, one run shared with the flush and the sample:
`tb_g6lc_apu_vgpu_ssc` 17 cases / 61 checks / 153 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 12 ports and no cells;
Enable=1 is 349 cells / 11 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_sfl` reads the VioScan `RESOURCE_FLUSH` of resource 1.
The rectangle is the top band, 640 by 64. A 480-high flush records
nothing. Nothing is presented. This is not `g6lc_apu_vgpu_flu`. A
second decode keeps the first. `SflEn` defaults to 0 and does not make
virgl legal. The unit is not on the testharness flist. The same remote
run, `tb_g6lc_apu_vgpu_ssc`, errors=0. Fixture synth, no latches:
Enable=0 is 13 ports and no cells; Enable=1 is 432 cells / 11
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_spr` reads one ceiling sample while that scanout is
unpresented. `(1,0)` is address 4 and the word stays `32'hFF1A0D0D`.
`(2,3)` is 776. `(63,63)` is 16380. `(64,0)` records nothing. The
address is `y * 256 + x * 4`. No frame is presented and no texel is
copied. `g6lc_apu_vgpu_pxr` still reports `(1,0)` as a miss of the four
stored corners. `SprEn` defaults to 0 and does not make virgl legal.
The unit is not on the testharness flist. The same remote run,
`tb_g6lc_apu_vgpu_ssc`, errors=0. Fixture synth, no latches: Enable=0
is 11 ports and no cells; Enable=1 is 486 cells / 48 flip-flops. The
CVA6 cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_bcp` reads the top band of resource 1 from the backing
address. The band is 640 by 64, 163,840 bytes, 5,120 beats of 32. A
failed beat stops the copy and the request can be repeated. The image
is not stored. Beat 0's low word is kept. The other 1,064,960 bytes of
the 1,228,800-byte backing are not read. A 480-high transfer records
nothing. A second copy keeps the first. This is not
`g6lc_apu_vgpu_xfer`. `BcpEn` defaults to 0 and does not make virgl
legal. The unit is not on the testharness flist. Remote 2026-09-23,
one run shared with the report: `tb_g6lc_apu_vgpu_bcp` 10 cases / 41
checks / 10,297 clocks, errors=0. Fixture synth, no latches: Enable=0
is 20 ports and no cells; Enable=1 is 802 cells / 118 flip-flops. The
CVA6 cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_bcr` reports that copied word beside the clear color.
The scene word stays `32'hFF1A0D0D`. The test's beat-0 word is
`32'hA5000000`. The ceiling is not replaced. TEX is not executed.
`BcrEn` defaults to 0 and does not make virgl legal. The unit is not
on the testharness flist. The same remote run, `tb_g6lc_apu_vgpu_bcp`,
errors=0. Fixture synth, no latches: Enable=0 is 9 ports and no cells;
Enable=1 is 458 cells / 81 flip-flops. The CVA6 cookie was not re-run.
The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_tap` reads one texel from that band. `x` clamps to 639.
`y` above 63 is outside the copy and records nothing. The sampler is
the recorded clamp-to-edge linear state. At `(0,0)` the filter uses
that texel alone, and the word must match the band copy. A failed beat
can be retried. This does not blend a second tap. `TapEn` defaults to
0 and does not make virgl legal. The unit is not on the testharness
flist. Remote 2026-09-23, one run shared with the corner record and
the ceiling read: `tb_g6lc_apu_vgpu_tap` 13 cases / 51 checks / 68
clocks, errors=0. Fixture synth, no latches: Enable=0 is 24 ports and
no cells; Enable=1 is 1,471 cells / 105 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_pxc` stores that corner as ceiling pixel `(0,0)`. The
word is the copied texel `32'hA5000000` in the test. A second store
keeps the first. `PxcEn` defaults to 0 and does not make virgl legal.
The unit is not on the testharness flist. The same remote run,
`tb_g6lc_apu_vgpu_tap`, errors=0. Fixture synth, no latches: Enable=0
is 10 ports and no cells; Enable=1 is 189 cells / 37 flip-flops. The
CVA6 cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_pxq` reads one ceiling sample after that store. `(0,0)`
is address 0 and returns `32'hA5000000`. `(1,0)` is address 4 and
stays `32'hFF1A0D0D`. `(63,63)` stays the clear word. `(64,0)` records
nothing. `g6lc_apu_vgpu_frd` still returns the clear word at `(0,0)`.
This reader is the later one. `PxqEn` defaults to 0 and does not make
virgl legal. The unit is not on the testharness flist. The same remote
run, `tb_g6lc_apu_vgpu_tap`, errors=0. Fixture synth, no latches:
Enable=0 is 10 ports and no cells; Enable=1 is 355 cells / 49
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_lin` blends two taps on row 0 of the copied band. The
texel coordinate is `s = x - 1/2` with `u = x/640`. `x = 0` clamps
both taps to texel 0 and the word stays `32'hA5000000`. `x = 1` blends
texel 0 with texel 1 at one half, round half up per byte, and the test
word is `32'hD2008000`. `x = 7` blends the last two texels of the first
beat to `32'h33445566`. `x` above 7 and `y` other than 0 record
nothing. A second beat is not read. `LinEn` defaults to 0 and does not
make virgl legal. The unit is not on the testharness flist. Remote
2026-09-23, one run shared with the pair record: `tb_g6lc_apu_vgpu_lin`
11 cases / 41 checks / 63 clocks, errors=0. Fixture synth, no latches:
Enable=0 is 25 ports and no cells; Enable=1 is 2,000 cells / 84
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_lnr` keeps that origin and the blended neighbor. The
origin must match the corner store. A third record keeps the pair.
`g6lc_apu_vgpu_pxq` still returns the clear word at `(1,0)`. `LnrEn`
defaults to 0 and does not make virgl legal. The unit is not on the
testharness flist. The same remote run, `tb_g6lc_apu_vgpu_lin`,
errors=0. Fixture synth, no latches: Enable=0 is 11 ports and no
cells; Enable=1 is 247 cells / 71 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_spn` blends row 0 for `x = 0..15`. `x = 8` reads two
beats: texel 7 `32'h55667788` and texel 8 `32'hAABBCCDD`, half blend
`32'h8091A2B3`, round half up per byte. `x = 0` stays `32'hA5000000`.
`x = 1` stays `32'hD2008000`. `x` above 15 and `y` other than 0 record
nothing. `SpnEn` defaults to 0 and does not make virgl legal. The unit
is not on the testharness flist. Remote 2026-09-23, one run shared
with the span record: `tb_g6lc_apu_vgpu_spn` 11 cases / 39 checks / 68
clocks, errors=0. Fixture synth, no latches: Enable=0 is 25 ports and
no cells; Enable=1 is 2,422 cells / 156 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_spx` keeps the `x = 8` word. A second store keeps the
first. `SpxEn` defaults to 0 and does not make virgl legal. The unit
is not on the testharness flist. The same remote run,
`tb_g6lc_apu_vgpu_spn`, errors=0. Fixture synth, no latches: Enable=0
is 10 ports and no cells; Enable=1 is 130 cells / 37 flip-flops. The
CVA6 cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_vln` blends `y = 1` with row 1 of the copied band.
`t = y - 1/2`, so `y = 1` is halfway between row 0 and row 1. `x = 0`
uses the stored origin and row-1 texel `32'h01020304`, giving
`32'h53010202`. `x = 1` uses the stored neighbor and the half blend of
row-1 texels `32'h01020304` and `32'h05060708`, giving `32'h6B024303`.
The row-1 beat is the backing address plus 2,560 bytes. The test
address is `64'h8800FA00`. `y = 0`, `y` above 1, and `x` above 1 record
nothing. Row 0 is not overwritten. TEX is not executed. `VlnEn`
defaults to 0 and does not make virgl legal. The unit is not on the
testharness flist. Remote 2026-09-23, one run shared with the pair
record: `tb_g6lc_apu_vgpu_vln` 11 cases / 41 checks / 60 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 26 ports and no
cells; Enable=1 is 1,517 cells / 77 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_vlr` keeps those two words. `x = 0` must differ from the
row-0 origin. `x = 1` must differ from the row-0 neighbor. A third
record keeps the pair. `VlrEn` defaults to 0 and does not make virgl
legal. The unit is not on the testharness flist. The same remote run,
`tb_g6lc_apu_vgpu_vln`, errors=0. Fixture synth, no latches: Enable=0
is 10 ports and no cells; Enable=1 is 237 cells / 71 flip-flops. The
CVA6 cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_vbx` blends `y = 1` for `x = 0..7`. Both taps of each
row sit in beat 0. The unit reads that beat of row 0 at the backing
address, then the same beat of row 1 at the backing address plus 2,560
bytes. `x = 0` stays `32'h53010202` and must match the stored pair.
`x = 1` stays `32'h6B024303`. `x = 2` is `32'h42024203`. `x = 7` is
`32'h1A222B33`. `x` above 7, `y = 0`, and `y` above 1 record nothing.
The image is not stored. One 32-byte beat is held so the two rows can
be mixed. TEX is not executed. `VbxEn` defaults to 0 and does not make
virgl legal. The unit is not on the testharness flist. Remote
2026-09-23, one run shared with the store: `tb_g6lc_apu_vgpu_vbx`
12 cases / 53 checks / 78 clocks, errors=0. Fixture synth, no latches:
Enable=0 is 27 ports and no cells; Enable=1 is 3,891 cells / 336
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_vbr` keeps the `x = 2` word. A second store keeps the
first. The pair at `x = 0` and `x = 1` stays put. `VbrEn` defaults to
0 and does not make virgl legal. The unit is not on the testharness
flist. The same remote run, `tb_g6lc_apu_vgpu_vbx`, errors=0. Fixture
synth, no latches: Enable=0 is 10 ports and no cells; Enable=1 is 129
cells / 37 flip-flops. The CVA6 cookie was not re-run. The TEX opcode
still returns `-26`.

`g6lc_apu_vgpu_vsp` blends `y = 1` for `x = 0..15`. `x = 8` reads beat
0 and beat 1 of each row. Row 0 at that column stays the stored span
`32'h8091A2B3`, from texel 7 `32'h55667788` and texel 8 `32'hAABBCCDD`.
Row 1 texel 8 is `32'h0A0B0C0D`. The vertical blend is `32'h434C545D`.
`x = 0` stays `32'h53010202`. `x = 1` stays `32'h6B024303`. `x = 2`
stays `32'h42024203`. `x = 15` is `32'h0`, because both taps sit in
beat 1 and those lanes are 0. `x` above 15, `y = 0`, and `y` above 1
record nothing. The image is not stored. TEX is not executed. `VspEn`
defaults to 0 and does not make virgl legal. The unit is not on the
testharness flist. Remote 2026-09-23, one run shared with the store:
`tb_g6lc_apu_vgpu_vsp` 13 cases / 63 checks / 91 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 28 ports and no cells; Enable=1
is 3,388 cells / 185 flip-flops. The CVA6 cookie was not re-run. The
TEX opcode still returns `-26`.

`g6lc_apu_vgpu_vsx` keeps the `x = 8` word. A second store keeps the
first. The earlier `y = 1` words stay put. `VsxEn` defaults to 0 and
does not make virgl legal. The unit is not on the testharness flist.
The same remote run, `tb_g6lc_apu_vgpu_vsp`, errors=0. Fixture synth,
no latches: Enable=0 is 12 ports and no cells; Enable=1 is 199 cells /
37 flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_y2b` blends `y = 2` for `x = 0..7`. `t = y - 1/2`, so
the sample is halfway between row 1 and row 2. Both taps sit in beat
0. Row 1 is the backing address plus 2,560 bytes. Row 2 is that
address plus another 2,560 bytes, `64'h88010400` in the test. `x = 0`
mixes row-1 texel `32'h01020304` with row-2 texel `32'hF0F0F0F0`,
giving `32'h79797A7A`. `x = 1` is `32'h42424343`. `x = 7` is
`32'h3C3C3C3C`. `x = 0` and `x = 1` must reproduce the stored `y = 1`
samples from the row-1 texels. `y = 1`, `y` above 2, and `x` above 7
record nothing. The image is not stored. TEX is not executed. `Y2bEn`
defaults to 0 and does not make virgl legal. The unit is not on the
testharness flist. Remote 2026-09-23, one run shared with the pair:
`tb_g6lc_apu_vgpu_y2b` 12 cases / 55 checks / 73 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 29 ports and no cells; Enable=1
is 3,300 cells / 116 flip-flops. The CVA6 cookie was not re-run. The
TEX opcode still returns `-26`.

`g6lc_apu_vgpu_y2r` keeps those two words. `x = 0` must differ from the
`y = 1` sample `32'h53010202`. `x = 1` must differ from `32'h6B024303`.
A third record keeps the pair. `Y2rEn` defaults to 0 and does not make
virgl legal. The unit is not on the testharness flist. The same remote
run, `tb_g6lc_apu_vgpu_y2b`, errors=0. Fixture synth, no latches:
Enable=0 is 11 ports and no cells; Enable=1 is 241 cells / 71
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_smp` samples any point of the 64 by 64 ceiling from the
copied band. `s = x - 1/2` and `t = y - 1/2`. `x = 0` clamps to texel
0 and `y = 0` clamps to row 0. A beat holds eight texels. Points
already stored must match: `(0,0)` is `32'hA5000000`, `(1,0)` is
`32'hD2008000`, `(8,0)` is `32'h8091A2B3`, `(0,1)` is `32'h53010202`,
`(1,1)` is `32'h6B024303`, `(2,1)` is `32'h42024203`, `(8,1)` is
`32'h434C545D`, `(0,2)` is `32'h79797A7A`, and `(1,2)` is
`32'h42424343`. `(9,0)` is `32'h555E666F`. `(8,2)` is `32'h17171718`.
`(0,3)` is `32'h78787878`. `(63,63)` is `32'h0` because those texels
are 0. `x` or `y` above 63 records nothing. The image is not stored.
One remote run checked all 4,096 points. TEX is not executed. `SmpEn`
defaults to 0 and does not make virgl legal. The unit is not on the
testharness flist. Remote 2026-09-23, one run shared with the store:
`tb_g6lc_apu_vgpu_smp` 4,117 cases / 16,472 checks / 38,678 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 30 ports and no
cells; Enable=1 is 4,351 cells / 221 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_smx` keeps the sample at `(0,3)`. A second store keeps
the first. The earlier samples stay put. `SmxEn` defaults to 0 and
does not make virgl legal. The unit is not on the testharness flist.
The same remote run, `tb_g6lc_apu_vgpu_smp`, errors=0. Fixture synth,
no latches: Enable=0 is 10 ports and no cells; Enable=1 is 204 cells /
37 flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_rbf` writes that ceiling to `32'h88040000`. Eight
samples fill one beat. The walk is 512 beats, 16,384 bytes. The last
beat is at `64'h88043FE0`. Beat 0 is row 0, `x = 0..7`: `32'hA5000000`,
`32'hD2008000`, `32'h80018001`, `32'h02020202`, `32'h03030303`,
`32'h04040404`, `32'h0B131C24`, `32'h33445566`. Beat 24, which is
`y = 3`, starts with `32'h78787878`. The last beat is `32'h0`. The
unit keeps the beat it is writing, not the image. A failed sample
writes nothing. A failed beat can be repeated from the start. This is
not `32'h8800C000` and not the texture. TEX is not executed. `RbfEn`
defaults to 0 and does not make virgl legal. The unit is not on the
testharness flist. Remote 2026-09-23, one run shared with the record:
`tb_g6lc_apu_vgpu_rbf` 7 cases / 35 checks / 39,646 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 37 ports and no cells; Enable=1
is 5,129 cells / 620 flip-flops, and that count includes the sampler.
The CVA6 cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_rbk` keeps the byte count, the first word, and the last
address. A second store keeps the first. The image is not kept.
`RbkEn` defaults to 0 and does not make virgl legal. The unit is not
on the testharness flist. The same remote run, `tb_g6lc_apu_vgpu_rbf`,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and no
cells; Enable=1 is 318 cells / 111 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_rdr` reads those 512 beats back from `32'h88040000`.
Beat 0's low word must be the stored first word, `32'hA5000000`. Beat
24's low word must be the stored `(0,3)` sample, `32'h78787878`. The
last beat is at `64'h88043FE0`. The image is not kept. A failed beat
stops the walk and the request can be repeated. A beat 0 word that
does not match the record is refused. TEX is not executed. `RdrEn`
defaults to 0 and does not make virgl legal. The unit is not on the
testharness flist. Remote 2026-09-23, one run shared with the pair:
`tb_g6lc_apu_vgpu_rdr` 7 cases / 30 checks / 1,066 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 20 ports and no cells; Enable=1
is 909 cells / 147 flip-flops. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vgpu_rdk` keeps those two words. They must differ. A second
store keeps the first. `RdkEn` defaults to 0 and does not make virgl
legal. The unit is not on the testharness flist. The same remote run,
`tb_g6lc_apu_vgpu_rdr`, errors=0. Fixture synth, no latches: Enable=0
is 11 ports and no cells; Enable=1 is 298 cells / 69 flip-flops. The
CVA6 cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_fet` reads the guest bytes named by the accepted scene
chain. The header is one beat at `64'h8800A000`: type `SUBMIT_3D`
(`32'h00000207`), context 1, size 960. The execbuffer is 30 beats at
`64'h8800B000`. Its first word is `32'h00050801`, the surface
`CREATE_OBJECT` with 5 body dwords. The last beat is at `64'h8800B3A0`.
The 960 bytes are not kept. The response at `64'h8800A800` is not
read. This is not `g6lc_apu_vgpu_avail`, and that walker still rejects
`NEXT`. A failed beat stops the fetch. TEX is not executed. `FetEn`
defaults to 0 and does not make virgl legal. The unit is not on the
testharness flist. Remote 2026-09-23, one run shared with the record:
`tb_g6lc_apu_vgpu_fet` 8 cases / 33 checks / 113 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 19 ports and no cells; Enable=1
is 834 cells / 81 flip-flops. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vgpu_fek` keeps the submit type and that first command word.
A second store keeps the first. `FekEn` defaults to 0 and does not
make virgl legal. The unit is not on the testharness flist. The same
remote run, `tb_g6lc_apu_vgpu_fet`, errors=0. Fixture synth, no
latches: Enable=0 is 10 ports and no cells; Enable=1 is 210 cells /
69 flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_drd` reads the `DRAW_VBO` at byte 908 of the execbuffer
`g6lc_apu_vgpu_fet` already accepted. Beat 28 at `64'h8800B380` carries
the header in bits `[127:96]`: `32'h000C0008`, twelve body dwords,
object 0, opcode 8. The next words are start 0, count 4, triangle
strip 5, and indexed 0. Beat 29 at `64'h8800B3A0` carries one instance
and max index 3. The low twelve bytes of beat 28 are the clear tail
and are not part of this command. The 960 bytes are not kept. The
draw is not executed. This is not `g6lc_apu_vgpu_drw`, and
`g6lc_apu_vgpu_avail` still rejects `NEXT`. A failed beat stops the
read and the request can be repeated. TEX is not executed. `DrdEn`
defaults to 0 and does not make virgl legal. The unit is not on the
testharness flist. Remote 2026-09-23, one run shared with the record:
`tb_g6lc_apu_vgpu_drd` 13 cases / 59 checks / 81 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 19 ports and no cells; Enable=1
is 839 cells / 139 flip-flops. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vgpu_drk` keeps the vertex count and the triangle-strip
primitive. A second store keeps the first. The draw is not executed.
`DrkEn` defaults to 0 and does not make virgl legal. The unit is not
on the testharness flist. The same remote run, `tb_g6lc_apu_vgpu_drd`,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and no
cells; Enable=1 is 241 cells / 69 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_qdr` reads the 24 NDC floats the recognized draw names.
They start at byte 696. Beat 21 at `64'h8800B2A0` holds the inline-write
length 96 and the first two floats. Beats 22 and 23 hold the middle
sixteen. Beat 24 at `64'h8800B300` holds the last six. Each vertex is
`{x, y, 0, 1, u, v}`. The corners are `(-1,-1)`, `(1,-1)`, `(-1,1)`,
and `(1,1)`. The first float is `32'hbf800000` and the last is
`32'h3f800000`. The 96 bytes are not kept. The vertex-buffer command
that follows the floats is not part of this read. This does not
transform a vertex and does not execute the draw. This is not
`g6lc_apu_vgpu_qd`, and `g6lc_apu_vgpu_avail` still rejects `NEXT`.
A failed beat stops the read and the request can be repeated. TEX is
not executed. `QdrEn` defaults to 0 and does not make virgl legal.
The unit is not on the testharness flist. Remote 2026-09-23, one run
shared with the record: `tb_g6lc_apu_vgpu_qdr` 14 cases / 63 checks /
97 clocks, errors=0. Fixture synth, no latches: Enable=0 is 20 ports
and no cells; Enable=1 is 1,109 cells / 143 flip-flops. The CVA6
cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_qdk` keeps the first float and the last float. They
differ. A second store keeps the first. The floats are not transformed.
`QdkEn` defaults to 0 and does not make virgl legal. The unit is not
on the testharness flist. The same remote run, `tb_g6lc_apu_vgpu_qdr`,
errors=0. Fixture synth, no latches: Enable=0 is 11 ports and no
cells; Enable=1 is 387 cells / 69 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_vwx` reads the `SET_VIEWPORT` at byte 824 of the
execbuffer whose draw and NDC floats are already accepted. Beat 25 at
`64'h8800B320` carries the header in bits `[223:192]`: `32'h00070004`,
seven body dwords, object 0, opcode 4. Beat 26 at `64'h8800B340`
carries scale `32'h43a00000` (320), scale `32'h43700000` (240), then
1, 320, 240, and 0. The frozen square is ndc ±1, so
`x = ndc_x*320+320` and `y = ndc_y*240+240` land on 0 and 640, 0 and
480. Those integers are the record. This is not a floating-point
multiply and not a rasterizer. The low 24 bytes of beat 25 are the
scissor and are not part of this command. This is not
`g6lc_apu_vgpu_vp`, and `g6lc_apu_vgpu_avail` still rejects `NEXT`.
A failed beat stops the read and the request can be repeated. TEX is
not executed. `VwxEn` defaults to 0 and does not make virgl legal.
The unit is not on the testharness flist. Remote 2026-09-23, one run
shared with the record: `tb_g6lc_apu_vgpu_vwx` 13 cases / 59 checks /
80 clocks, errors=0. Fixture synth, no latches: Enable=0 is 21 ports
and no cells; Enable=1 is 1,000 cells / 140 flip-flops. The CVA6
cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_vwk` keeps the scales and the window edges. 640 and 480
differ. A second store keeps the first. This is not a transform.
`VwkEn` defaults to 0 and does not make virgl legal. The unit is not
on the testharness flist. The same remote run, `tb_g6lc_apu_vgpu_vwx`,
errors=0. Fixture synth, no latches: Enable=0 is 12 ports and no
cells; Enable=1 is 566 cells / 133 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_cxr` reads the `SET_SCISSOR` at byte 808. The command
shares beat 25 at `64'h8800B320` with the viewport. The header is in
bits `[95:64]`: `32'h0003000F`, three body dwords, object 0, opcode 15.
The box is `32'h01E00280`, width 640 and height 480. The window edges
are 0 and 640, 0 and 480, so the scissor and the window are the same
rectangle. No pixel is clipped. The vertex-buffer tail and the viewport
header in that beat are not part of this command. This is not
`g6lc_apu_vgpu_sci`, and `g6lc_apu_vgpu_avail` still rejects `NEXT`.
A failed beat stops the read and the request can be repeated. TEX is
not executed. `CxrEn` defaults to 0 and does not make virgl legal.
The unit is not on the testharness flist. Remote 2026-09-23, one run
shared with the record: `tb_g6lc_apu_vgpu_cxr` 13 cases / 59 checks /
71 clocks, errors=0. Fixture synth, no latches: Enable=0 is 22 ports
and no cells; Enable=1 is 851 cells / 73 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_cxk` keeps the width and the height. They differ. A
second store keeps the first. No pixel is clipped. `CxkEn` defaults
to 0 and does not make virgl legal. The unit is not on the testharness
flist. The same remote run, `tb_g6lc_apu_vgpu_cxr`, errors=0. Fixture
synth, no latches: Enable=0 is 13 ports and no cells; Enable=1 is
461 cells / 37 flip-flops. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vgpu_cwr` reads the `CLEAR` at byte 872 of the execbuffer
whose scissor matches the window. Beat 27 at `64'h8800B360` carries
the header in bits `[95:64]`: `32'h00080007`, eight body dwords,
object 0, opcode 7. The color floats are `32'h3d4ccccd`,
`32'h3d4ccccd`, `32'h3dcccccd`, and `32'h3f800000`. Beat 28 at
`64'h8800B380` carries depth `32'h3ff00000` and is also the draw beat.
The packed word of those floats is `32'hFF1A0D0D`, byte 0 red. This
does not convert a float and does not write a pixel. The framebuffer
tail in beat 27 and the draw header in beat 28 are not part of this
command. This is not `g6lc_apu_vgpu_clr`, and `g6lc_apu_vgpu_avail`
still rejects `NEXT`. A failed beat stops the read and the request
can be repeated. TEX is not executed. `CwrEn` defaults to 0 and does
not make virgl legal. The unit is not on the testharness flist.
Remote 2026-09-23, one run shared with the record:
`tb_g6lc_apu_vgpu_cwr` 13 cases / 59 checks / 78 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 23 ports and no cells;
Enable=1 is 1,185 cells / 140 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_cwk` keeps the red, the blue, and the packed word. Red
and blue differ. A second store keeps the first. No pixel is written.
`CwkEn` defaults to 0 and does not make virgl legal. The unit is not
on the testharness flist. The same remote run, `tb_g6lc_apu_vgpu_cwr`,
errors=0. Fixture synth, no latches: Enable=0 is 11 ports and no
cells; Enable=1 is 524 cells / 101 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_fbr` reads the `SET_FRAMEBUFFER` at byte 856 of the
execbuffer whose clear color is already accepted. Beat 26 at
`64'h8800B340` carries the header in bits `[223:192]`:
`32'h00030005`, three body dwords, object 0, opcode 5, and one color
buffer in bits `[255:224]`. Beat 27 at `64'h8800B360` carries a zero
and surface handle 1. The accepted clear word `32'hFF1A0D0D` stays
with that surface. This does not attach memory and does not write a
pixel. The viewport body in beat 26 and the clear in beat 27 are not
part of this command. This is not `g6lc_apu_vgpu_fbo`, and
`g6lc_apu_vgpu_avail` still rejects `NEXT`. A failed beat stops the
read and the request can be repeated. TEX is not executed. `FbrEn`
defaults to 0 and does not make virgl legal. The unit is not on the
testharness flist. Remote 2026-09-23, one run shared with the record:
`tb_g6lc_apu_vgpu_fbr` 13 cases / 59 checks / 78 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 24 ports and no cells;
Enable=1 is 1,130 cells / 171 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_fbk` keeps the color-buffer count, the surface handle,
and the clear word. The word and the handle differ. A second store
keeps the first. No memory is attached. `FbkEn` defaults to 0 and
does not make virgl legal. The unit is not on the testharness flist.
The same remote run, `tb_g6lc_apu_vgpu_fbr`, errors=0. Fixture synth,
no latches: Enable=0 is 11 ports and no cells; Enable=1 is 452 cells
/ 101 flip-flops. The CVA6 cookie was not re-run. The TEX opcode
still returns `-26`.

`g6lc_apu_vgpu_vbf` reads the `SET_VERTEX_BUFFERS` at byte 792 of the
execbuffer whose framebuffer is already accepted. Beat 24 at
`64'h8800B300` carries the header in bits `[223:192]`:
`32'h00030006`, three body dwords, object 0, opcode 6, and stride 24
in bits `[255:224]`. Beat 25 at `64'h8800B320` carries offset 0 and
resource 3. This does not fetch vertices. The last quad float in
beat 24 and the scissor in beat 25 are not part of this command.
This is not `g6lc_apu_vgpu_vb`, and `g6lc_apu_vgpu_avail` still
rejects `NEXT`. A failed beat stops the read and the request can be
repeated. TEX is not executed. `VbfEn` defaults to 0 and does not
make virgl legal. The unit is not on the testharness flist. Remote
2026-09-23, one run shared with the record: `tb_g6lc_apu_vgpu_vbf`
14 cases / 63 checks / 87 clocks, errors=0. Fixture synth, no
latches: Enable=0 is 25 ports and no cells; Enable=1 is 1,246 cells
/ 203 flip-flops. The CVA6 cookie was not re-run. The TEX opcode
still returns `-26`.

`g6lc_apu_vgpu_vbk` keeps the stride, the offset, and the resource.
Stride 24 and resource 3 differ. A second store keeps the first.
No vertices are fetched. `VbkEn` defaults to 0 and does not make
virgl legal. The unit is not on the testharness flist. The same
remote run, `tb_g6lc_apu_vgpu_vbf`, errors=0. Fixture synth, no
latches: Enable=0 is 11 ports and no cells; Enable=1 is 452 cells /
101 flip-flops. The CVA6 cookie was not re-run. The TEX opcode
still returns `-26`.

`g6lc_apu_vgpu_iwr` reads the `INLINE_WRITE` at byte 648 that holds
the quad already accepted. Beat 20 at `64'h8800B280` carries the
header in bits `[95:64]`: `32'h00230009`, 35 body dwords, object 0,
opcode 9, and resource 3. Beat 21 at `64'h8800B2A0` carries the
length 96 and the first float `32'hbf800000`. The 96 bytes are not
kept. This does not fetch vertices. The sampler-view handle in beat
20 and the second float in beat 21 are not part of this check. This
is not `g6lc_apu_vgpu_iw`, and `g6lc_apu_vgpu_avail` still rejects
`NEXT`. A failed beat stops the read and the request can be repeated.
TEX is not executed. `IwrEn` defaults to 0 and does not make virgl
legal. The unit is not on the testharness flist. Remote 2026-09-23,
one run shared with the record: `tb_g6lc_apu_vgpu_iwr` 13 cases /
59 checks / 78 clocks, errors=0. Fixture synth, no latches: Enable=0
is 26 ports and no cells; Enable=1 is 1,405 cells / 139 flip-flops.
The CVA6 cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_iwk` keeps the resource and the byte count. They
differ, and the resource matches the vertex-buffer set. A second
store keeps the first. The floats are not here. `IwkEn` defaults to
0 and does not make virgl legal. The unit is not on the testharness
flist. The same remote run, `tb_g6lc_apu_vgpu_iwr`, errors=0. Fixture
synth, no latches: Enable=0 is 12 ports and no cells; Enable=1 is
449 cells / 69 flip-flops. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vgpu_svr` reads `SET_SAMPLER_VIEWS` at byte 632 after the
inline write is accepted. Beat 19 at `64'h8800B260` carries the header
in bits `[223:192]`: `32'h0003000A`, three body dwords, object 0,
opcode 10, and the fragment stage in bits `[255:224]`. Beat 20 at
`64'h8800B280` carries slot 0 and sampler-view handle 5. No texture
is bound. The sampler-state handle in beat 19 and the inline-write
header in beat 20 are not part of this check. This is not
`g6lc_apu_vgpu_svb`, and `g6lc_apu_vgpu_avail` still rejects `NEXT`.
A failed beat stops the read and the request can be repeated. TEX is
not executed. `SvrEn` defaults to 0 and does not make virgl legal.
The unit is not on the testharness flist. Remote 2026-09-23, one run
shared with the record: `tb_g6lc_apu_vgpu_svr` 15 cases / 67 checks /
91 clocks, errors=0. Fixture synth, no latches: Enable=0 is 27 ports
and no cells; Enable=1 is 1,644 cells / 204 flip-flops. The CVA6
cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_svk` keeps the stage, the slot, and the handle. They
differ. A second store keeps the first. No texture is bound. `SvkEn`
defaults to 0 and does not make virgl legal. The unit is not on the
testharness flist. The same remote run, `tb_g6lc_apu_vgpu_svr`,
errors=0. Fixture synth, no latches: Enable=0 is 12 ports and no
cells; Enable=1 is 612 cells / 101 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_ssr` reads `BIND_SAMPLER_STATES` at byte 616 after the
sampler view is accepted. The command shares beat 19 at
`64'h8800B260`. Bits `[95:64]` are the header `32'h00030012`, three
body dwords, object 0, opcode 18. Bits `[127:96]` are the fragment
stage, `[159:128]` is slot 0, and `[191:160]` is sampler-state
handle 6. No texture is bound. The vertex-element bind and the
sampler-view header in that beat are not part of this check. This
is not `g6lc_apu_vgpu_ssb`, and `g6lc_apu_vgpu_avail` still rejects
`NEXT`. A failed beat stops the read and the request can be repeated.
TEX is not executed. `SsrEn` defaults to 0 and does not make virgl
legal. The unit is not on the testharness flist. Remote 2026-09-23,
one run shared with the record: `tb_g6lc_apu_vgpu_ssr` 15 cases /
67 checks / 85 clocks, errors=0. Fixture synth, no latches: Enable=0
is 28 ports and no cells; Enable=1 is 1,926 cells / 201 flip-flops.
The CVA6 cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_ssk` keeps the stage, the slot, and the handle. They
differ, and the handle is not the sampler-view handle. A second store
keeps the first. No texture is bound. `SskEn` defaults to 0 and does
not make virgl legal. The unit is not on the testharness flist. The
same remote run, `tb_g6lc_apu_vgpu_ssr`, errors=0. Fixture synth, no
latches: Enable=0 is 13 ports and no cells; Enable=1 is 778 cells /
101 flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_ver` reads the vertex-element `BIND_OBJECT` at byte 608
after the sampler state is accepted. The command is the first eight
bytes of beat 19 at `64'h8800B260`. Bits `[31:0]` are the header
`32'h00010502`: one body dword, object 5, opcode 2. Bits `[63:32]`
are handle 4. No vertices are fetched. The sampler-state words in
that beat are not part of this check. This is not
`g6lc_apu_vgpu_veb`, and `g6lc_apu_vgpu_avail` still rejects `NEXT`.
A failed beat stops the read and the request can be repeated. TEX is
not executed. `VerEn` defaults to 0 and does not make virgl legal.
The unit is not on the testharness flist. Remote 2026-09-23, one run
shared with the record: `tb_g6lc_apu_vgpu_ver` 13 cases / 59 checks /
71 clocks, errors=0. Fixture synth, no latches: Enable=0 is 29 ports
and no cells; Enable=1 is 1,965 cells / 137 flip-flops. The CVA6
cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_vek` keeps the header and the handle. They differ, and
the handle is not the sampler-state handle. A second store keeps the
first. No vertices are fetched. `VekEn` defaults to 0 and does not
make virgl legal. The unit is not on the testharness flist. The same
remote run, `tb_g6lc_apu_vgpu_ver`, errors=0. Fixture synth, no
latches: Enable=0 is 13 ports and no cells; Enable=1 is 651 cells /
69 flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_fsr` reads the fragment `BIND_SHADER` at byte 596 after
the vertex elements are accepted. The command is the last twelve
bytes of beat 18 at `64'h8800B240`. Bits `[191:160]` are the header
`32'h0002001F`: two body dwords, object 0, opcode 31. Bits `[223:192]`
are handle 3 and `[255:224]` is the fragment stage. The shader is not
run. The vertex-shader words in that beat are not part of this check.
This is not `g6lc_apu_vgpu_fsb`, and `g6lc_apu_vgpu_avail` still
rejects `NEXT`. A failed beat stops the read and the request can be
repeated. TEX is not executed. `FsrEn` defaults to 0 and does not make
virgl legal. The unit is not on the testharness flist. Remote
2026-09-23, one run shared with the record: `tb_g6lc_apu_vgpu_fsr`
14 cases / 63 checks / 78 clocks, errors=0. Fixture synth, no
latches: Enable=0 is 30 ports and no cells; Enable=1 is 2,141 cells /
137 flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_fsk` keeps the handle and the stage. They differ, and
the handle is not the vertex-shader handle or the vertex-element
handle. A second store keeps the first. The shader is not run.
`FskEn` defaults to 0 and does not make virgl legal. The unit is not
on the testharness flist. The same remote run, `tb_g6lc_apu_vgpu_fsr`,
errors=0. Fixture synth, no latches: Enable=0 is 13 ports and no
cells; Enable=1 is 691 cells / 69 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_vsr` reads the vertex `BIND_SHADER` at byte 584 after
the fragment shader is accepted. The command shares beat 18 at
`64'h8800B240`. Bits `[95:64]` are the header `32'h0002001F`: two
body dwords, object 0, opcode 31. Bits `[127:96]` are handle 2 and
`[159:128]` is the vertex stage. The shader is not run. The
fragment-shader words in that beat are not part of this check. This
is not `g6lc_apu_vgpu_vsb`, and `g6lc_apu_vgpu_avail` still rejects
`NEXT`. A failed beat stops the read and the request can be repeated.
TEX is not executed. `VsrEn` defaults to 0 and does not make virgl
legal. The unit is not on the testharness flist. Remote 2026-09-23,
one run shared with the record: `tb_g6lc_apu_vgpu_vsr` 14 cases /
63 checks / 78 clocks, errors=0. Fixture synth, no latches: Enable=0
is 31 ports and no cells; Enable=1 is 2,401 cells / 137 flip-flops.
The CVA6 cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_vsk` keeps the handle and the stage. They differ, and
the handle is not the fragment-shader handle. A second store keeps
the first. The shader is not run. `VskEn` defaults to 0 and does not
make virgl legal. The unit is not on the testharness flist. The same
remote run, `tb_g6lc_apu_vgpu_vsr`, errors=0. Fixture synth, no
latches: Enable=0 is 13 ports and no cells; Enable=1 is 745 cells /
69 flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_rzr` reads the rasterizer `BIND_OBJECT` at byte 576
after the vertex shader is accepted. The command is the first eight
bytes of beat 18 at `64'h8800B240`. Bits `[31:0]` are the header
`32'h00010202`: one body dword, object 2, opcode 2. Bits `[63:32]`
are handle 9. No triangle is walked. The vertex-shader words in that
beat are not part of this check. This is not `g6lc_apu_vgpu_rb`, and
`g6lc_apu_vgpu_avail` still rejects `NEXT`. A failed beat stops the
read and the request can be repeated. TEX is not executed. `RzrEn`
defaults to 0 and does not make virgl legal. The unit is not on the
testharness flist. Remote 2026-09-23, one run shared with the record:
`tb_g6lc_apu_vgpu_rzr` 13 cases / 59 checks / 71 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 32 ports and no cells;
Enable=1 is 2,568 cells / 137 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_rzk` keeps the header and the handle. They differ, and
the handle is not the vertex-shader handle. A second store keeps the
first. No triangle is walked. `RzkEn` defaults to 0 and does not make
virgl legal. The unit is not on the testharness flist. The same
remote run, `tb_g6lc_apu_vgpu_rzr`, errors=0. Fixture synth, no
latches: Enable=0 is 13 ports and no cells; Enable=1 is 682 cells /
69 flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_dbr` reads the depth-stencil `BIND_OBJECT` at byte 568
after the rasterizer is accepted. The command is the last eight bytes
of beat 17 at `64'h8800B220`. Bits `[223:192]` are the header
`32'h00010302`: one body dword, object 3, opcode 2. Bits `[255:224]`
are handle 8. No depth test is run. The blend bind in that beat is
not part of this check. This is not `g6lc_apu_vgpu_db`, and
`g6lc_apu_vgpu_avail` still rejects `NEXT`. A failed beat stops the
read and the request can be repeated. TEX is not executed. `DbrEn`
defaults to 0 and does not make virgl legal. The unit is not on the
testharness flist. Remote 2026-09-23, one run shared with the record:
`tb_g6lc_apu_vgpu_dbr` 13 cases / 59 checks / 71 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 33 ports and no cells;
Enable=1 is 2,769 cells / 137 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_dbk` keeps the header and the handle. They differ, and
the handle is not the rasterizer handle. A second store keeps the
first. No depth test is run. `DbkEn` defaults to 0 and does not make
virgl legal. The unit is not on the testharness flist. The same
remote run, `tb_g6lc_apu_vgpu_dbr`, errors=0. Fixture synth, no
latches: Enable=0 is 13 ports and no cells; Enable=1 is 686 cells /
69 flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_bbr` reads the blend `BIND_OBJECT` at byte 560 after
the depth-stencil bind is accepted. The command is eight bytes,
sixteen bytes into beat 17 at `64'h8800B220`. Bits `[159:128]` are
the header `32'h00010102`: one body dword, object 1, opcode 2. Bits
`[191:160]` are handle 7. No blend is applied. The depth-stencil
words in that beat are not part of this check. This is not
`g6lc_apu_vgpu_bb`, and `g6lc_apu_vgpu_avail` still rejects `NEXT`.
A failed beat stops the read and the request can be repeated. TEX is
not executed. `BbrEn` defaults to 0 and does not make virgl legal.
The unit is not on the testharness flist. Remote 2026-09-23, one run
shared with the record: `tb_g6lc_apu_vgpu_bbr` 13 cases / 59 checks /
71 clocks, errors=0. Fixture synth, no latches: Enable=0 is 34 ports
and no cells; Enable=1 is 2,972 cells / 137 flip-flops. The CVA6
cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_bbk` keeps the header and the handle. They differ, and
the handle is not the depth-stencil handle. A second store keeps the
first. No blend is applied. `BbkEn` defaults to 0 and does not make
virgl legal. The unit is not on the testharness flist. The same
remote run, `tb_g6lc_apu_vgpu_bbr`, errors=0. Fixture synth, no
latches: Enable=0 is 13 ports and no cells; Enable=1 is 687 cells /
69 flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_rcr` reads the rasterizer `CREATE_OBJECT` at byte 520
after the blend bind is accepted. Beat 16 at `64'h8800B200` carries
the header `32'h00090201` and handle 9, then the first four state
words. Beat 17 at `64'h8800B220` carries the last four. All eight
state words are 0 and are not kept. No triangle is walked. The
depth-stencil tail in beat 16 and the blend bind in beat 17 are not
part of this check. This is not `g6lc_apu_vgpu_rz`, and
`g6lc_apu_vgpu_avail` still rejects `NEXT`. A failed beat stops the
read and the request can be repeated. TEX is not executed. `RcrEn`
defaults to 0 and does not make virgl legal. The unit is not on the
testharness flist. Remote 2026-09-23, one run shared with the record:
`tb_g6lc_apu_vgpu_rcr` 15 cases / 67 checks / 89 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 35 ports and no cells;
Enable=1 is 3,536 cells / 139 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_rck` keeps the header and the handle. They differ, and
the handle is not the blend handle. A second store keeps the first.
The eight state words are not kept. No triangle is walked. `RckEn`
defaults to 0 and does not make virgl legal. The unit is not on the
testharness flist. The same remote run, `tb_g6lc_apu_vgpu_rcr`,
errors=0. Fixture synth, no latches: Enable=0 is 13 ports and no
cells; Enable=1 is 700 cells / 69 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_dcr` reads the depth-stencil `CREATE_OBJECT` at byte
496 after the rasterizer object is accepted. Beat 15 at
`64'h8800B1E0` carries the header `32'h00050301`, handle 8, and the
first two state words. Beat 16 at `64'h8800B200` carries the last
two. All four state words are 0 and are not kept. No depth test is
run. The blend tail in beat 15 and the rasterizer object in beat 16
are not part of this check. This is not `g6lc_apu_vgpu_ds`, and
`g6lc_apu_vgpu_avail` still rejects `NEXT`. A failed beat stops the
read and the request can be repeated. TEX is not executed. `DcrEn`
defaults to 0 and does not make virgl legal. The unit is not on the
testharness flist. Remote 2026-09-23, one run shared with the record:
`tb_g6lc_apu_vgpu_dcr` 15 cases / 67 checks / 89 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 36 ports and no cells;
Enable=1 is 3,734 cells / 140 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_dck` keeps the header and the handle. They differ, and
the handle is not the rasterizer handle. A second store keeps the
first. The four state words are not kept. No depth test is run.
`DckEn` defaults to 0 and does not make virgl legal. The unit is not
on the testharness flist. The same remote run,
`tb_g6lc_apu_vgpu_dcr`, errors=0. Fixture synth, no latches:
Enable=0 is 13 ports and no cells; Enable=1 is 700 cells / 69
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_blr` reads the blend `CREATE_OBJECT` at byte 448 after
the depth-stencil object is accepted. Beat 14 at `64'h8800B1C0`
carries the header `32'h000B0101`, handle 7, and color word
`32'h78020010`. Beat 15 at `64'h8800B1E0` carries the last four body
words, and they are 0. Those zero words are not kept. No blend is
applied. The depth-stencil object in beat 15 is not part of this
check. This is not `g6lc_apu_vgpu_bl`, and `g6lc_apu_vgpu_avail` still
rejects `NEXT`. A failed beat stops the read and the request can be
repeated. TEX is not executed. `BlrEn` defaults to 0 and does not make
virgl legal. The unit is not on the testharness flist. Remote
2026-09-23, one run shared with the record: `tb_g6lc_apu_vgpu_blr` 16
cases / 71 checks / 96 clocks, errors=0. Fixture synth, no latches:
Enable=0 is 37 ports and no cells; Enable=1 is 4,308 cells / 203
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_blk` keeps the header, the handle, and the color word.
They stay distinct, and the handle is not the depth-stencil handle. A
second store keeps the first. The zero body words are not kept. No
blend is applied. `BlkEn` defaults to 0 and does not make virgl legal.
The unit is not on the testharness flist. The same remote run,
`tb_g6lc_apu_vgpu_blr`, errors=0. Fixture synth, no latches:
Enable=0 is 13 ports and no cells; Enable=1 is 838 cells / 101
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_scr` reads the sampler-state `CREATE_OBJECT` at byte
408 after the blend object is accepted. Beat 12 at `64'h8800B180`
carries the header `32'h00090701` and handle 6. Beat 13 at
`64'h8800B1A0` carries wrap word `32'h00002292` and max LOD
`32'h42000000`. The other body words are 0 and are not kept. No
texture is bound. The sampler-view tail in beat 12 is not part of
this check. This is not `g6lc_apu_vgpu_ss`, and `g6lc_apu_vgpu_avail`
still rejects `NEXT`. A failed beat stops the read and the request
can be repeated. TEX is not executed. `ScrEn` defaults to 0 and does
not make virgl legal. The unit is not on the testharness flist.
Remote 2026-09-23, one run shared with the record:
`tb_g6lc_apu_vgpu_scr` 17 cases / 75 checks / 109 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 38 ports and no cells;
Enable=1 is 4,899 cells / 267 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_sck` keeps the header, the handle, the wrap word, and
the max LOD. The handle is not the blend handle. A second store keeps
the first. The zero body words are not kept. No texture is bound.
`SckEn` defaults to 0 and does not make virgl legal. The unit is not
on the testharness flist. The same remote run,
`tb_g6lc_apu_vgpu_scr`, errors=0. Fixture synth, no latches:
Enable=0 is 13 ports and no cells; Enable=1 is 951 cells / 133
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_svc` reads the sampler-view `CREATE_OBJECT` at byte
380 after the sampler-state object is accepted. Beat 11 at
`64'h8800B160` carries the header `32'h00060601`. Beat 12 at
`64'h8800B180` carries handle 5, resource 1, format word
`32'h02000002`, and swizzle `32'h00000688`. Two body words are 0 and
are not kept. No texture is bound. The vertex-element tail in beat
11 and the sampler-state words in beat 12 are not part of this check.
This is not `g6lc_apu_vgpu_sv`, and `g6lc_apu_vgpu_avail` still
rejects `NEXT`. A failed beat stops the read and the request can be
repeated. TEX is not executed. `SvcEn` defaults to 0 and does not
make virgl legal. The unit is not on the testharness flist. Remote
2026-09-23, one run shared with the record: `tb_g6lc_apu_vgpu_svc` 18
cases / 79 checks / 120 clocks, errors=0. Fixture synth, no latches:
Enable=0 is 39 ports and no cells; Enable=1 is 5,267 cells / 332
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_vck` keeps the header, the handle, the resource, the
format word, and the swizzle. The handle is not the sampler-state
handle. A second store keeps the first. The zero body words are not
kept. No texture is bound. `VckEn` defaults to 0 and does not make
virgl legal. The unit is not on the testharness flist. The same
remote run, `tb_g6lc_apu_vgpu_svc`, errors=0. Fixture synth, no
latches: Enable=0 is 13 ports and no cells; Enable=1 is 1,046 cells
/ 165 flip-flops. The CVA6 cookie was not re-run. The TEX opcode
still returns `-26`.

`g6lc_apu_vgpu_vec` reads the vertex-element `CREATE_OBJECT` at byte
340 after the sampler view is accepted. Beat 10 at `64'h8800B140`
carries the header `32'h00090501`, handle 4, and offset 0. Beat 11
at `64'h8800B160` carries format 31, offset 16, and format 29. Four
divisor words are 0 and are not kept. No vertices are fetched. The
shader text in beat 10 and the sampler-view header in beat 11 are
not part of this check. This is not `g6lc_apu_vgpu_ve`, and
`g6lc_apu_vgpu_avail` still rejects `NEXT`. A failed beat stops the
read and the request can be repeated. TEX is not executed. `VecEn`
defaults to 0 and does not make virgl legal. The unit is not on the
testharness flist. Remote 2026-09-23, one run shared with the record:
`tb_g6lc_apu_vgpu_vec` 19 cases / 83 checks / 125 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 40 ports and no cells;
Enable=1 is 5,868 cells / 395 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_vce` keeps the header, the handle, and the two offsets
and formats. The handle is not the sampler-view handle. A second
store keeps the first. The divisor words are not kept. No vertices
are fetched. `VceEn` defaults to 0 and does not make virgl legal. The
unit is not on the testharness flist. The same remote run,
`tb_g6lc_apu_vgpu_vec`, errors=0. Fixture synth, no latches:
Enable=0 is 13 ports and no cells; Enable=1 is 1,135 cells / 197
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_fsc` reads the fragment-shader `CREATE_OBJECT` at byte
176 after the vertex-element object is accepted. Beat 5 at
`64'h8800B0A0` carries the header `32'h00280401`, handle 3, the
fragment stage, and length 140. Beat 6 at `64'h8800B0C0` carries
token count 300, a zero stream-out word, and text dword
`32'h47415246`. The rest of the text stays in the execbuffer. The
shader is not run. This is not `g6lc_apu_vgpu_fs`, and
`g6lc_apu_vgpu_avail` still rejects `NEXT`. A failed beat stops the
read and the request can be repeated. TEX is not executed. `FscEn`
defaults to 0 and does not make virgl legal. The unit is not on the
testharness flist. Remote 2026-09-23, one run shared with the vertex
shader, the surface, and the three records: `tb_g6lc_apu_vgpu_obj`
53 cases / 221 checks / 317 clocks, errors=0. Fixture synth, no
latches: Enable=0 is 41 ports and no cells; Enable=1 is 6,794 cells
/ 396 flip-flops. The CVA6 cookie was not re-run. The TEX opcode
still returns `-26`.

`g6lc_apu_vgpu_fce` keeps the header, the handle, the stage, the
length, the token count, and the first text dword. A second store
keeps the first. The rest of the text is not kept. The shader is not
run. `FceEn` defaults to 0 and does not make virgl legal. The unit is
not on the testharness flist. The same remote run,
`tb_g6lc_apu_vgpu_obj`, errors=0. Fixture synth, no latches:
Enable=0 is 13 ports and no cells; Enable=1 is 1,140 cells / 197
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_vsc` reads the vertex-shader `CREATE_OBJECT` at byte
24 after the fragment shader is accepted. Beat 0 at `64'h8800B000`
carries the header `32'h00250401` and handle 2 in its last two words.
Beat 1 at `64'h8800B020` carries the vertex stage, length 125, token
count 300, a zero stream-out word, and text dword `32'h54524556`.
The surface words in beat 0 are not this check. The rest of the text
stays in the execbuffer. The shader is not run. This is not
`g6lc_apu_vgpu_sh`, and `g6lc_apu_vgpu_avail` still rejects `NEXT`.
`VscEn` defaults to 0 and does not make virgl legal. The unit is not
on the testharness flist. The same remote run, `tb_g6lc_apu_vgpu_obj`,
errors=0. Fixture synth, no latches: Enable=0 is 42 ports and no
cells; Enable=1 is 7,311 cells / 395 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_vse` keeps the header, the handle, the stage, the
length, the token count, and the first text dword. A second store
keeps the first. The shader is not run. `VseEn` defaults to 0 and
does not make virgl legal. The unit is not on the testharness flist.
The same remote run, `tb_g6lc_apu_vgpu_obj`, errors=0. Fixture synth,
no latches: Enable=0 is 13 ports and no cells; Enable=1 is 1,017
cells / 197 flip-flops. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vgpu_sfc` reads the surface `CREATE_OBJECT` at byte 0 after
the vertex shader is accepted. The first six words of beat 0 at
`64'h8800B000` are the header `32'h00050801`, handle 1, resource 4,
format 2, and two zero words. The vertex-shader header in that beat
is not this check. No framebuffer is painted. This is not
`g6lc_apu_vgpu_fbr`, and `g6lc_apu_vgpu_avail` still rejects `NEXT`.
`SfcEn` defaults to 0 and does not make virgl legal. The unit is not
on the testharness flist. The same remote run, `tb_g6lc_apu_vgpu_obj`,
errors=0. Fixture synth, no latches: Enable=0 is 43 ports and no
cells; Enable=1 is 6,753 cells / 265 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_sfe` keeps the header, the handle, the resource, and
the format. A second store keeps the first. The two zero words are
not kept. No pixels are stored. `SfeEn` defaults to 0 and does not
make virgl legal. The unit is not on the testharness flist. The same
remote run, `tb_g6lc_apu_vgpu_obj`, errors=0. Fixture synth, no
latches: Enable=0 is 13 ports and no cells; Enable=1 is 840 cells /
133 flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_nxc` reads the scene descriptor chain from guest memory
after the surface is accepted. Beat 0 at `64'h8800E100` carries
descriptor 0 (header at `64'h8800A000`, NEXT to 1) and descriptor 1
(960 bytes at `64'h8800B000`, NEXT to 2). Beat 1 carries descriptor 2,
a 24-byte WRITE at `64'h8800A800`. Beat 2 at `64'h8800E200` is avail
index 1 naming descriptor 0. INDIRECT, a broken link, and a jumped
index record nothing. This is not `g6lc_apu_vgpu_avail` and not
`g6lc_apu_vgpu_chn`. `g6lc_apu_vgpu_avail` still rejects `NEXT`.
`NxcEn` defaults to 0 and does not make virgl legal. The unit is not
on the testharness flist. Remote 2026-09-23, one run shared with the
record: `tb_g6lc_apu_vgpu_nxc` 16 cases / 71 checks / 109 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 22 ports and no
cells; Enable=1 is 1,959 cells / 396 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_nxk` keeps the head, the avail index, the execbuffer,
and the response. A second store keeps the first. The descriptor
bytes are not kept. `NxkEn` defaults to 0 and does not make virgl
legal. The unit is not on the testharness flist. The same remote run,
`tb_g6lc_apu_vgpu_nxc`, errors=0. Fixture synth, no latches:
Enable=0 is 13 ports and no cells; Enable=1 is 921 cells / 197
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_ols` reads the completed-opcode list at `64'h8800E300`
after the scene chain is accepted and the virgl capset request is
still refused. The count word is 0 and the capset id is 0. A nonzero
count or virgl id 1 records nothing. No caps blob is stored. The
answer is `OK_NODATA`. This is not `g6lc_apu_vgpu_cap` and not
`g6lc_apu_vgpu_nfo`. `FeatureVirgl` stays off and `NumCapsets` stays
0. `OlsEn` defaults to 0 and does not make virgl legal. The unit is
not on the testharness flist. Remote 2026-09-23, one run shared with
the record: `tb_g6lc_apu_vgpu_ols` 13 cases / 59 checks / 71 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 24 ports and no
cells; Enable=1 is 1,055 cells / 137 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_olk` keeps the zero count, capset id 0, and the
response. A second store keeps the first. No caps blob is kept.
`OlkEn` defaults to 0 and does not make virgl legal. The unit is not
on the testharness flist. The same remote run, `tb_g6lc_apu_vgpu_ols`,
errors=0. Fixture synth, no latches: Enable=0 is 13 ports and no
cells; Enable=1 is 557 cells / 101 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_gpw` writes the scene clear word `32'hFF1A0D0D` across
a 64 by 64 guest window at `64'h88020000`. Each beat is eight copies
of that word. 512 beats is 16384 bytes. The bytes are not kept in
registers. A 64-high scissor records nothing. This is not
`g6lc_apu_vgpu_rbf` and not the ceiling at `32'h88040000`. The shader
is not run. This is not the screenshot. `GpwEn` defaults to 0 and
does not make virgl legal. The unit is not on the testharness flist.
Remote 2026-09-23, one run shared with the end read and the record:
`tb_g6lc_apu_vgpu_gpw` 16 cases / 73 checks / 1112 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 23 ports and no cells;
Enable=1 is 766 cells / 18 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_gpr` reads the first beat at `64'h88020000` and the
last beat at `64'h88023FE0`. Both are the clear word. `(1,0)` is byte
4 of the first beat and is that same word. This is not
`g6lc_apu_vgpu_frd` and not `g6lc_apu_vgpu_pxr`. `GprEn` defaults to
0 and does not make virgl legal. The same remote run,
`tb_g6lc_apu_vgpu_gpw`, errors=0. Fixture synth, no latches:
Enable=0 is 22 ports and no cells; Enable=1 is 1,212 cells / 75
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_gpk` keeps the clear word and the two beat addresses.
A second store keeps the first. `GpkEn` defaults to 0 and does not
make virgl legal. The same remote run, `tb_g6lc_apu_vgpu_gpw`,
errors=0. Fixture synth, no latches: Enable=0 is 13 ports and no
cells; Enable=1 is 873 cells / 165 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_gcw` writes the guest completion after that window.
The 24-byte response at `64'h8800A800` is `OK_NODATA`, fence
`64'h1122334455667788`, and context 1. The used element at
`64'h8800E400` is descriptor 0 and length 24. The used index at
`64'h8800E480` is 1. A 64-high scissor writes nothing. The response
bytes are not kept. This is not `g6lc_apu_vgpu_rsp`, not
`g6lc_apu_vgpu_suw`, and not `g6lc_apu_vgpu_sux`. The shader is not
run. `g6lc_apu_vgpu_avail` still rejects `NEXT`. `GcwEn` defaults to
0 and does not make virgl legal. Remote 2026-09-23, shared with the
read and the record: `tb_g6lc_apu_vgpu_gcw` 22 cases / 96 checks /
127 clocks, errors=0. Fixture synth, no latches: Enable=0 is 22
ports and no cells; Enable=1 is 995 cells / 14 flip-flops. The CVA6
cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_gcr` reads those three beats back. Upper bytes of each
beat are not part of the check. `GcrEn` defaults to 0 and does not
make virgl legal. The same remote run, `tb_g6lc_apu_vgpu_gcw`,
errors=0. Fixture synth, no latches: Enable=0 is 24 ports and no
cells; Enable=1 is 1,867 cells / 365 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_gck` keeps the response type, the fence, the used
element, and the used index. A second store keeps the first.
`GckEn` defaults to 0 and does not make virgl legal. The same remote
run, `tb_g6lc_apu_vgpu_gcw`, errors=0. Fixture synth, no latches:
Enable=0 is 15 ports and no cells; Enable=1 is 1,318 cells / 181
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_viw` writes the used-buffer interrupt reason `32'h1`
at `64'h8800E500` after that completion and raises the pin. Ack
lowers the pin and leaves the record. A cancel before the beat
writes nothing and the pin stays low. A 64-high scissor writes
nothing. The reason is not kept as a register file. This is not
`g6lc_apu_vgpu_sun` and not `g6lc_apu_vgpu_used`. The pin is not
PLIC source 9. The shader is not run. `g6lc_apu_vgpu_avail` still
rejects `NEXT`. `ViwEn` defaults to 0 and does not make virgl legal.
Remote 2026-09-23, shared with the read and the record:
`tb_g6lc_apu_vgpu_viw` 20 cases / 89 checks / 102 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 26 ports and no cells;
Enable=1 is 888 cells / 24 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_vir` reads that reason. Upper bytes are not part of
the check. The pin may already have been acknowledged. `VirEn`
defaults to 0 and does not make virgl legal. The same remote run,
`tb_g6lc_apu_vgpu_viw`, errors=0. Fixture synth, no latches:
Enable=0 is 23 ports and no cells; Enable=1 is 897 cells / 88
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_vik` keeps the reason and the used index. A second
store keeps the first. `VikEn` defaults to 0 and does not make virgl
legal. The same remote run, `tb_g6lc_apu_vgpu_viw`, errors=0.
Fixture synth, no latches: Enable=0 is 13 ports and no cells;
Enable=1 is 607 cells / 53 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_vaw` reads the guest ack at `64'h8800E510`. The low
word must be `32'h1`. It then writes `32'h0` over the status word at
`64'h8800E500`. A config-only ack and a zero ack write nothing. A
cancel before the read writes nothing. This does not drive the viw
pin. The shader is not run. `g6lc_apu_vgpu_avail` still rejects
`NEXT`. `VawEn` defaults to 0 and does not make virgl legal. Remote
2026-09-23, shared with the read and the record:
`tb_g6lc_apu_vgpu_vaw` 22 cases / 96 checks / 122 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 34 ports and no cells;
Enable=1 is 862 cells / 7 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_var` reads the ack word and the cleared status. Upper
bytes are not part of the check. `VarEn` defaults to 0 and does not
make virgl legal. The same remote run, `tb_g6lc_apu_vgpu_vaw`,
errors=0. Fixture synth, no latches: Enable=0 is 22 ports and no
cells; Enable=1 is 816 cells / 155 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_vak` keeps the ack, the cleared status, and the used
index. A second store keeps the first. `VakEn` defaults to 0 and
does not make virgl legal. The same remote run,
`tb_g6lc_apu_vgpu_vaw`, errors=0. Fixture synth, no latches:
Enable=0 is 13 ports and no cells; Enable=1 is 709 cells / 85
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_wfr` reads all 512 beats of the window at
`64'h88020000`. Every beat is eight copies of `32'hFF1A0D0D`.
`(0,0)` is the low word of beat 0. `(1,0)` is byte 4 of that beat.
`(63,63)` is the top lane of the last beat at `64'h88023FE0`. The
image is not kept. A 64-high scissor reads nothing. A failed beat
stops the walk. This is not `g6lc_apu_vgpu_gpr`. The shader is not
run. `g6lc_apu_vgpu_avail` still rejects `NEXT`. `WfrEn` defaults
to 0 and does not make virgl legal. Remote 2026-09-23, shared with
the record and the point: `tb_g6lc_apu_vgpu_wfr` 21 cases / 86
checks / 2149 clocks, errors=0. Fixture synth, no latches:
Enable=0 is 23 ports and no cells; Enable=1 is 1,660 cells / 210
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_wfk` keeps those three words and the beat count. A
second store keeps the first. `WfkEn` defaults to 0 and does not
make virgl legal. The same remote run, `tb_g6lc_apu_vgpu_wfr`,
errors=0. Fixture synth, no latches: Enable=0 is 12 ports and no
cells; Enable=1 is 674 cells / 117 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_wfx` returns that clear word for one in-range point.
`x` or `y` of 64 records nothing. A second store keeps the first.
`WfxEn` defaults to 0 and does not make virgl legal. The same remote
run, `tb_g6lc_apu_vgpu_wfr`, errors=0. Fixture synth, no latches:
Enable=0 is 11 ports and no cells; Enable=1 is 299 cells / 51
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_gbw` copies that window into the guest readback
buffer at `64'h88030000`. Each of the 512 beats is read from
`64'h88020000`, checked, and written. A beat that is not the clear
word stops the copy before that beat is written. One beat is held
between the read and the write. The image is not kept. This is not
Mesa `glReadPixels` and not the ceiling at `32'h88040000`. The
shader is not run. `g6lc_apu_vgpu_avail` still rejects `NEXT`.
`GbwEn` defaults to 0 and does not make virgl legal. Remote
2026-09-23, shared with the read and the record:
`tb_g6lc_apu_vgpu_gbw` 19 cases / 84 checks / 2153 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 33 ports and no cells;
Enable=1 is 2,227 cells / 412 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_gbr` reads the first and last beats of that buffer.
Both are the clear word. `(1,0)` is byte 4 of the first beat.
`GbrEn` defaults to 0 and does not make virgl legal. The same remote
run, `tb_g6lc_apu_vgpu_gbw`, errors=0. Fixture synth, no latches:
Enable=0 is 20 ports and no cells; Enable=1 is 1,080 cells / 75
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_gbk` keeps the clear word, the source, and the
readback address. A second store keeps the first. `GbkEn` defaults
to 0 and does not make virgl legal. The same remote run,
`tb_g6lc_apu_vgpu_gbw`, errors=0. Fixture synth, no latches:
Enable=0 is 12 ports and no cells; Enable=1 is 935 cells / 181
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_gbd` names that buffer as a 64 by 64 rectangle,
stride 256, format `B8G8R8X8`, 16384 bytes. A 640 by 480 request
records nothing. The image is not kept. This is not Mesa
`glReadPixels`. The shader is not run. `g6lc_apu_vgpu_avail` still
rejects `NEXT`. `GbdEn` defaults to 0 and does not make virgl legal.
Remote 2026-09-23, shared with the lane and the record:
`tb_g6lc_apu_vgpu_gbd` 18 cases / 78 checks / 91 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 11 ports and no cells;
Enable=1 is 261 cells / 6 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_gbl` reads one lane of that rectangle. `(1,0)` is
byte 4 of the beat at `64'h88030000`. `(63,63)` is the top lane of
`64'h88033FE0`. Both are the clear word. `x` or `y` of 64 reads
nothing. `GblEn` defaults to 0 and does not make virgl legal. The
same remote run, `tb_g6lc_apu_vgpu_gbd`, errors=0. Fixture synth,
no latches: Enable=0 is 22 ports and no cells; Enable=1 is 1,363
cells / 102 flip-flops. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vgpu_gbx` keeps the rectangle and the sampled lane. A
second store keeps the first. `GbxEn` defaults to 0 and does not
make virgl legal. The same remote run, `tb_g6lc_apu_vgpu_gbd`,
errors=0. Fixture synth, no latches: Enable=0 is 11 ports and no
cells; Enable=1 is 829 cells / 115 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_gof` names the byte offset of one point in that
rectangle. The offset is `y * 256 + x * 4`. Row 1 starts at byte
256, address `64'h88030100`. `(1,0)` is byte 4. `(63,63)` starts at
byte 16380. `x` or `y` of 64 records nothing. The image is not
kept. The shader is not run. `g6lc_apu_vgpu_avail` still rejects
`NEXT`. `GofEn` defaults to 0 and does not make virgl legal. Remote
2026-09-23, shared with the lane and the record:
`tb_g6lc_apu_vgpu_gof` 19 cases / 85 checks / 101 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 12 ports and no cells;
Enable=1 is 406 cells / 20 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_gbo` reads the lane at that offset. The lane is the
clear word. `GboEn` defaults to 0 and does not make virgl legal.
The same remote run, `tb_g6lc_apu_vgpu_gof`, errors=0. Fixture
synth, no latches: Enable=0 is 21 ports and no cells; Enable=1 is
1,501 cells / 166 flip-flops. The CVA6 cookie was not re-run. The
TEX opcode still returns `-26`.

`g6lc_apu_vgpu_gbz` keeps the offset and the lane. A second store
keeps the first. `GbzEn` defaults to 0 and does not make virgl
legal. The same remote run, `tb_g6lc_apu_vgpu_gof`, errors=0.
Fixture synth, no latches: Enable=0 is 11 ports and no cells;
Enable=1 is 540 cells / 99 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_byr` reads the first beat and the last beat of that
readback buffer. The clear word `32'hFF1A0D0D` sits in memory as the
bytes 0D 0D 1A FF. Byte 0 is red `8'h0D`, then green `8'h0D`, blue
`8'h1A`, and `8'hFF`. `(0,0)` and `(1,0)` are the low two words of
the beat at `64'h88030000`. `(63,63)` is the top lane of
`64'h88033FE0`. A 64-high scissor reads nothing. A beat that is not
the clear word stops the read. A first byte of `8'hFF` is the
high-byte-first reading and records nothing. The four channels are
the clear-color constants. The image is not kept. The shader is not
run. This is not Mesa `glReadPixels`. `g6lc_apu_vgpu_avail` still
rejects `NEXT`. `ByrEn` defaults to 0 and does not make virgl legal.
Remote 2026-09-23, shared with the record and the first byte:
`tb_g6lc_apu_vgpu_byr` 17 cases / 71 checks / 86 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 22 ports and no cells;
Enable=1 is 1,083 cells / 11 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_byk` keeps those four channels. A second store keeps
the first. The packed channels are the clear word. `BykEn` defaults
to 0 and does not make virgl legal. The same remote run,
`tb_g6lc_apu_vgpu_byr`, errors=0. Fixture synth, no latches:
Enable=0 is 10 ports and no cells; Enable=1 is 145 cells / 37
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_byx` requires the first raw byte to be red `8'h0D`.
A first byte of `8'hFF` records nothing. A second store keeps the
first. `ByxEn` defaults to 0 and does not make virgl legal. The
same remote run, `tb_g6lc_apu_vgpu_byr`, errors=0. Fixture synth,
no latches: Enable=0 is 10 ports and no cells; Enable=1 is 125
cells / 45 flip-flops. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vgpu_ryr` reads row 1 of that readback, the beat at
`64'h88030100`. Byte 0 of that beat is red `8'h0D`, then green
`8'h0D`, blue `8'h1A`, and `8'hFF`. The format tag is
`B8G8R8X8`. A 64-high scissor, a 480-high rectangle, or a format
other than 2 reads nothing. A blue first byte `8'h1A` or a high
byte `8'hFF` records nothing. This is later than
`g6lc_apu_vgpu_byr` and it is not `g6lc_apu_vgpu_gof`. The image
is not kept. The shader is not run. This is not Mesa
`glReadPixels`. `g6lc_apu_vgpu_avail` still rejects `NEXT`.
`RyrEn` defaults to 0 and does not make virgl legal. Remote
2026-09-23, shared with the record and the first byte:
`tb_g6lc_apu_vgpu_ryr` 22 cases / 91 checks / 107 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 21 ports and no
cells; Enable=1 is 877 cells / 9 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_ryk` keeps those channels and the format tag. A
second store keeps the first. `RykEn` defaults to 0 and does not
make virgl legal. The same remote run, `tb_g6lc_apu_vgpu_ryr`,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and no
cells; Enable=1 is 260 cells / 69 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_ryx` requires byte 0 of row 1 to be red `8'h0D`.
A first byte of blue `8'h1A` or of `8'hFF` records nothing. A
second store keeps the first. `RyxEn` defaults to 0 and does not
make virgl legal. The same remote run, `tb_g6lc_apu_vgpu_ryr`,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and no
cells; Enable=1 is 211 cells / 77 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_tpr` reads three points of that readback. `(1,1)` is
byte 260, lane 1 of the beat at `64'h88030100`. `(2,3)` is byte
776, lane 2 of the beat at `64'h88030300`. `(0,63)` is byte 16128,
lane 0 of the beat at `64'h88033F00`. Each lane is the bytes
0D 0D 1A FF. A 64-high scissor, a 480-high rectangle, or another
format reads nothing. A blue or high byte in the named lane stops
the read. This is later than `g6lc_apu_vgpu_ryr`. No triangle is
walked. The image is not kept. The shader is not run. This is not
Mesa `glReadPixels`. `g6lc_apu_vgpu_avail` still rejects `NEXT`.
`TprEn` defaults to 0 and does not make virgl legal. Remote
2026-09-24, shared with the record and the first byte:
`tb_g6lc_apu_vgpu_tpr` 23 cases / 95 checks / 124 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 21 ports and no
cells; Enable=1 is 956 cells / 12 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_tpk` keeps the three offsets and the channels. A
second store keeps the first. `TpkEn` defaults to 0 and does not
make virgl legal. The same remote run, `tb_g6lc_apu_vgpu_tpr`,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and no
cells; Enable=1 is 418 cells / 117 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_tpx` requires byte 0 of `(0,63)` to be red `8'h0D`.
A first byte of blue `8'h1A` or of `8'hFF` records nothing. A
second store keeps the first. `TpxEn` defaults to 0 and does not
make virgl legal. The same remote run, `tb_g6lc_apu_vgpu_tpr`,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and no
cells; Enable=1 is 318 cells / 125 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_x6r` reads `(63,0)` in that readback. The offset is
252, lane 7 of the beat at `64'h880300E0`. Byte 0 of that lane is
red `8'h0D`. `(0,63)` stays byte 16128 and is not this point. A
swapped offset reads nothing. A blue or high byte in lane 7 stops
the read. The image is not kept. The shader is not run. This is
not Mesa `glReadPixels`. `g6lc_apu_vgpu_avail` still rejects
`NEXT`. `X6rEn` defaults to 0 and does not make virgl legal.
Remote 2026-09-24, shared with the record and the first byte:
`tb_g6lc_apu_vgpu_x6r` 21 cases / 87 checks / 103 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 21 ports and no
cells; Enable=1 is 971 cells / 9 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_x6k` keeps that offset and the channels. A second
store keeps the first. `X6kEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_x6r`,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and no
cells; Enable=1 is 371 cells / 99 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_x6x` requires byte 0 of `(63,0)` to be red `8'h0D`.
A first byte of blue `8'h1A` or of `8'hFF` records nothing. A
second store keeps the first. `X6xEn` defaults to 0 and does not
make virgl legal. The same remote run, `tb_g6lc_apu_vgpu_x6r`,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and no
cells; Enable=1 is 283 cells / 107 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_tcr` reads `(63,63)` in that readback. The offset is
16380, lane 7 of the beat at `64'h88033FE0`. Byte 0 of that lane
is red `8'h0D`. The next byte is 16384, the byte count. `(63,0)`
stays byte 252 and `(0,63)` stays byte 16128. A swapped offset
reads nothing. A blue or high byte in lane 7 stops the read. The
image is not kept. The shader is not run. This is not Mesa
`glReadPixels`. `g6lc_apu_vgpu_avail` still rejects `NEXT`.
`TcrEn` defaults to 0 and does not make virgl legal. Remote
2026-09-24, shared with the record and the first byte:
`tb_g6lc_apu_vgpu_tcr` 22 cases / 91 checks / 107 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 22 ports and no
cells; Enable=1 is 1,032 cells / 9 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_tck` keeps that offset and the channels. A second
store keeps the first. `TckEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_tcr`,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and no
cells; Enable=1 is 380 cells / 99 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_tcx` requires byte 0 of `(63,63)` to be red `8'h0D`.
A first byte of blue `8'h1A` or of `8'hFF` records nothing. A
second store keeps the first. `TcxEn` defaults to 0 and does not
make virgl legal. The same remote run, `tb_g6lc_apu_vgpu_tcr`,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and no
cells; Enable=1 is 295 cells / 107 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_p7r` reads `(7,0)` in that readback. The offset is
28, lane 7 of the base beat at `64'h88030000`. `(63,0)` stays
byte 252 at `64'h880300E0`. A record that puts offset 28 on
`(63,0)` reads nothing. A blue or high byte in lane 7 stops the
read. The image is not kept. The shader is not run. This is not
Mesa `glReadPixels`. `g6lc_apu_vgpu_avail` still rejects `NEXT`.
`P7rEn` defaults to 0 and does not make virgl legal. Remote
2026-09-24, shared with the record and the first byte:
`tb_g6lc_apu_vgpu_p7r` 21 cases / 87 checks / 103 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 22 ports and no
cells; Enable=1 is 1,002 cells / 9 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_p7k` keeps that offset and the channels. A second
store keeps the first. `P7kEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_p7r`,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and no
cells; Enable=1 is 369 cells / 99 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_p7x` requires byte 0 of `(7,0)` to be red `8'h0D`.
A first byte of blue `8'h1A` or of `8'hFF` records nothing. A
second store keeps the first. `P7xEn` defaults to 0 and does not
make virgl legal. The same remote run, `tb_g6lc_apu_vgpu_p7r`,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and no
cells; Enable=1 is 277 cells / 107 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_b1r` reads the next beat of row 0, at
`64'h88030020`. `(8,0)` is byte 32, lane 0. `(15,0)` is byte 60,
lane 7. Both lanes are the bytes 0D 0D 1A FF. `(7,0)` stays byte
28 in the base beat. Putting offset 32 on `(7,0)` reads nothing.
A blue or high byte in either lane stops the read. The image is
not kept. The shader is not run. This is not Mesa
`glReadPixels`. `g6lc_apu_vgpu_avail` still rejects `NEXT`.
`B1rEn` defaults to 0 and does not make virgl legal. Remote
2026-09-24, shared with the record and the first byte:
`tb_g6lc_apu_vgpu_b1r` 21 cases / 87 checks / 103 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 21 ports and no
cells; Enable=1 is 955 cells / 9 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_b1k` keeps those two offsets and the channels. A
second store keeps the first. `B1kEn` defaults to 0 and does not
make virgl legal. The same remote run, `tb_g6lc_apu_vgpu_b1r`,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and no
cells; Enable=1 is 399 cells / 115 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_b1x` requires byte 0 of `(8,0)` to be red `8'h0D`.
A first byte of blue `8'h1A` or of `8'hFF` records nothing. A
second store keeps the first. `B1xEn` defaults to 0 and does not
make virgl legal. The same remote run, `tb_g6lc_apu_vgpu_b1r`,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and no
cells; Enable=1 is 313 cells / 123 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_b7r` reads lane 0 of the beat that holds `(63,0)`,
at `64'h880300E0`. `(56,0)` is byte 224, lane 0. `(63,0)` stays
byte 252, lane 7. Both lanes are the bytes 0D 0D 1A FF. Putting
offset 224 on `(63,0)`, or on the beat-1 record, reads nothing.
A blue or high byte in either lane stops the read. The image is
not kept. The shader is not run. This is not Mesa
`glReadPixels`. `g6lc_apu_vgpu_avail` still rejects `NEXT`.
`B7rEn` defaults to 0 and does not make virgl legal. Remote
2026-09-24, shared with the record and the first byte:
`tb_g6lc_apu_vgpu_b7r` 21 cases / 87 checks / 103 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 22 ports and no
cells; Enable=1 is 1,016 cells / 9 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_b7k` keeps those two offsets and the channels. A
second store keeps the first. `B7kEn` defaults to 0 and does not
make virgl legal. The same remote run, `tb_g6lc_apu_vgpu_b7r`,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and no
cells; Enable=1 is 421 cells / 115 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_b7x` requires byte 0 of `(56,0)` to be red `8'h0D`.
A first byte of blue `8'h1A` or of `8'hFF` records nothing. A
second store keeps the first. `B7xEn` defaults to 0 and does not
make virgl legal. The same remote run, `tb_g6lc_apu_vgpu_b7r`,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and no
cells; Enable=1 is 321 cells / 123 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_b2r` reads beat 2 of row 0, at `64'h88030040`.
`(16,0)` is byte 64, lane 0. `(23,0)` is byte 92, lane 7. Both
lanes are the bytes 0D 0D 1A FF. Putting offset 64 on `(56,0)`
reads nothing. A blue or high byte in either lane stops the read.
The image is not kept. The shader is not run. This is not Mesa
`glReadPixels`. `g6lc_apu_vgpu_avail` still rejects `NEXT`.
`B2rEn` defaults to 0 and does not make virgl legal. Remote
2026-09-24, shared with the record and the first byte:
`tb_g6lc_apu_vgpu_b2r` 21 cases / 87 checks / 103 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 21 ports and no
cells; Enable=1 is 983 cells / 9 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_b2k` keeps those two offsets and the channels. A
second store keeps the first. `B2kEn` defaults to 0 and does not
make virgl legal. The same remote run, `tb_g6lc_apu_vgpu_b2r`,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and no
cells; Enable=1 is 413 cells / 115 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_b2x` requires byte 0 of `(16,0)` to be red `8'h0D`.
A first byte of blue `8'h1A` or of `8'hFF` records nothing. A
second store keeps the first. `B2xEn` defaults to 0 and does not
make virgl legal. The same remote run, `tb_g6lc_apu_vgpu_b2r`,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and no
cells; Enable=1 is 313 cells / 123 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_b3r` reads beat 3 of row 0, at `64'h88030060`.
`(24,0)` is byte 96, lane 0. `(31,0)` is byte 124, lane 7. Both
lanes are the bytes 0D 0D 1A FF. Putting offset 96 on `(16,0)`
reads nothing. A blue or high byte in either lane stops the read.
The image is not kept. The shader is not run. This is not Mesa
`glReadPixels`. `g6lc_apu_vgpu_avail` still rejects `NEXT`.
`B3rEn` defaults to 0 and does not make virgl legal. Remote
2026-09-24, shared with the record and the first byte:
`tb_g6lc_apu_vgpu_b3r` 21 cases / 87 checks / 103 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 21 ports and no
cells; Enable=1 is 976 cells / 9 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_b3k` keeps those two offsets and the channels. A
second store keeps the first. `B3kEn` defaults to 0 and does not
make virgl legal. The same remote run, `tb_g6lc_apu_vgpu_b3r`,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and no
cells; Enable=1 is 417 cells / 115 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_b3x` requires byte 0 of `(24,0)` to be red `8'h0D`.
A first byte of blue `8'h1A` or of `8'hFF` records nothing. A
second store keeps the first. `B3xEn` defaults to 0 and does not
make virgl legal. The same remote run, `tb_g6lc_apu_vgpu_b3r`,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and no
cells; Enable=1 is 317 cells / 123 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_b4r` reads beat 4 of row 0, at `64'h88030080`.
`(32,0)` is byte 128, lane 0. `(39,0)` is byte 156, lane 7. Both
lanes are the bytes 0D 0D 1A FF. Putting offset 128 on `(24,0)`
reads nothing. A blue or high byte in either lane stops the read.
The image is not kept. The shader is not run. This is not Mesa
`glReadPixels`. `g6lc_apu_vgpu_avail` still rejects `NEXT`.
`B4rEn` defaults to 0 and does not make virgl legal. Remote
2026-09-24, shared with the record and the first byte:
`tb_g6lc_apu_vgpu_b4r` 21 cases / 87 checks / 103 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 21 ports and no
cells; Enable=1 is 979 cells / 9 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_b4k` keeps those two offsets and the channels. A
second store keeps the first. `B4kEn` defaults to 0 and does not
make virgl legal. The same remote run, `tb_g6lc_apu_vgpu_b4r`,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and no
cells; Enable=1 is 413 cells / 115 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_b4x` requires byte 0 of `(32,0)` to be red `8'h0D`.
A first byte of blue `8'h1A` or of `8'hFF` records nothing. A
second store keeps the first. `B4xEn` defaults to 0 and does not
make virgl legal. The same remote run, `tb_g6lc_apu_vgpu_b4r`,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and no
cells; Enable=1 is 313 cells / 123 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_b5r` reads beat 5 of row 0, at `64'h880300A0`.
`(40,0)` is byte 160, lane 0. `(47,0)` is byte 188, lane 7. Both
lanes are the bytes 0D 0D 1A FF. Putting offset 160 on `(32,0)`
reads nothing. A blue or high byte in either lane stops the read.
The image is not kept. The shader is not run. This is not Mesa
`glReadPixels`. `g6lc_apu_vgpu_avail` still rejects `NEXT`.
`B5rEn` defaults to 0 and does not make virgl legal. Remote
2026-09-24, shared with the record and the first byte:
`tb_g6lc_apu_vgpu_b5r` 21 cases / 87 checks / 103 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 21 ports and no
cells; Enable=1 is 976 cells / 9 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_b5k` keeps those two offsets and the channels. A
second store keeps the first. `B5kEn` defaults to 0 and does not
make virgl legal. The same remote run, `tb_g6lc_apu_vgpu_b5r`,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and no
cells; Enable=1 is 417 cells / 115 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_b5x` requires byte 0 of `(40,0)` to be red `8'h0D`.
A first byte of blue `8'h1A` or of `8'hFF` records nothing. A
second store keeps the first. `B5xEn` defaults to 0 and does not
make virgl legal. The same remote run, `tb_g6lc_apu_vgpu_b5r`,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and no
cells; Enable=1 is 317 cells / 123 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_b6r` reads beat 6 of row 0, at `64'h880300C0`.
`(48,0)` is byte 192, lane 0. `(55,0)` is byte 220, lane 7. Both
lanes are the bytes 0D 0D 1A FF. Putting offset 192 on `(40,0)`
reads nothing. A blue or high byte in either lane stops the read.
The image is not kept. The shader is not run. This is not Mesa
`glReadPixels`. `g6lc_apu_vgpu_avail` still rejects `NEXT`.
`B6rEn` defaults to 0 and does not make virgl legal. Remote
2026-09-24, shared with the record and the first byte:
`tb_g6lc_apu_vgpu_b6r` 21 cases / 87 checks / 103 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 21 ports and no
cells; Enable=1 is 980 cells / 9 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_b6k` keeps those two offsets and the channels. A
second store keeps the first. `B6kEn` defaults to 0 and does not
make virgl legal. The same remote run, `tb_g6lc_apu_vgpu_b6r`,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and no
cells; Enable=1 is 417 cells / 115 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_b6x` requires byte 0 of `(48,0)` to be red `8'h0D`.
A first byte of blue `8'h1A` or of `8'hFF` records nothing. A
second store keeps the first. `B6xEn` defaults to 0 and does not
make virgl legal. The same remote run, `tb_g6lc_apu_vgpu_b6r`,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and no
cells; Enable=1 is 317 cells / 123 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_back` stores one `RESOURCE_ATTACH_BACKING` (`0x0106`)
entry for a resource that already exists. The command is 48 bytes: the
virtio header, the resource id, `nr_entries`, and one memory entry.
`nr_entries` must be 1. The length must equal `width * height * 4`, the
address must be nonzero and 4-byte aligned, and the byte range must not
wrap. A second attach returns `ERR_UNSPEC` (`0x1200`) and does not
replace the entry. An unknown id returns `INVALID_RESOURCE_ID`. A bad
shape, a zero or misaligned address, a wrapping range, or another
command type returns `INVALID_PARAMETER` and stores nothing.
`VIRTIO_GPU_FLAG_FENCE` echoes `fence_id` on success and on error.
Resource 7, the 4×2 image, keeps address `64'h8800_1000` and length 32.
Resource 8, a 1×1 image, keeps address `64'h8800_2000` and length 4.
This is not `g6lc_apu_attach`. It does not read guest memory, walk an
avail ring, or follow a descriptor chain. `BackEn` defaults to 0 and
does not make virgl legal. The unit is not on the testharness flist.
Remote 2026-09-22: `tb_g6lc_apu_vgpu_back` 19 cases / 138 checks / 99
clocks, errors=0. Fixture synth, no latches: Enable=0 is 12 ports and
no cells; Enable=1 is 8,782 cells / 363 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_xfer` reads that one stored entry into the resource.
`TRANSFER_TO_HOST_2D` (`0x0105`) is a 56-byte command: the virtio
header, a rectangle, a 64-bit offset, the resource id, and padding.
`x`, `y`, and the offset must be 0, and the rectangle must match the
resource. The read address and length come from the stored backing
entry. A response with a different address, a different length, or a
failed beat returns `ERR_UNSPEC` and does not change the image. The
4×2 resource keeps all 32 bytes. The 1×1 resource keeps its low 4
bytes and clears the rest, so a wide response does not leak into the
image. There is no guest write. `XferEn` defaults to 0 and does not
make virgl legal. The unit is not on the testharness flist. Each
slot is its own byte memory. One response stores one 32-byte beat,
and bytes above that beat stay clear. Remote 2026-09-23:
`tb_g6lc_apu_vgpu_xfer` 13 cases / 154 checks / 125 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 27 ports and no cells;
Enable=1 is 12,034 cells / 974 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_uwr` writes one published local `virtq_used` element
into guest memory. The store is 8 bytes: the descriptor id in the low
half and the length in the high half. `used.idx` must already be
nonzero, so an unpublished prefix is not written. The address must be
nonzero and 8-byte aligned, and the 8-byte range must not wrap. A
failed response or a mismatched address does not mark the element
written, and that write can be retried. A second store does not
replace it. Descriptor 4 with length 24 lands at `64'h8800_3000`.
This does not write `used.idx`. It is not `g6lc_apu_queue`, and
`g6lc_apu_vgpu_used` still does not write guest memory. `UwrEn`
defaults to 0 and does not make virgl legal. The unit is not on the
testharness flist. Remote 2026-09-22: `tb_g6lc_apu_vgpu_uwr` 10 cases
/ 74 checks / 66 clocks, errors=0. Fixture synth, no latches:
Enable=0 is 20 ports and no cells; Enable=1 is 1,701 cells / 262
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_uidx` stores that local `used.idx` into guest memory.
The store is the 16-bit index at a 2-byte-aligned address. The local
index must already be nonzero, and the used element must already have
been written. An unpublished prefix is not stored. A zero address, an
odd address, or a wrapping range issues no store. A failed or
mismatched response does not mark the index stored, and that store
can be retried. A second store does not replace it. After descriptor
4 is published and its element is at `64'h8800_3000`, the index value
1 lands at `64'h8800_4002`. This does not write the element again. It
is not `g6lc_apu_queue`. `UidxEn` defaults to 0 and does not make
virgl legal. The unit is not on the testharness flist. Remote
2026-09-22: `tb_g6lc_apu_vgpu_uidx` 11 cases / 82 checks / 76 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 19 ports and no
cells; Enable=1 is 1,376 cells / 166 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_rsurf` copies one covered sample from that resource image.
The address is `y * stride + x * 4`, and byte 0 is red, the same rule
as the fragment surface. The image must already hold
`width * height * 4` bytes and the stride must be `width * 4`. A miss
leaves the surface unchanged. A fault leaves it unchanged. Sample
`(1,0)` of the 4×2 ramp image is `32'hA7A6A5A4`; `(0,0)` and `(2,0)`
stay clear. This is not `g6lc_apu_frag`'s memory, not a draw command,
and not the HDMI buffer. `SurfEn` defaults to 0 and does not make
virgl legal. The unit is not on the testharness flist. The image
is a byte memory. Remote 2026-09-23: `tb_g6lc_apu_rsurf` 7 cases /
46 checks / 69 clocks, errors=0. Fixture synth, no latches:
Enable=0 is 16 ports and no cells; Enable=1 is 2,368,466 cells /
262,180 flip-flops. The CVA6 cookie was not re-run. The TEX opcode
still returns `-26`.

`g6lc_apu_vgpu_rdb` writes that fragment surface back to the guest.
`TRANSFER_FROM_HOST_3D` (`0x0206`) is a 72-byte command: the virtio
header, a box, a 64-bit offset, the resource id, the level, the
stride, and the layer stride. The box is the whole resource, `x`, `y`,
`z`, the offset, and the level are 0, and the depth is 1. The stride
is 0 or `width * 4`, and the layer stride is 0 or that row size times
the height. Bytes come from the fragment image, not from the upload
ramp, and land at the stored backing address. A 4-byte resource keeps
only its low 4 bytes on the wide store. A failed or mismatched
response does not mark the readback done, and that store can be
retried. A second readback of the same resource returns `ERR_UNSPEC`
and does not replace the bytes. `SUBMIT_3D` stores nothing. Resource
7, the 4×2 surface, keeps address `64'h8800_5000` and length 32:
`(0,0)` is `32'hFF0000FF`, `(1,0)` is gray `32'hFF808080`, `(2,0)` is
the texel `32'hFF80FF40`, and the other five pixels stay 0. Resource
8 keeps 4 bytes at `64'h8800_2000`. The same command also reads
an 8×4 surface, 128 bytes at `64'h8800_6000`. Column `(4,0)` is gray
`32'hFF808080` and row `(0,2)` is the texel `32'hFF80FF40`. The same
command also reads a 16×8 surface, 512 bytes at `64'h8800_7000`.
The 64×32 surface is 8192 bytes at `64'h8800_9000`. The 64×64
surface is 16384 bytes at `64'h8800_C000`. Row `(0,32)` is that gray
and `(63,63)` is white. A 128-wide resource is still rejected. The
guest copy is a 32-byte beat. The full image is 512 beats, and
`wrote` rises after the last good beat. A 4-byte resource is one
beat, and the upper bytes of that beat are 0. This is not a draw,
not a descriptor chain, and not the HDMI buffer. `RdbEn` defaults to
0 and does not make virgl legal. The unit is not on the testharness
flist. The image zero is wider than Verilator's 8k-bit replication
check, so these run scripts waive `WIDTHCONCAT`. Remote 2026-09-23:
`tb_g6lc_apu_vgpu_rdb` 52 cases / 1,169 checks / 9,024 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 27 ports and no
cells; Enable=1 is 1,589,819 cells / 131,758 flip-flops. The CVA6
cookie was not re-run. The TEX opcode still returns `-26`.

## One service, two optional loading policies

The production artifact must have a manifest naming image length/digest,
entry, privilege, load/BSS/stack requirements, firmware ABI, native ISA,
RTL configuration and supported compatibility profile. No compiler-supplied
capability declaration may enable functionality absent from RTL.

- A platform loader can provision/start this image without `g6lc_bios`.
- BIOS can optionally select/stage the same artifact and invoke a bounded
  trusted-supervisor loader/start interface. The reserved hart runs the same
  service after Linux takes over. This is independent management, not a
  requirement to link firmware C into BIOS Rust or synchronize both releases.
- OpenSBI owns M-mode and domain/HSM policy; the service is S-mode. Do not
  parse untrusted virgl in M-mode. The current direct reset and M-mode DTS
  overlay remain diagnostics until a real S-mode launch is verified.

Loader, domain, reset and health responsibilities are defined once in
`apu-firmware-domain.md`. `crt0.S` currently sets SP and calls main; it does
not establish a production BSS/trap/privilege/interrupt/ready contract.
Hex preload and `fw_ready=#1` are not deployment loading mechanisms.

## Service-loop completion gates

1. Bring up a real trap/stack/BSS environment and deterministic initialization
   of resource/program validity. Do not rely on simulation-zeroed SRAM.
2. Establish runtime ABI/config/image identity and fresh instance readiness.
   Readiness is a completed bounded initialization/self-test, not a cookie
   from a previous firmware instance. Expose progress/fault diagnostics.
3. Consume both standard virtqueues through checked snapshots; validate
   descriptor chains, byte counts, continuations, object namespaces and
   resource lifetime before submitting native work. No descriptor-chain
   semantics are inferred from the flat virtio-gpu backing SG table.
4. Bound allocator/compiler/decoder work and enforce per-context quotas and
   deadlines. Interrupts enqueue/ack; long compilation never starves reset,
   completion or recovery service. Return deterministic standard errors.
5. Use the same semantic compiler on host and CVA6. Preserve program and
   resource identity through the combined memory/exec scheduler and issue
   used/fence publication only after execution and cache visibility.
6. Prove service restart, failed image load, stale request, queue reset and
   watchdog recovery with work outstanding. Keep mappings pinned during drain;
   protocol quarantine is not released by clearing a software variable.

## Boot-health adapter boundary

The BIOS plan's `g6b-bootctl`/`g6b-boot-health` already separate Linux-attempt
acknowledgement from firmware-candidate health and operator inhibition.
Reuse those principles and a versioned status adapter, not their private
structures or journal offsets. APU service status is a distinct namespace;
G6BH v1 has no APU domain. The APU must not write the Linux journal, choose
BIOS slots, enable autoboot or assume ownership of the platform watchdog.

Optional graphics failure leaves serial/recovery usable and the device off.
Only explicit required-graphics policy may delay Linux confirmation for a
real hardware graphics probe. Firmware alive, DRM bound, successful GPU work
and Linux healthy are separate facts. The existing BIOS live-Linux/watchdog
gates remain independent and incomplete until actually demonstrated.

## Evidence

Historical remote evidence: native encoding and host TGSI tests pass;
resident BFM 179 checks / 739 clocks; mini-hart 186 / 3,077; CVA6 cookie
14 / 1,835; CVA6 target-stub TGSI image 14 / 10,511. These results are
bring-up evidence only. Reproducible acceptance must rebuild the ELF/hex from
pinned source/toolchain and verify hashes, not silently use a checked-in hex
when compilation is skipped. Runs and limitations belong in the root
traceability records rather than a new chronological plan milestone.
