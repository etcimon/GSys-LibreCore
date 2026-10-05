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

`g6lc_apu_vgpu_acw` writes the linear sample pair as fragment color.
One beat at `64'h88050000`. Lane 0 is `(0,0)`, the clamp texel
`32'hA5000000`. Lane 1 is `(1,0)`, the half blend `32'hD2008000`.
A 64-high scissor, a clear-colored sample, or a failed beat writes
nothing. This is later than `g6lc_apu_vgpu_lnr`. The clear window
at `64'h88020000` stays the clear word. The image is not kept. TEX
is not the compiler opcode. This is not Mesa `glReadPixels`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. `AcwEn` defaults to 0
and does not make virgl legal. Remote 2026-09-30, shared with the
readback and the first byte: `tb_g6lc_apu_vgpu_acw` 25 cases / 109
checks / 125 clocks, errors=0. Fixture synth, no latches: Enable=0
is 21 ports and no cells; Enable=1 is 773 cells / 137 flip-flops.
The CVA6 cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_acr` reads that beat back. Both lanes must match the
written pair and must not be the clear word. Swapped lanes or a
clear-colored lane stop the read. A second store keeps the first.
`AcrEn` defaults to 0 and does not make virgl legal. The same
remote run, `tb_g6lc_apu_vgpu_acw`, errors=0. Fixture synth, no
latches: Enable=0 is 21 ports and no cells; Enable=1 is 1,093
cells / 137 flip-flops. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vgpu_acx` requires byte 0 of `(1,0)` to be the sample red
`8'h00`. A first byte of the clear red `8'h0D`, of blue `8'h1A`, or
of `8'hFF` records nothing. A second store keeps the first.
`AcxEn` defaults to 0 and does not make virgl legal. The same
remote run, `tb_g6lc_apu_vgpu_acw`, errors=0. Fixture synth, no
latches: Enable=0 is 10 ports and no cells; Enable=1 is 538 cells
/ 155 flip-flops. The CVA6 cookie was not re-run. The TEX opcode
still returns `-26`.

`g6lc_apu_vgpu_csw` copies the 64 by 64 ceiling samples into the
color window at `64'h88060000`. Source is `64'h88040000`. Beat 0
lanes 0 and 1 are the linear sample pair. A clear-colored lane, a
64-high scissor, or a failed beat stops the copy. The image is
not kept. This is later than `g6lc_apu_vgpu_acx`. TEX is not the
compiler opcode. This is not Mesa `glReadPixels`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. `CswEn` defaults to 0
and does not make virgl legal. Remote 2026-09-30, shared with the
readback and the first byte: `tb_g6lc_apu_vgpu_csw` 24 cases / 105
checks / 2172 clocks, errors=0. Fixture synth, no latches:
Enable=0 is 30 ports and no cells; Enable=1 is 1,805 cells / 412
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_csr` reads beat 0 of that color window. Both lanes
must match the sample pair. Swapped lanes or a clear-colored lane
stop the read. A second store keeps the first. `CsrEn` defaults
to 0 and does not make virgl legal. The same remote run,
`tb_g6lc_apu_vgpu_csw`, errors=0. Fixture synth, no latches:
Enable=0 is 21 ports and no cells; Enable=1 is 1,114 cells / 137
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_csx` requires byte 0 of `(1,0)` in that window to be
the sample red `8'h00`. A first byte of the clear red `8'h0D`, of
blue `8'h1A`, or of `8'hFF` records nothing. A second store keeps
the first. `CsxEn` defaults to 0 and does not make virgl legal.
The same remote run, `tb_g6lc_apu_vgpu_csw`, errors=0. Fixture
synth, no latches: Enable=0 is 10 ports and no cells; Enable=1 is
482 cells / 123 flip-flops. The CVA6 cookie was not re-run. The
TEX opcode still returns `-26`.

`g6lc_apu_vgpu_crd` names that color window as a 64 by 64
rectangle, stride 256, format B8G8R8X8, 16384 bytes, base
`64'h88060000`. A 640 by 480 request records nothing. This is
later than `g6lc_apu_vgpu_csx`. The image is not kept. TEX is not
the compiler opcode. This is not Mesa `glReadPixels`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. `CrdEn` defaults to 0
and does not make virgl legal. Remote 2026-09-30, shared with the
lane and the first byte: `tb_g6lc_apu_vgpu_crd` 22 cases / 90
checks / 104 clocks, errors=0. Fixture synth, no latches:
Enable=0 is 12 ports and no cells; Enable=1 is 608 cells / 70
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_crl` reads `(1,0)` in that rectangle. The lane is
the half blend `32'hD2008000`. `(0,0)` or the next row records
nothing. A clear-colored lane stops the read. A second store
keeps the first. `CrlEn` defaults to 0 and does not make virgl
legal. The same remote run, `tb_g6lc_apu_vgpu_crd`, errors=0.
Fixture synth, no latches: Enable=0 is 22 ports and no cells;
Enable=1 is 1,019 cells / 134 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_crx` requires byte 0 of that `(1,0)` to be the
sample red `8'h00`. A first byte of the clear red `8'h0D`, of
blue `8'h1A`, or of `8'hFF` records nothing. A second store keeps
the first. `CrxEn` defaults to 0 and does not make virgl legal.
The same remote run, `tb_g6lc_apu_vgpu_crd`, errors=0. Fixture
synth, no latches: Enable=0 is 11 ports and no cells; Enable=1 is
470 cells / 123 flip-flops. The CVA6 cookie was not re-run. The
TEX opcode still returns `-26`.

`g6lc_apu_vgpu_cof` names the byte offset of one point in that
sample rectangle. Offset is `y * 256 + x * 4`. `(1,0)` is byte 4
at `64'h88060000`. `(63,63)` is byte 16380 at `64'h88063FE0`. x
or y of 64 records nothing. This is later than `g6lc_apu_vgpu_crx`.
The image is not kept. TEX is not the compiler opcode. This is
not Mesa `glReadPixels`. `g6lc_apu_vgpu_avail` still rejects
`NEXT`. `CofEn` defaults to 0 and does not make virgl legal.
Remote 2026-09-30, shared with the origin and the first byte:
`tb_g6lc_apu_vgpu_cof` 21 cases / 89 checks / 103 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 12 ports and no
cells; Enable=1 is 395 cells / 20 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_cor` reads `(0,0)` in that rectangle. The lane is
the clamp texel `32'hA5000000`. `(1,0)` or the next row records
nothing. A clear-colored lane or swapped lanes stop the read. A
second store keeps the first. `CorEn` defaults to 0 and does not
make virgl legal. The same remote run, `tb_g6lc_apu_vgpu_cof`,
errors=0. Fixture synth, no latches: Enable=0 is 22 ports and no
cells; Enable=1 is 973 cells / 106 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_cox` requires byte 0 of that `(0,0)` to be the
sample red `8'h00`. The word is the clamp texel, not the `(1,0)`
blend. A first byte of the clear red `8'h0D`, of blue `8'h1A`, or
of `8'hFF` records nothing. A second store keeps the first.
`CoxEn` defaults to 0 and does not make virgl legal. The same
remote run, `tb_g6lc_apu_vgpu_cof`, errors=0. Fixture synth, no
latches: Enable=0 is 11 ports and no cells; Enable=1 is 492 cells
/ 75 flip-flops. The CVA6 cookie was not re-run. The TEX opcode
still returns `-26`.

`g6lc_apu_vgpu_rpw` copies that 64 by 64 sample rectangle into a
guest buffer at `64'h88070000`. The command is
`TRANSFER_FROM_HOST_3D` (`0x0206`) of resource 4. Source is
`64'h88060000`. Beat 0 is the linear sample pair. A clear-colored
lane, a 64-high scissor, or a failed beat stops the copy. This is
later than `g6lc_apu_vgpu_cox`. The image is not kept. TEX is not
the compiler opcode. This is not Mesa `glReadPixels`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. `RpwEn` defaults to 0
and does not make virgl legal. Remote 2026-09-30, shared with the
readback and the first byte: `tb_g6lc_apu_vgpu_rpw` 24 cases / 105
checks / 2172 clocks, errors=0. Fixture synth, no latches:
Enable=0 is 30 ports and no cells; Enable=1 is 1,821 cells / 412
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_rpr` reads beat 0 of that guest buffer. Both lanes
must match the sample pair. Swapped lanes or a clear-colored lane
stop the read. A second store keeps the first. `RprEn` defaults
to 0 and does not make virgl legal. The same remote run,
`tb_g6lc_apu_vgpu_rpw`, errors=0. Fixture synth, no latches:
Enable=0 is 21 ports and no cells; Enable=1 is 1,119 cells / 137
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_rpx` requires byte 0 of `(1,0)` in that guest
buffer to be the sample red `8'h00`. A first byte of the clear
red `8'h0D`, of blue `8'h1A`, or of `8'hFF` records nothing. A
second store keeps the first. `RpxEn` defaults to 0 and does not
make virgl legal. The same remote run, `tb_g6lc_apu_vgpu_rpw`,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and no
cells; Enable=1 is 482 cells / 123 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_grd` names that guest buffer as a 64 by 64
rectangle, stride 256, format B8G8R8X8, 16384 bytes, base
`64'h88070000`. The command is `TRANSFER_FROM_HOST_3D`. A 640 by
480 request records nothing. This is later than `g6lc_apu_vgpu_rpx`.
The image is not kept. TEX is not the compiler opcode. This is
not Mesa `glReadPixels`. `g6lc_apu_vgpu_avail` still rejects
`NEXT`. `GrdEn` defaults to 0 and does not make virgl legal.
Remote 2026-09-30, shared with the lane and the first byte:
`tb_g6lc_apu_vgpu_grd` 23 cases / 93 checks / 108 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 12 ports and no
cells; Enable=1 is 710 cells / 102 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_grl` reads `(1,0)` in that guest rectangle. The
lane is the half blend `32'hD2008000`. `(0,0)` or the next row
records nothing. A clear-colored lane stops the read. A second
store keeps the first. `GrlEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_grd`,
errors=0. Fixture synth, no latches: Enable=0 is 22 ports and no
cells; Enable=1 is 1,054 cells / 134 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_grx` requires byte 0 of that `(1,0)` to be the
sample red `8'h00`. A first byte of the clear red `8'h0D`, of
blue `8'h1A`, or of `8'hFF` records nothing. A second store keeps
the first. `GrxEn` defaults to 0 and does not make virgl legal.
The same remote run, `tb_g6lc_apu_vgpu_grd`, errors=0. Fixture
synth, no latches: Enable=0 is 11 ports and no cells; Enable=1 is
505 cells / 123 flip-flops. The CVA6 cookie was not re-run. The
TEX opcode still returns `-26`.

`g6lc_apu_vgpu_rof` names the byte offset of one point in that
guest rectangle. Offset is `y * 256 + x * 4`. `(1,0)` is byte 4
at `64'h88070000`. `(63,63)` is byte 16380 at `64'h88073FE0`. x
or y of 64 records nothing. This is later than `g6lc_apu_vgpu_grx`.
The image is not kept. TEX is not the compiler opcode. This is
not Mesa `glReadPixels`. `g6lc_apu_vgpu_avail` still rejects
`NEXT`. `RofEn` defaults to 0 and does not make virgl legal.
Remote 2026-09-30, shared with the origin and the first byte:
`tb_g6lc_apu_vgpu_rof` 21 cases / 89 checks / 103 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 12 ports and no
cells; Enable=1 is 429 cells / 20 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_ror` reads `(0,0)` in that guest rectangle. The
lane is the clamp texel `32'hA5000000`. `(1,0)` or the next row
records nothing. A clear-colored lane or swapped lanes stop the
read. A second store keeps the first. `RorEn` defaults to 0 and
does not make virgl legal. The same remote run, `tb_g6lc_apu_vgpu_rof`,
errors=0. Fixture synth, no latches: Enable=0 is 22 ports and no
cells; Enable=1 is 1,008 cells / 106 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_rox` requires byte 0 of that `(0,0)` to be the
sample red `8'h00`. The word is the clamp texel, not the `(1,0)`
blend. A first byte of the clear red `8'h0D`, of blue `8'h1A`, or
of `8'hFF` records nothing. A second store keeps the first.
`RoxEn` defaults to 0 and does not make virgl legal. The same
remote run, `tb_g6lc_apu_vgpu_rof`, errors=0. Fixture synth, no
latches: Enable=0 is 11 ports and no cells; Enable=1 is 529 cells
/ 75 flip-flops. The CVA6 cookie was not re-run. The TEX opcode
still returns `-26`.

`g6lc_apu_vgpu_tfb` names the `TRANSFER_FROM_HOST_3D` box as
`(0,0,64,64)` of resource 4 at 640 by 480. A 640 by 480 box
records nothing. A 64 by 64 resource records nothing. A shifted
origin records nothing. This is later than `g6lc_apu_vgpu_rox`.
The image is not kept. TEX is not the compiler opcode. This is
not Mesa `glReadPixels`. `g6lc_apu_vgpu_avail` still rejects
`NEXT`. `TfbEn` defaults to 0 and does not make virgl legal.
Remote 2026-09-30, shared with the command and the packed stride:
`tb_g6lc_apu_vgpu_tfb` 20 cases / 79 checks / 117 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 18 ports and no
cells; Enable=1 is 658 cells / 6 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_tfr` reads that command from guest beats at
`64'h88080000`. Beat 0 is the header and the box origin. Beat 1
is the 64 by 64 size and resource 4. Beat 2 is packed stride 256.
A 640-wide box, resource 1, or a failed beat stops the read. A
second store keeps the first. This is not `g6lc_apu_vgpu_rdb`.
`TfrEn` defaults to 0 and does not make virgl legal. The same
remote run, `tb_g6lc_apu_vgpu_tfb`, errors=0. Fixture synth, no
latches: Enable=0 is 20 ports and no cells; Enable=1 is 1,368
cells / 331 flip-flops. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vgpu_tfx` requires that packed stride to be 256. The
640-wide resource row is 2560 and records nothing. A second store
keeps the first. `TfxEn` defaults to 0 and does not make virgl
legal. The same remote run, `tb_g6lc_apu_vgpu_tfb`, errors=0.
Fixture synth, no latches: Enable=0 is 11 ports and no cells;
Enable=1 is 513 cells / 101 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_rab` names `RESOURCE_ATTACH_BACKING` of the 64 by
64 readpixels buffer at `64'h88070000`. Length is 16384. A
1,228,800-byte attach records nothing. This is later than
`g6lc_apu_vgpu_tfx`. This is not `g6lc_apu_vgpu_back` and not
`g6lc_apu_attach`. The image is not kept. TEX is not the compiler
opcode. This is not Mesa `glReadPixels`. `g6lc_apu_vgpu_avail`
still rejects `NEXT`. `RabEn` defaults to 0 and does not make
virgl legal. Remote 2026-09-30, shared with the command and the
crop length: `tb_g6lc_apu_vgpu_rab` 19 cases / 76 checks / 107
clocks, errors=0. Fixture synth, no latches: Enable=0 is 14 ports
and no cells; Enable=1 is 551 cells / 6 flip-flops. The CVA6
cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_rar` reads that command from guest beats at
`64'h88090000`. Beat 0 is the header, resource 4, and one entry.
Beat 1 is address `64'h88070000` and length 16384. A 1,228,800-byte
length, resource 1, or a failed beat stops the read. A second
store keeps the first. This is not `g6lc_apu_vgpu_back`. `RarEn`
defaults to 0 and does not make virgl legal. The same remote run,
`tb_g6lc_apu_vgpu_rab`, errors=0. Fixture synth, no latches:
Enable=0 is 20 ports and no cells; Enable=1 is 1,358 cells / 331
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_rax` requires that length to be 16384. The 640 by
480 backing is 1,228,800 and records nothing. A second store
keeps the first. `RaxEn` defaults to 0 and does not make virgl
legal. The same remote run, `tb_g6lc_apu_vgpu_rab`, errors=0.
Fixture synth, no latches: Enable=0 is 11 ports and no cells;
Enable=1 is 517 cells / 133 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_rfw` writes the 24-byte virtio `OK_NODATA` of the
64 by 64 `TRANSFER_FROM_HOST_3D` at `64'h880A0000`. The fence is
2. The scene fence `64'h1122334455667788` is a different word.
This is later than `g6lc_apu_vgpu_rax`. This is not
`g6lc_apu_vgpu_gcw` and not `g6lc_apu_vgpu_rsp`. The image is not
kept. TEX is not the compiler opcode. This is not Mesa
`glReadPixels`. `g6lc_apu_vgpu_avail` still rejects `NEXT`.
`RfwEn` defaults to 0 and does not make virgl legal. Remote
2026-09-30, shared with the echo and the fence: `tb_g6lc_apu_vgpu_rfw`
15 cases / 68 checks / 88 clocks, errors=0. Fixture synth, no
latches: Enable=0 is 20 ports and no cells; Enable=1 is 447 cells
/ 9 flip-flops. The CVA6 cookie was not re-run. The TEX opcode
still returns `-26`.

`g6lc_apu_vgpu_rfr` reads that 24-byte response. A missing fence
bit or the scene fence records nothing. A second store keeps the
first. This is not `g6lc_apu_vgpu_gcr`. `RfrEn` defaults to 0 and
does not make virgl legal. The same remote run,
`tb_g6lc_apu_vgpu_rfw`, errors=0. Fixture synth, no latches:
Enable=0 is 20 ports and no cells; Enable=1 is 1,506 cells / 330
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_rfx` requires fence 2. The scene fence records
nothing. A second store keeps the first. `RfxEn` defaults to 0
and does not make virgl legal. The same remote run,
`tb_g6lc_apu_vgpu_rfw`, errors=0. Fixture synth, no latches:
Enable=0 is 10 ports and no cells; Enable=1 is 649 cells / 133
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_tuw` writes the used element of the 64 by 64
`TRANSFER_FROM_HOST_3D` at `64'h880B0000` and `used.idx` 2 at
`64'h880B0008`. Descriptor id is 1. The scene element at
`64'h8800E400` and index 1 are different words. This is later than
`g6lc_apu_vgpu_rfx`. This is not `g6lc_apu_vgpu_gcw` and not
`g6lc_apu_vgpu_suw`. The image is not kept. TEX is not the
compiler opcode. This is not Mesa `glReadPixels`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. `TuwEn` defaults to 0
and does not make virgl legal. Remote 2026-09-30, shared with the
echo and the index: `tb_g6lc_apu_vgpu_tuw` 16 cases / 72 checks /
105 clocks, errors=0. Fixture synth, no latches: Enable=0 is 19
ports and no cells; Enable=1 is 475 cells / 11 flip-flops. The
CVA6 cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_tur` reads that used element and index. Descriptor
0 or index 1 records nothing. A second store keeps the first.
This is not `g6lc_apu_vgpu_gcr`. `TurEn` defaults to 0 and does
not make virgl legal. The same remote run, `tb_g6lc_apu_vgpu_tuw`,
errors=0. Fixture synth, no latches: Enable=0 is 20 ports and no
cells; Enable=1 is 909 cells / 171 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_tux` requires `used.idx` 2. The scene index 1
records nothing. A second store keeps the first. `TuxEn` defaults
to 0 and does not make virgl legal. The same remote run,
`tb_g6lc_apu_vgpu_tuw`, errors=0. Fixture synth, no latches:
Enable=0 is 10 ports and no cells; Enable=1 is 307 cells / 53
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_tiw` writes the used-buffer interrupt reason
`32'h1` at `64'h880C0000` and raises the pin after `used.idx` 2.
Ack lowers the pin and leaves the record. A cancel before the
beat writes nothing. This is later than `g6lc_apu_vgpu_tux`. This
is not `g6lc_apu_vgpu_viw` and not PLIC source 9. The image is not
kept. TEX is not the compiler opcode. This is not Mesa
`glReadPixels`. `g6lc_apu_vgpu_avail` still rejects `NEXT`.
`TiwEn` defaults to 0 and does not make virgl legal. Remote
2026-09-30, shared with the echo and the keep: `tb_g6lc_apu_vgpu_tiw`
15 cases / 70 checks / 86 clocks, errors=0. Fixture synth, no
latches: Enable=0 is 22 ports and no cells; Enable=1 is 349 cells
/ 8 flip-flops. The CVA6 cookie was not re-run. The TEX opcode
still returns `-26`.

`g6lc_apu_vgpu_tir` reads that reason. A zero word or the scene
status address `64'h8800E500` records nothing. A second store
keeps the first. This is not `g6lc_apu_vgpu_vir`. `TirEn`
defaults to 0 and does not make virgl legal. The same remote run,
`tb_g6lc_apu_vgpu_tiw`, errors=0. Fixture synth, no latches:
Enable=0 is 20 ports and no cells; Enable=1 is 617 cells / 88
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_tix` requires reason `32'h1` at `64'h880C0000` with
`used.idx` 2. The scene status word records nothing. A second
store keeps the first. `TixEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_tiw`,
errors=0. Fixture synth, no latches: Enable=0 is 11 ports and no
cells; Enable=1 is 401 cells / 117 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_taw` reads the guest ack at `64'h880C0010`. The low
word must be `32'h1`. Then it writes `32'h0` over the status word
at `64'h880C0000`. A config-only ack or a zero ack writes
nothing. A cancel before the read writes nothing. This is later
than `g6lc_apu_vgpu_tix`. This is not `g6lc_apu_vgpu_vaw` and not
PLIC source 9. The image is not kept. TEX is not the compiler
opcode. This is not Mesa `glReadPixels`. `g6lc_apu_vgpu_avail`
still rejects `NEXT`. `TawEn` defaults to 0 and does not make
virgl legal. Remote 2026-09-30, shared with the echo and the
keep: `tb_g6lc_apu_vgpu_taw` 23 cases / 101 checks / 130 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 29 ports and no
cells; Enable=1 is 489 cells / 7 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_tar` reads that ack and the cleared status. The ack
low word stays `32'h1`. The status low word is `32'h0`. The scene
ack at `64'h8800E510` records nothing. A second store keeps the
first. This is not `g6lc_apu_vgpu_var`. `TarEn` defaults to 0 and
does not make virgl legal. The same remote run,
`tb_g6lc_apu_vgpu_taw`, errors=0. Fixture synth, no latches:
Enable=0 is 20 ports and no cells; Enable=1 is 834 cells / 155
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_tax` requires ack `32'h1` and remain 0 with
`used.idx` 2. The scene ack and index 1 record nothing. A second
store keeps the first. `TaxEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_taw`,
errors=0. Fixture synth, no latches: Enable=0 is 11 ports and no
cells; Enable=1 is 567 cells / 85 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_txc` reads the 64 by 64 transfer descriptor chain
from guest memory after the interrupt is acked. Beat 0 at
`64'h880D0000` is attach `64'h88090000` with `NEXT` to the
transfer at `64'h88080000`. Beat 1 is the 24-byte `WRITE` at
`64'h880A0000`. Beat 2 at `64'h880D0100` is avail index 2 naming
descriptor 0. `INDIRECT`, a broken link, and the scene index
record nothing. This is later than `g6lc_apu_vgpu_tax`. This is
not `g6lc_apu_vgpu_avail`, not `g6lc_apu_vgpu_chn`, and not
`g6lc_apu_vgpu_nxc`. `g6lc_apu_vgpu_avail` still rejects `NEXT`.
The image is not kept. TEX is not the compiler opcode. This is
not Mesa `glReadPixels`. `TxcEn` defaults to 0 and does not make
virgl legal. Remote 2026-09-30, shared with the keep and the
check: `tb_g6lc_apu_vgpu_txc` 23 cases / 98 checks / 144 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 21 ports and no
cells; Enable=1 is 2045 cells / 523 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_txk` keeps that chain's head, avail index 2,
attach, transfer, and response. A second store keeps the first.
The descriptor bytes are not kept. This is not
`g6lc_apu_vgpu_nxk`. `TxkEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_txc`,
errors=0. Fixture synth, no latches: Enable=0 is 12 ports and no
cells; Enable=1 is 848 cells / 261 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_txx` requires avail index 2 with attach at
`64'h88090000`. The scene table at `64'h8800E100` and index 1
record nothing. A second store keeps the first. `TxxEn` defaults
to 0 and does not make virgl legal. The same remote run,
`tb_g6lc_apu_vgpu_txc`, errors=0. Fixture synth, no latches:
Enable=0 is 11 ports and no cells; Enable=1 is 471 cells / 101
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_ftx` names TEX of sampler view 5 on resource 1.
`(0,0)` is the clamp texel `32'hA5000000`. `(1,0)` is the half
blend `32'hD2008000`. `refused` is 0. The clear word records
nothing. This is later than `g6lc_apu_vgpu_den` and later than
`g6lc_apu_vgpu_acx`. The compiler TEX opcode still returns `-26`.
This is not `g6lc_apu_tgsi_compile`. The sample was read from the
backing. The image is not kept. This is not Mesa `glReadPixels`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. `FtxEn` defaults to 0
and does not make virgl legal. Remote 2026-09-30, shared with the
keep and the check: `tb_g6lc_apu_vgpu_ftx` 19 cases / 79 checks /
83 clocks, errors=0. Fixture synth, no latches: Enable=0 is 10
ports and no cells; Enable=1 is 523 cells / 133 flip-flops. The
CVA6 cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_ftr` keeps that TEX result. `refused` stays 0. The
clear word and a refused sample record nothing. A second store
keeps the first. This is not `g6lc_apu_vgpu_den`. `FtrEn`
defaults to 0 and does not make virgl legal. The same remote run,
`tb_g6lc_apu_vgpu_ftx`, errors=0. Fixture synth, no latches:
Enable=0 is 11 ports and no cells; Enable=1 is 531 cells / 133
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_ftk` requires `refused` 0 and origin
`32'hA5000000`, not the clear word. A refused sample records
nothing. A second store keeps the first. This is not
`g6lc_apu_vgpu_dnr`. `FtkEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_ftx`,
errors=0. Fixture synth, no latches: Enable=0 is 11 ports and no
cells; Enable=1 is 406 cells / 69 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_ocw` writes that TEX pair into beat 0 of the 64 by
64 scene window at `64'h88020000`. Lane 0 is `(0,0)`, the clamp
texel. Lane 1 is `(1,0)`, the half blend. The other 511 beats are
not stored. A 64-high scissor records nothing. This is later than
`g6lc_apu_vgpu_ftk` and later than `g6lc_apu_vgpu_gpw`. This is
not `g6lc_apu_vgpu_acw`. The compiler TEX opcode still returns
`-26`. The image is not kept. This is not Mesa `glReadPixels`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. `OcwEn` defaults to 0
and does not make virgl legal. Remote 2026-09-30, shared with the
echo and the keep: `tb_g6lc_apu_vgpu_ocw` 23 cases / 103 checks /
120 clocks, errors=0. Fixture synth, no latches: Enable=0 is 19
ports and no cells; Enable=1 is 558 cells / 137 flip-flops. The
CVA6 cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_ocr` reads that beat. Both words are the TEX pair,
not the clear color. The fragment-color beat at `64'h88050000`
records nothing. A second store keeps the first. This is not
`g6lc_apu_vgpu_acr`. `OcrEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_ocw`,
errors=0. Fixture synth, no latches: Enable=0 is 21 ports and no
cells; Enable=1 is 1121 cells / 137 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_ocx` requires byte 0 of `(0,0)` to be sample red
`8'h00`. The word is not the clear color. A clear red, a blue, or
a high first byte records nothing. A second store keeps the
first. This is not `g6lc_apu_vgpu_acx`. `OcxEn` defaults to 0 and
does not make virgl legal. The same remote run,
`tb_g6lc_apu_vgpu_ocw`, errors=0. Fixture synth, no latches:
Enable=0 is 10 ports and no cells; Enable=1 is 548 cells / 155
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_pbw` writes that TEX pair into beat 0 of the guest
readback at `64'h88030000`. Lane 0 is `(0,0)`, the clamp texel.
Lane 1 is `(1,0)`, the half blend. The other 511 beats are not
stored. A 64-high scissor records nothing. This is later than
`g6lc_apu_vgpu_ocx` and later than `g6lc_apu_vgpu_gbw`. This is
not `g6lc_apu_vgpu_ocw`. The compiler TEX opcode still returns
`-26`. The image is not kept. This is not Mesa `glReadPixels`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. `PbwEn` defaults to 0
and does not make virgl legal. Remote 2026-09-30, shared with the
echo and the keep: `tb_g6lc_apu_vgpu_pbw` 23 cases / 103 checks /
120 clocks, errors=0. Fixture synth, no latches: Enable=0 is 19
ports and no cells; Enable=1 is 595 cells / 137 flip-flops. The
CVA6 cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_pbr` reads that beat. Both words are the TEX pair,
not the clear color. The scene window at `64'h88020000` records
nothing as this destination. A second store keeps the first.
This is not `g6lc_apu_vgpu_ocr`. `PbrEn` defaults to 0 and does
not make virgl legal. The same remote run, `tb_g6lc_apu_vgpu_pbw`,
errors=0. Fixture synth, no latches: Enable=0 is 21 ports and no
cells; Enable=1 is 1117 cells / 137 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_pbx` requires byte 0 of `(0,0)` in that readback to
be sample red `8'h00`. The word is not the clear color. A clear
red, a blue, or a high first byte records nothing. A second
store keeps the first. This is not `g6lc_apu_vgpu_ocx`. `PbxEn`
defaults to 0 and does not make virgl legal. The same remote run,
`tb_g6lc_apu_vgpu_pbw`, errors=0. Fixture synth, no latches:
Enable=0 is 10 ports and no cells; Enable=1 is 546 cells / 155
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_tnw` is a posted walker of the 64 by 64 transfer
chain. Descriptors 0 and 1 carry `NEXT`. Descriptor 2 is
`WRITE`. Avail index 2 names descriptor 0. Device index starts at
1. The scene chain at avail index 1 records nothing. This is
later than `g6lc_apu_vgpu_txx`. This is not `g6lc_apu_vgpu_avail`,
not `g6lc_apu_vgpu_chn`, and not `g6lc_apu_vgpu_txc`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. This does not read
guest memory. The image is not kept. The compiler TEX opcode
still returns `-26`. This is not Mesa `glReadPixels`. `TnwEn`
defaults to 0 and does not make virgl legal. Remote 2026-09-30,
shared with the keep and the check: `tb_g6lc_apu_vgpu_tnw` 29
cases / 105 checks / 123 clocks, errors=0. Fixture synth, no
latches: Enable=0 is 12 ports and no cells; Enable=1 is 1406
cells / 634 flip-flops. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vgpu_tnk` keeps that walked chain. Avail index 2. The
scene index 1 and the scene table record nothing. A second store
keeps the first. This is not `g6lc_apu_vgpu_chn`. `TnkEn`
defaults to 0 and does not make virgl legal. The same remote run,
`tb_g6lc_apu_vgpu_tnw`, errors=0. Fixture synth, no latches:
Enable=0 is 10 ports and no cells; Enable=1 is 580 cells / 245
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_tnx` requires avail index 2 with `NEXT` accepted.
The scene index 1 and the scene table at `64'h8800E100` record
nothing. A second store keeps the first. This is not
`g6lc_apu_vgpu_avail`. `TnxEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_tnw`,
errors=0. Fixture synth, no latches: Enable=0 is 11 ports and no
cells; Enable=1 is 312 cells / 101 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_qnt` writes QueueNotify of control queue 0 at
`64'h880D0200` after that walk. The word is `32'd0`. The cursor
queue records nothing. A cancel before the beat writes nothing.
This is later than `g6lc_apu_vgpu_tnx`. This is not
`g6lc_apu_virtio_mmio`. `g6lc_apu_vgpu_avail` still rejects
`NEXT`. The image is not kept. The compiler TEX opcode still
returns `-26`. This is not Mesa `glReadPixels`. `QntEn` defaults
to 0 and does not make virgl legal. Remote 2026-09-30, shared
with the echo and the keep: `tb_g6lc_apu_vgpu_qnt` 17 cases /
77 checks / 93 clocks, errors=0. Fixture synth, no latches:
Enable=0 is 19 ports and no cells; Enable=1 is 310 cells / 9
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_qnr` reads that notify word. The low word is
control queue 0. The cursor queue and the avail ring at
`64'h880D0100` record nothing. A second store keeps the first.
This is later than `g6lc_apu_vgpu_qnt`. This is not
`g6lc_apu_virtio_mmio`. `QnrEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_qnt`,
errors=0. Fixture synth, no latches: Enable=0 is 20 ports and no
cells; Enable=1 is 473 cells / 73 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_qnx` requires control queue 0 after avail index 2.
The cursor queue and the scene index 1 record nothing. A second
store keeps the first. This is later than `g6lc_apu_vgpu_qnr`.
This is not `g6lc_apu_virtio_mmio`. `QnxEn` defaults to 0 and
does not make virgl legal. The same remote run,
`tb_g6lc_apu_vgpu_qnt`, errors=0. Fixture synth, no latches:
Enable=0 is 11 ports and no cells; Enable=1 is 293 cells / 53
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_qav` reads `virtq_avail.idx` at `64'h880D0100`
after that QueueNotify. The word is index 2. The scene ring at
`64'h8800E200` and index 1 record nothing. This is later than
`g6lc_apu_vgpu_qnx`. This is not `g6lc_apu_vgpu_avail` and not
`g6lc_apu_vgpu_txc`. `g6lc_apu_vgpu_avail` still rejects `NEXT`.
The image is not kept. The compiler TEX opcode still returns
`-26`. This is not Mesa `glReadPixels`. `QavEn` defaults to 0
and does not make virgl legal. Remote 2026-09-30, shared with
the keep and the check: `tb_g6lc_apu_vgpu_qav` 17 cases / 74
checks / 87 clocks, errors=0. Fixture synth, no latches:
Enable=0 is 19 ports and no cells; Enable=1 is 357 cells / 41
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_qak` keeps that avail index. Index 2. The scene
ring and index 1 record nothing. A second store keeps the first.
This is later than `g6lc_apu_vgpu_qav`. This is not
`g6lc_apu_vgpu_txc`. `QakEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_qav`,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and no
cells; Enable=1 is 271 cells / 85 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_qax` requires avail index 2 at `64'h880D0100`.
The scene index 1 and the scene ring record nothing. A second
store keeps the first. This is later than `g6lc_apu_vgpu_qak`.
This is not `g6lc_apu_vgpu_avail`. `QaxEn` defaults to 0 and
does not make virgl legal. The same remote run,
`tb_g6lc_apu_vgpu_qav`, errors=0. Fixture synth, no latches:
Enable=0 is 11 ports and no cells; Enable=1 is 249 cells / 21
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_qrg` reads `virtq_avail.ring[0]` at `64'h880D0104`
after that index. The entry names descriptor 0. The scene ring
at `64'h8800E204` and a nonzero id record nothing. This is later
than `g6lc_apu_vgpu_qax`. This is not `g6lc_apu_vgpu_avail` and
not `g6lc_apu_vgpu_txc`. `g6lc_apu_vgpu_avail` still rejects
`NEXT`. The image is not kept. The compiler TEX opcode still
returns `-26`. This is not Mesa `glReadPixels`. `QrgEn` defaults
to 0 and does not make virgl legal. Remote 2026-09-30, shared
with the keep and the check: `tb_g6lc_apu_vgpu_qrg` 16 cases /
70 checks / 83 clocks, errors=0. Fixture synth, no latches:
Enable=0 is 19 ports and no cells; Enable=1 is 342 cells / 41
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_qrk` keeps that ring name. Descriptor 0. The
scene ring and a nonzero id record nothing. A second store keeps
the first. This is later than `g6lc_apu_vgpu_qrg`. This is not
`g6lc_apu_vgpu_txc`. `QrkEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_qrg`,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and no
cells; Enable=1 is 247 cells / 85 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_qrx` requires ring[0] to name descriptor 0 at
`64'h880D0104`. The scene ring and a nonzero id record nothing.
A second store keeps the first. This is later than
`g6lc_apu_vgpu_qrk`. This is not `g6lc_apu_vgpu_avail`. `QrxEn`
defaults to 0 and does not make virgl legal. The same remote
run, `tb_g6lc_apu_vgpu_qrg`, errors=0. Fixture synth, no
latches: Enable=0 is 11 ports and no cells; Enable=1 is 224
cells / 21 flip-flops. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vgpu_qhd` reads `virtq_desc` 0 at `64'h880D0000` after
that ring name. The attach is at `64'h88090000`, length 64,
`NEXT` to 1. The scene table at `64'h8800E100`, `INDIRECT`, and
a jump record nothing. This is later than `g6lc_apu_vgpu_qrx`.
This is not `g6lc_apu_vgpu_avail` and not `g6lc_apu_vgpu_txc`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. The image is not
kept. The compiler TEX opcode still returns `-26`. This is not
Mesa `glReadPixels`. `QhdEn` defaults to 0 and does not make
virgl legal. Remote 2026-09-30, shared with the keep and the
check: `tb_g6lc_apu_vgpu_qhd` 17 cases / 74 checks / 90 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 19 ports and no
cells; Enable=1 is 671 cells / 233 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_qhk` keeps that attach descriptor. Address
`64'h88090000`, length 64, `NEXT` to 1. The scene table and a
jump record nothing. A second store keeps the first. This is
later than `g6lc_apu_vgpu_qhd`. This is not `g6lc_apu_vgpu_txc`.
`QhkEn` defaults to 0 and does not make virgl legal. The same
remote run, `tb_g6lc_apu_vgpu_qhd`, errors=0. Fixture synth, no
latches: Enable=0 is 10 ports and no cells; Enable=1 is 309
cells / 117 flip-flops. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vgpu_qhx` requires descriptor 0 to be the attach at
`64'h88090000` with `NEXT` to 1. The scene table and a jump
record nothing. A second store keeps the first. This is later
than `g6lc_apu_vgpu_qhk`. This is not `g6lc_apu_vgpu_avail`.
`QhxEn` defaults to 0 and does not make virgl legal. The same
remote run, `tb_g6lc_apu_vgpu_qhd`, errors=0. Fixture synth, no
latches: Enable=0 is 11 ports and no cells; Enable=1 is 438
cells / 85 flip-flops. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vgpu_qfd` reads `virtq_desc` 1 at `64'h880D0010` after
`NEXT` from desc 0. The transfer is at `64'h88080000`, length
96, `NEXT` to 2. The attach descriptor, the scene table,
`INDIRECT`, and `WRITE` record nothing. This is later than
`g6lc_apu_vgpu_qhx`. This is not `g6lc_apu_vgpu_avail` and not
`g6lc_apu_vgpu_txc`. `g6lc_apu_vgpu_avail` still rejects `NEXT`.
The image is not kept. The compiler TEX opcode still returns
`-26`. This is not Mesa `glReadPixels`. `QfdEn` defaults to 0
and does not make virgl legal. Remote 2026-09-30, shared with
the keep and the check: `tb_g6lc_apu_vgpu_qfd` 17 cases / 74
checks / 90 clocks, errors=0. Fixture synth, no latches:
Enable=0 is 19 ports and no cells; Enable=1 is 763 cells / 233
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_qfk` keeps that transfer descriptor. Address
`64'h88080000`, length 96, `NEXT` to 2. The attach descriptor
and a jump record nothing. A second store keeps the first. This
is later than `g6lc_apu_vgpu_qfd`. This is not
`g6lc_apu_vgpu_txc`. `QfkEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_qfd`,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and no
cells; Enable=1 is 298 cells / 117 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_qfx` requires descriptor 1 to be the transfer at
`64'h88080000` with `NEXT` to 2. The attach descriptor and a
jump record nothing. A second store keeps the first. This is
later than `g6lc_apu_vgpu_qfk`. This is not
`g6lc_apu_vgpu_avail`. `QfxEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_qfd`,
errors=0. Fixture synth, no latches: Enable=0 is 11 ports and no
cells; Enable=1 is 428 cells / 85 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_qwd` reads `virtq_desc` 2 at `64'h880D0020` after
`NEXT` from desc 1. The `WRITE` is the 24-byte response at
`64'h880A0000`. The transfer descriptor, the scene table,
`NEXT`, and `INDIRECT` record nothing. This is later than
`g6lc_apu_vgpu_qfx`. This is not `g6lc_apu_vgpu_avail` and not
`g6lc_apu_vgpu_txc`. `g6lc_apu_vgpu_avail` still rejects `NEXT`.
The image is not kept. The compiler TEX opcode still returns
`-26`. This is not Mesa `glReadPixels`. `QwdEn` defaults to 0
and does not make virgl legal. Remote 2026-09-30, shared with
the keep and the check: `tb_g6lc_apu_vgpu_qwd` 17 cases / 74
checks / 90 clocks, errors=0. Fixture synth, no latches:
Enable=0 is 19 ports and no cells; Enable=1 is 739 cells / 201
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_qwk` keeps that `WRITE` descriptor. Address
`64'h880A0000`, length 24. The transfer descriptor and `NEXT`
record nothing. A second store keeps the first. This is later
than `g6lc_apu_vgpu_qwd`. This is not `g6lc_apu_vgpu_txc`.
`QwkEn` defaults to 0 and does not make virgl legal. The same
remote run, `tb_g6lc_apu_vgpu_qwd`, errors=0. Fixture synth, no
latches: Enable=0 is 10 ports and no cells; Enable=1 is 263
cells / 101 flip-flops. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vgpu_qwx` requires descriptor 2 to be the `WRITE` of
the 24-byte response at `64'h880A0000`. The transfer descriptor
and `NEXT` record nothing. A second store keeps the first. This
is later than `g6lc_apu_vgpu_qwk`. This is not
`g6lc_apu_vgpu_avail`. `QwxEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_qwd`,
errors=0. Fixture synth, no latches: Enable=0 is 11 ports and no
cells; Enable=1 is 420 cells / 69 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_qok` writes the 24-byte virtio `OK_NODATA` at
`64'h880A0000` after that named `WRITE`. The fence is 2. The
scene response at `64'h8800A800` and the descriptor table record
nothing. This is later than `g6lc_apu_vgpu_qwx`. This is not
`g6lc_apu_vgpu_rfw`. `g6lc_apu_vgpu_avail` still rejects `NEXT`.
The image is not kept. The compiler TEX opcode still returns
`-26`. This is not Mesa `glReadPixels`. `QokEn` defaults to 0
and does not make virgl legal. Remote 2026-09-30, shared with
the echo and the keep: `tb_g6lc_apu_vgpu_qok` 17 cases / 76
checks / 96 clocks, errors=0. Fixture synth, no latches:
Enable=0 is 18 ports and no cells; Enable=1 is 307 cells / 9
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_qol` reads that response. Fence 2. The scene
fence and a missing fence bit record nothing. A second store
keeps the first. This is later than `g6lc_apu_vgpu_qok`. This is
not `g6lc_apu_vgpu_rfr`. `QolEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_qok`,
errors=0. Fixture synth, no latches: Enable=0 is 20 ports and no
cells; Enable=1 is 1437 cells / 265 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_qox` requires fence 2 `OK_NODATA` at
`64'h880A0000`. The scene fence and the scene response record
nothing. A second store keeps the first. This is later than
`g6lc_apu_vgpu_qol`. This is not `g6lc_apu_vgpu_rfx`. `QoxEn`
defaults to 0 and does not make virgl legal. The same remote
run, `tb_g6lc_apu_vgpu_qok`, errors=0. Fixture synth, no
latches: Enable=0 is 11 ports and no cells; Enable=1 is 687
cells / 101 flip-flops. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vgpu_quw` writes the used element at `64'h880B0000` and
`used.idx` 2 at `64'h880B0008` after that `OK_NODATA`. Descriptor
id is 1. The scene id 0 and index 1 record nothing. This is
later than `g6lc_apu_vgpu_qox`. This is not `g6lc_apu_vgpu_tuw`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. The image is not
kept. The compiler TEX opcode still returns `-26`. This is not
Mesa `glReadPixels`. `QuwEn` defaults to 0 and does not make
virgl legal. Remote 2026-09-30, shared with the echo and the
keep: `tb_g6lc_apu_vgpu_quw` 18 cases / 80 checks / 113 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 18 ports and no
cells; Enable=1 is 383 cells / 11 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_qul` reads that used element and index.
Descriptor 0 or index 1 records nothing. A second store keeps
the first. This is later than `g6lc_apu_vgpu_quw`. This is not
`g6lc_apu_vgpu_tur`. `QulEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_quw`,
errors=0. Fixture synth, no latches: Enable=0 is 20 ports and no
cells; Enable=1 is 909 cells / 171 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_qux` requires `used.idx` 2 and id 1. The scene
index 1 and id 0 record nothing. A second store keeps the first.
This is later than `g6lc_apu_vgpu_qul`. This is not
`g6lc_apu_vgpu_tux`. `QuxEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_quw`,
errors=0. Fixture synth, no latches: Enable=0 is 11 ports and no
cells; Enable=1 is 374 cells / 53 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_qiw` writes the guest used-buffer interrupt
reason `32'h1` at `64'h880C0000` and raises the pin after
`used.idx` 2 of the named chain. Ack lowers the pin and leaves
the record. A cancel before the beat writes nothing. This is
later than `g6lc_apu_vgpu_qux`. This is not `g6lc_apu_vgpu_tiw`,
not `g6lc_apu_vgpu_viw`, and not PLIC source 9. The image is not
kept. TEX is not the compiler opcode. This is not Mesa
`glReadPixels`. `g6lc_apu_vgpu_avail` still rejects `NEXT`.
`QiwEn` defaults to 0 and does not make virgl legal. Remote
2026-09-30, shared with the echo and the keep: `tb_g6lc_apu_vgpu_qiw`
15 cases / 70 checks / 86 clocks, errors=0. Fixture synth, no
latches: Enable=0 is 22 ports and no cells; Enable=1 is 349 cells
/ 8 flip-flops. The CVA6 cookie was not re-run. The TEX opcode
still returns `-26`.

`g6lc_apu_vgpu_qir` reads that reason. A zero word or the scene
status address `64'h8800E500` records nothing. A second store
keeps the first. This is later than `g6lc_apu_vgpu_qiw`. This is
not `g6lc_apu_vgpu_tir` and not `g6lc_apu_vgpu_vir`. `QirEn`
defaults to 0 and does not make virgl legal. The same remote run,
`tb_g6lc_apu_vgpu_qiw`, errors=0. Fixture synth, no latches:
Enable=0 is 20 ports and no cells; Enable=1 is 617 cells / 88
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_qix` requires reason `32'h1` at `64'h880C0000` with
`used.idx` 2. The scene status word records nothing. A second
store keeps the first. This is later than `g6lc_apu_vgpu_qir`.
This is not `g6lc_apu_vgpu_tix`. `QixEn` defaults to 0 and does
not make virgl legal. The same remote run, `tb_g6lc_apu_vgpu_qiw`,
errors=0. Fixture synth, no latches: Enable=0 is 11 ports and no
cells; Enable=1 is 401 cells / 117 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_qaw` reads the guest ack at `64'h880C0010` after
the guest-rung interrupt. The low word must be `32'h1`. Then it
writes `32'h0` over the status word at `64'h880C0000`. A
config-only ack or a zero ack writes nothing. A cancel before the
read writes nothing. This is later than `g6lc_apu_vgpu_qix`. This
is not `g6lc_apu_vgpu_taw`, not `g6lc_apu_vgpu_vaw`, and not PLIC
source 9. The image is not kept. TEX is not the compiler opcode.
This is not Mesa `glReadPixels`. `g6lc_apu_vgpu_avail` still
rejects `NEXT`. `QawEn` defaults to 0 and does not make virgl
legal. Remote 2026-09-30, shared with the echo and the keep:
`tb_g6lc_apu_vgpu_qaw` 23 cases / 101 checks / 130 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 29 ports and no
cells; Enable=1 is 489 cells / 7 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_qar` reads that ack and the cleared status. The ack
low word stays `32'h1`. The status low word is `32'h0`. The scene
ack at `64'h8800E510` records nothing. A second store keeps the
first. This is later than `g6lc_apu_vgpu_qaw`. This is not
`g6lc_apu_vgpu_tar` and not `g6lc_apu_vgpu_var`. `QarEn` defaults
to 0 and does not make virgl legal. The same remote run,
`tb_g6lc_apu_vgpu_qaw`, errors=0. Fixture synth, no latches:
Enable=0 is 20 ports and no cells; Enable=1 is 834 cells / 155
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_qay` requires ack `32'h1` and remain 0 with
`used.idx` 2. The scene ack and index 1 record nothing. A second
store keeps the first. This is later than `g6lc_apu_vgpu_qar`.
This is not `g6lc_apu_vgpu_tax`. `QayEn` defaults to 0 and does
not make virgl legal. The same remote run, `tb_g6lc_apu_vgpu_qaw`,
errors=0. Fixture synth, no latches: Enable=0 is 11 ports and no
cells; Enable=1 is 567 cells / 85 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_qsv` reads scene `virtq_avail.idx` 1 at
`64'h8800E200` after the guest ack of the transfer. The transfer
ring at `64'h880D0100` and index 2 record nothing. This is later
than `g6lc_apu_vgpu_qay`. This is not `g6lc_apu_vgpu_qav`, not
`g6lc_apu_vgpu_avail`, and not `g6lc_apu_vgpu_nxc`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. The image is not kept.
The compiler TEX opcode still returns `-26`. This is not Mesa
`glReadPixels`. `QsvEn` defaults to 0 and does not make virgl
legal. Remote 2026-09-30, shared with the keep and the check:
`tb_g6lc_apu_vgpu_qsv` 17 cases / 74 checks / 87 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 20 ports and no
cells; Enable=1 is 442 cells / 41 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_qsk` keeps that scene index. The transfer ring and
index 2 record nothing. A second store keeps the first. This is
later than `g6lc_apu_vgpu_qsv`. This is not `g6lc_apu_vgpu_qak`.
`QskEn` defaults to 0 and does not make virgl legal. The same
remote run, `tb_g6lc_apu_vgpu_qsv`, errors=0. Fixture synth, no
latches: Enable=0 is 11 ports and no cells; Enable=1 is 290 cells
/ 85 flip-flops. The CVA6 cookie was not re-run. The TEX opcode
still returns `-26`.

`g6lc_apu_vgpu_qsx` requires scene avail index 1 at
`64'h8800E200`. The transfer index 2 records nothing. A second
store keeps the first. This is later than `g6lc_apu_vgpu_qsk`.
This is not `g6lc_apu_vgpu_qax`. `QsxEn` defaults to 0 and does
not make virgl legal. The same remote run, `tb_g6lc_apu_vgpu_qsv`,
errors=0. Fixture synth, no latches: Enable=0 is 12 ports and no
cells; Enable=1 is 268 cells / 21 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_qsr` reads scene `virtq_avail.ring[0]` at
`64'h8800E204` after avail index 1. The entry names descriptor 0.
The transfer ring at `64'h880D0104` and a nonzero id record
nothing. This is later than `g6lc_apu_vgpu_qsx`. This is not
`g6lc_apu_vgpu_qrg`, not `g6lc_apu_vgpu_avail`, and not
`g6lc_apu_vgpu_nxc`. `g6lc_apu_vgpu_avail` still rejects `NEXT`.
The image is not kept. The compiler TEX opcode still returns
`-26`. This is not Mesa `glReadPixels`. `QsrEn` defaults to 0 and
does not make virgl legal. Remote 2026-09-30, shared with the keep
and the check: `tb_g6lc_apu_vgpu_qsr` 16 cases / 70 checks / 83
clocks, errors=0. Fixture synth, no latches: Enable=0 is 19 ports
and no cells; Enable=1 is 341 cells / 41 flip-flops. The CVA6
cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_qsl` keeps that scene ring name. The transfer ring
and a nonzero id record nothing. A second store keeps the first.
This is later than `g6lc_apu_vgpu_qsr`. This is not
`g6lc_apu_vgpu_qrk`. `QslEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_qsr`,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and no
cells; Enable=1 is 247 cells / 85 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_qsy` requires descriptor 0 at `64'h8800E204`. The
transfer ring records nothing. A second store keeps the first.
This is later than `g6lc_apu_vgpu_qsl`. This is not
`g6lc_apu_vgpu_qrx`. `QsyEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_qsr`,
errors=0. Fixture synth, no latches: Enable=0 is 11 ports and no
cells; Enable=1 is 224 cells / 21 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_qsd` reads scene `virtq_desc` 0 at `64'h8800E100`
after ring[0] names it. The header is at `64'h8800A000`, length
32, `NEXT` to 1. The transfer table at `64'h880D0000`,
`INDIRECT`, and a jump record nothing. This is later than
`g6lc_apu_vgpu_qsy`. This is not `g6lc_apu_vgpu_qhd`, not
`g6lc_apu_vgpu_avail`, and not `g6lc_apu_vgpu_nxc`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. The image is not kept.
The compiler TEX opcode still returns `-26`. This is not Mesa
`glReadPixels`. `QsdEn` defaults to 0 and does not make virgl
legal. Remote 2026-09-30, shared with the keep and the check:
`tb_g6lc_apu_vgpu_qsd` 17 cases / 74 checks / 90 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 19 ports and no
cells; Enable=1 is 670 cells / 233 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_qse` keeps that scene header descriptor. The
transfer table and a jump record nothing. A second store keeps
the first. This is later than `g6lc_apu_vgpu_qsd`. This is not
`g6lc_apu_vgpu_qhk`. `QseEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_qsd`,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and no
cells; Enable=1 is 306 cells / 117 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_qsf` requires the header at `64'h8800A000` with
`NEXT` to 1. The transfer table records nothing. A second store
keeps the first. This is later than `g6lc_apu_vgpu_qse`. This is
not `g6lc_apu_vgpu_qhx`. `QsfEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_qsd`,
errors=0. Fixture synth, no latches: Enable=0 is 11 ports and no
cells; Enable=1 is 434 cells / 85 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_qed` reads scene `virtq_desc` 1 at `64'h8800E110`
after `NEXT` from desc 0. The execbuffer is at `64'h8800B000`,
length 960, `NEXT` to 2. The header descriptor, the transfer
table, `INDIRECT`, and `WRITE` record nothing. This is later than
`g6lc_apu_vgpu_qsf`. This is not `g6lc_apu_vgpu_qfd`, not
`g6lc_apu_vgpu_avail`, and not `g6lc_apu_vgpu_nxc`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. The image is not kept.
The compiler TEX opcode still returns `-26`. This is not Mesa
`glReadPixels`. `QedEn` defaults to 0 and does not make virgl
legal. Remote 2026-09-30, shared with the keep and the check:
`tb_g6lc_apu_vgpu_qed` 17 cases / 74 checks / 90 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 19 ports and no
cells; Enable=1 is 791 cells / 233 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_qek` keeps that scene execbuffer descriptor. The
header descriptor and a jump record nothing. A second store keeps
the first. This is later than `g6lc_apu_vgpu_qed`. This is not
`g6lc_apu_vgpu_qfk`. `QekEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_qed`,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and no
cells; Enable=1 is 306 cells / 117 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_qex` requires the execbuffer at `64'h8800B000` with
`NEXT` to 2. The header descriptor records nothing. A second
store keeps the first. This is later than `g6lc_apu_vgpu_qek`.
This is not `g6lc_apu_vgpu_qfx`. `QexEn` defaults to 0 and does
not make virgl legal. The same remote run, `tb_g6lc_apu_vgpu_qed`,
errors=0. Fixture synth, no latches: Enable=0 is 11 ports and no
cells; Enable=1 is 431 cells / 85 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_qrs` reads scene `virtq_desc` 2 at `64'h8800E120`
after `NEXT` from desc 1. The `WRITE` is the 24-byte response at
`64'h8800A800`. The execbuffer descriptor, the transfer table,
`NEXT`, and `INDIRECT` record nothing. This is later than
`g6lc_apu_vgpu_qex`. This is not `g6lc_apu_vgpu_qwd`, not
`g6lc_apu_vgpu_avail`, and not `g6lc_apu_vgpu_nxc`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. The image is not kept.
The compiler TEX opcode still returns `-26`. This is not Mesa
`glReadPixels`. `QrsEn` defaults to 0 and does not make virgl
legal. Remote 2026-09-30, shared with the keep and the check:
`tb_g6lc_apu_vgpu_qrs` 17 cases / 74 checks / 90 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 19 ports and no
cells; Enable=1 is 761 cells / 201 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_qrt` keeps that scene `WRITE` descriptor. The
execbuffer descriptor and `NEXT` record nothing. A second store
keeps the first. This is later than `g6lc_apu_vgpu_qrs`. This is
not `g6lc_apu_vgpu_qwk`. `QrtEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_qrs`,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and no
cells; Enable=1 is 279 cells / 101 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_qru` requires the `WRITE` of the 24-byte response
at `64'h8800A800`. The execbuffer descriptor records nothing. A
second store keeps the first. This is later than
`g6lc_apu_vgpu_qrt`. This is not `g6lc_apu_vgpu_qwx`. `QruEn`
defaults to 0 and does not make virgl legal. The same remote run,
`tb_g6lc_apu_vgpu_qrs`, errors=0. Fixture synth, no latches:
Enable=0 is 11 ports and no cells; Enable=1 is 431 cells / 69
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_qso` writes the 24-byte virtio `OK_NODATA` at
`64'h8800A800` after that named `WRITE`. The fence is the scene
fence. The transfer response at `64'h880A0000` and fence 2
record nothing. This is later than `g6lc_apu_vgpu_qru`. This is
not `g6lc_apu_vgpu_qok` and not `g6lc_apu_vgpu_gcw`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. The image is not kept.
The compiler TEX opcode still returns `-26`. This is not Mesa
`glReadPixels`. `QsoEn` defaults to 0 and does not make virgl
legal. Remote 2026-09-30, shared with the echo and the keep:
`tb_g6lc_apu_vgpu_qso` 17 cases / 76 checks / 96 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 18 ports and no
cells; Enable=1 is 312 cells / 9 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_qsp` reads that response. Scene fence. Fence 2
and a missing fence bit record nothing. A second store keeps the
first. This is later than `g6lc_apu_vgpu_qso`. This is not
`g6lc_apu_vgpu_qol`. `QspEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_qso`,
errors=0. Fixture synth, no latches: Enable=0 is 20 ports and no
cells; Enable=1 is 1438 cells / 265 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_qsq` requires the scene fence `OK_NODATA` at
`64'h8800A800`. Fence 2 and the transfer response record
nothing. A second store keeps the first. This is later than
`g6lc_apu_vgpu_qsp`. This is not `g6lc_apu_vgpu_qox`. `QsqEn`
defaults to 0 and does not make virgl legal. The same remote
run, `tb_g6lc_apu_vgpu_qso`, errors=0. Fixture synth, no
latches: Enable=0 is 11 ports and no cells; Enable=1 is 688
cells / 101 flip-flops. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vgpu_qsu` writes the used element at `64'h8800E400` and
`used.idx` 1 at `64'h8800E480` after that `OK_NODATA`. Descriptor
id is 0. The transfer id 1 and index 2 record nothing. This is
later than `g6lc_apu_vgpu_qsq`. This is not `g6lc_apu_vgpu_quw`
and not `g6lc_apu_vgpu_gcw`. `g6lc_apu_vgpu_avail` still rejects
`NEXT`. The image is not kept. The compiler TEX opcode still
returns `-26`. This is not Mesa `glReadPixels`. `QsuEn` defaults
to 0 and does not make virgl legal. Remote 2026-09-30, shared
with the echo and the keep: `tb_g6lc_apu_vgpu_qsu` 18 cases / 80
checks / 113 clocks, errors=0. Fixture synth, no latches:
Enable=0 is 18 ports and no cells; Enable=1 is 383 cells / 11
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_qst` reads that element and index. Id 1 or index 2
records nothing. A second store keeps the first. This is later
than `g6lc_apu_vgpu_qsu`. This is not `g6lc_apu_vgpu_qul`.
`QstEn` defaults to 0 and does not make virgl legal. The same
remote run, `tb_g6lc_apu_vgpu_qsu`, errors=0. Fixture synth, no
latches: Enable=0 is 20 ports and no cells; Enable=1 is 936
cells / 171 flip-flops. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vgpu_qsz` requires `used.idx` 1 and id 0. The transfer
index 2 and id 1 record nothing. A second store keeps the first.
This is later than `g6lc_apu_vgpu_qst`. This is not
`g6lc_apu_vgpu_qux`. `QszEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_qsu`,
errors=0. Fixture synth, no latches: Enable=0 is 11 ports and no
cells; Enable=1 is 398 cells / 53 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_qsi` writes the used-buffer interrupt reason
`32'h1` at `64'h8800E500` after that index and raises the pin.
Ack lowers it. The transfer status at `64'h880C0000` records
nothing. This is later than `g6lc_apu_vgpu_qsz`. This is not
`g6lc_apu_vgpu_qiw` and not `g6lc_apu_vgpu_viw`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. The image is not kept.
The compiler TEX opcode still returns `-26`. This is not Mesa
`glReadPixels`. `QsiEn` defaults to 0 and does not make virgl
legal. Remote 2026-09-30, shared with the echo and the keep:
`tb_g6lc_apu_vgpu_qsi` 15 cases / 70 checks / 86 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 22 ports and no
cells; Enable=1 is 349 cells / 8 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_qsn` reads that reason. A zero reason records
nothing. A second store keeps the first. This is later than
`g6lc_apu_vgpu_qsi`. This is not `g6lc_apu_vgpu_qir`. `QsnEn`
defaults to 0 and does not make virgl legal. The same remote
run, `tb_g6lc_apu_vgpu_qsi`, errors=0. Fixture synth, no
latches: Enable=0 is 20 ports and no cells; Enable=1 is 617
cells / 88 flip-flops. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vgpu_qsm` requires reason `32'h1` with `used.idx` 1 at
`64'h8800E500`. Index 2 and the transfer status record nothing.
A second store keeps the first. This is later than
`g6lc_apu_vgpu_qsn`. This is not `g6lc_apu_vgpu_qix`. `QsmEn`
defaults to 0 and does not make virgl legal. The same remote
run, `tb_g6lc_apu_vgpu_qsi`, errors=0. Fixture synth, no
latches: Enable=0 is 11 ports and no cells; Enable=1 is 401
cells / 117 flip-flops. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vgpu_qga` reads the guest ack at `64'h8800E510` after
that interrupt. The low word is `32'h1`. Remain 0 is then written
over `64'h8800E500`. A config ack or a zero ack writes nothing.
The transfer ack at `64'h880C0010` records nothing. This is later
than `g6lc_apu_vgpu_qsm`. This is not `g6lc_apu_vgpu_qaw` and not
`g6lc_apu_vgpu_vaw`. `g6lc_apu_vgpu_avail` still rejects `NEXT`.
The image is not kept. The compiler TEX opcode still returns
`-26`. This is not Mesa `glReadPixels`. `QgaEn` defaults to 0 and
does not make virgl legal. Remote 2026-09-30, shared with the
echo and the keep: `tb_g6lc_apu_vgpu_qga` 23 cases / 101 checks /
130 clocks, errors=0. Fixture synth, no latches: Enable=0 is 29
ports and no cells; Enable=1 is 489 cells / 7 flip-flops. The
CVA6 cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_qgk` reads that ack and remain. A second store
keeps the first. This is later than `g6lc_apu_vgpu_qga`. This is
not `g6lc_apu_vgpu_qar`. `QgkEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_qga`,
errors=0. Fixture synth, no latches: Enable=0 is 20 ports and no
cells; Enable=1 is 837 cells / 155 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_qgx` requires ack `32'h1` and remain 0 with
`used.idx` 1. Index 2 and the transfer ack record nothing. A
second store keeps the first. This is later than
`g6lc_apu_vgpu_qgk`. This is not `g6lc_apu_vgpu_qay`. `QgxEn`
defaults to 0 and does not make virgl legal. The same remote
run, `tb_g6lc_apu_vgpu_qga`, errors=0. Fixture synth, no
latches: Enable=0 is 11 ports and no cells; Enable=1 is 570
cells / 85 flip-flops. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vgpu_snw` is a posted walker of the scene submit chain.
Descriptors 0 and 1 carry `NEXT`. Descriptor 2 is `WRITE`. Avail
index 1 names descriptor 0. Device index starts at 0. The
transfer chain at avail index 2 records nothing. This is later
than `g6lc_apu_vgpu_qgx`. This is not `g6lc_apu_vgpu_tnw`, not
`g6lc_apu_vgpu_chn`, and not `g6lc_apu_vgpu_avail`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. This does not read
guest memory. The image is not kept. The compiler TEX opcode
still returns `-26`. This is not Mesa `glReadPixels`. `SnwEn`
defaults to 0 and does not make virgl legal. Remote 2026-09-30,
shared with the keep and the check: `tb_g6lc_apu_vgpu_snw` 29
cases / 105 checks / 123 clocks, errors=0. Fixture synth, no
latches: Enable=0 is 12 ports and no cells; Enable=1 is 1,305
cells / 633 flip-flops. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vgpu_snk` keeps that walked scene chain. Avail index 1.
The transfer index 2 and the transfer table record nothing. A
second store keeps the first. This is later than
`g6lc_apu_vgpu_snw`. This is not `g6lc_apu_vgpu_tnk`. `SnkEn`
defaults to 0 and does not make virgl legal. The same remote
run, `tb_g6lc_apu_vgpu_snw`, errors=0. Fixture synth, no
latches: Enable=0 is 10 ports and no cells; Enable=1 is 579
cells / 245 flip-flops. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vgpu_snx` requires avail index 1 with `NEXT` accepted.
Index 2 and the transfer table record nothing. A second store
keeps the first. This is later than `g6lc_apu_vgpu_snk`. This is
not `g6lc_apu_vgpu_tnx`. `SnxEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_snw`,
errors=0. Fixture synth, no latches: Enable=0 is 11 ports and no
cells; Enable=1 is 309 cells / 101 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_snt` writes QueueNotify of control queue 0 at
`64'h8800E220` after that walker. The cursor queue and the
transfer doorbell at `64'h880D0200` record nothing. A cancel
before the beat writes nothing. This is later than
`g6lc_apu_vgpu_snx`. This is not `g6lc_apu_vgpu_qnt` and not
`g6lc_apu_virtio_mmio`. `g6lc_apu_vgpu_avail` still rejects
`NEXT`. The image is not kept. The compiler TEX opcode still
returns `-26`. This is not Mesa `glReadPixels`. `SntEn` defaults
to 0 and does not make virgl legal. Remote 2026-09-30, shared
with the echo and the keep: `tb_g6lc_apu_vgpu_snt` 17 cases / 77
checks / 93 clocks, errors=0. Fixture synth, no latches:
Enable=0 is 19 ports and no cells; Enable=1 is 313 cells / 9
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_snr` reads that notify word. Control queue 0. The
cursor queue records nothing. A second store keeps the first.
This is later than `g6lc_apu_vgpu_snt`. This is not
`g6lc_apu_vgpu_qnr`. `SnrEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_snt`,
errors=0. Fixture synth, no latches: Enable=0 is 20 ports and no
cells; Enable=1 is 492 cells / 73 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_sny` requires control queue 0 after avail index 1.
Index 2 and the cursor queue record nothing. A second store
keeps the first. This is later than `g6lc_apu_vgpu_snr`. This is
not `g6lc_apu_vgpu_qnx`. `SnyEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_snt`,
errors=0. Fixture synth, no latches: Enable=0 is 11 ports and no
cells; Enable=1 is 294 cells / 53 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_sav` reads `virtq_avail.idx` at `64'h8800E200`
after that scene QueueNotify. The word is index 1. The transfer
ring at `64'h880D0100` and index 2 record nothing. This is later
than `g6lc_apu_vgpu_sny`. This is not `g6lc_apu_vgpu_qav`, not
`g6lc_apu_vgpu_qsv`, and not `g6lc_apu_vgpu_avail`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. The image is not
kept. The compiler TEX opcode still returns `-26`. This is not
Mesa `glReadPixels`. `SavEn` defaults to 0 and does not make
virgl legal. Remote 2026-09-30, shared with the keep and the
check: `tb_g6lc_apu_vgpu_sav` 17 cases / 74 checks / 87 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 19 ports and no
cells; Enable=1 is 357 cells / 41 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_sak` keeps that scene avail index. Index 1. The
transfer ring and index 2 record nothing. A second store keeps
the first. This is later than `g6lc_apu_vgpu_sav`. This is not
`g6lc_apu_vgpu_qak` and not `g6lc_apu_vgpu_qsv`. `SakEn` defaults
to 0 and does not make virgl legal. The same remote run,
`tb_g6lc_apu_vgpu_sav`, errors=0. Fixture synth, no latches:
Enable=0 is 10 ports and no cells; Enable=1 is 271 cells / 85
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_sax` requires avail index 1 at `64'h8800E200`
after that notify. Index 2 and the transfer ring record nothing.
A second store keeps the first. This is later than
`g6lc_apu_vgpu_sak`. This is not `g6lc_apu_vgpu_qax` and not
`g6lc_apu_vgpu_avail`. `SaxEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_sav`,
errors=0. Fixture synth, no latches: Enable=0 is 11 ports and no
cells; Enable=1 is 249 cells / 21 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_srg` reads `virtq_avail.ring[0]` at `64'h8800E204`
after that scene index. The entry names descriptor 0. The
transfer ring at `64'h880D0104` and a nonzero id record nothing.
This is later than `g6lc_apu_vgpu_sax`. This is not
`g6lc_apu_vgpu_qrg`, not `g6lc_apu_vgpu_qsr`, and not
`g6lc_apu_vgpu_avail`. `g6lc_apu_vgpu_avail` still rejects
`NEXT`. The image is not kept. The compiler TEX opcode still
returns `-26`. This is not Mesa `glReadPixels`. `SrgEn` defaults
to 0 and does not make virgl legal. Remote 2026-09-30, shared
with the keep and the check: `tb_g6lc_apu_vgpu_srg` 16 cases /
70 checks / 83 clocks, errors=0. Fixture synth, no latches:
Enable=0 is 19 ports and no cells; Enable=1 is 341 cells / 41
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_srk` keeps that scene ring name. Descriptor 0.
The transfer ring and a nonzero id record nothing. A second
store keeps the first. This is later than `g6lc_apu_vgpu_srg`.
This is not `g6lc_apu_vgpu_qrk` and not `g6lc_apu_vgpu_qsr`.
`SrkEn` defaults to 0 and does not make virgl legal. The same
remote run, `tb_g6lc_apu_vgpu_srg`, errors=0. Fixture synth, no
latches: Enable=0 is 10 ports and no cells; Enable=1 is 247
cells / 85 flip-flops. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vgpu_srx` requires descriptor 0 at `64'h8800E204` after
that notify. The transfer ring and a nonzero id record nothing.
A second store keeps the first. This is later than
`g6lc_apu_vgpu_srk`. This is not `g6lc_apu_vgpu_qrx` and not
`g6lc_apu_vgpu_avail`. `SrxEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_srg`,
errors=0. Fixture synth, no latches: Enable=0 is 11 ports and no
cells; Enable=1 is 224 cells / 21 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_shd` reads `virtq_desc` 0 at `64'h8800E100` after
that ring name. The header is at `64'h8800A000`, length 32,
`NEXT` to 1. The transfer table at `64'h880D0000`, `INDIRECT`,
and a jump record nothing. This is later than
`g6lc_apu_vgpu_srx`. This is not `g6lc_apu_vgpu_qhd`, not
`g6lc_apu_vgpu_qsd`, and not `g6lc_apu_vgpu_avail`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. The image is not
kept. The compiler TEX opcode still returns `-26`. This is not
Mesa `glReadPixels`. `ShdEn` defaults to 0 and does not make
virgl legal. Remote 2026-09-30, shared with the keep and the
check: `tb_g6lc_apu_vgpu_shd` 17 cases / 74 checks / 90 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 19 ports and no
cells; Enable=1 is 670 cells / 233 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_shk` keeps that scene header descriptor. Header at
`64'h8800A000`, length 32, `NEXT` to 1. The transfer table and a
jump record nothing. A second store keeps the first. This is
later than `g6lc_apu_vgpu_shd`. This is not `g6lc_apu_vgpu_qhk`
and not `g6lc_apu_vgpu_qsd`. `ShkEn` defaults to 0 and does not
make virgl legal. The same remote run, `tb_g6lc_apu_vgpu_shd`,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and no
cells; Enable=1 is 306 cells / 117 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_shx` requires the header at `64'h8800A000` with
`NEXT` to 1. The transfer table and a jump record nothing. A
second store keeps the first. This is later than
`g6lc_apu_vgpu_shk`. This is not `g6lc_apu_vgpu_qhx` and not
`g6lc_apu_vgpu_avail`. `ShxEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_shd`,
errors=0. Fixture synth, no latches: Enable=0 is 11 ports and no
cells; Enable=1 is 434 cells / 85 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_sfd` reads `virtq_desc` 1 at `64'h8800E110` after
that `NEXT`. The execbuffer is at `64'h8800B000`, length 960,
`NEXT` to 2. The header descriptor, the transfer table,
`INDIRECT`, and `WRITE` record nothing. This is later than
`g6lc_apu_vgpu_shx`. This is not `g6lc_apu_vgpu_qfd`, not
`g6lc_apu_vgpu_qed`, and not `g6lc_apu_vgpu_avail`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. The image is not
kept. The compiler TEX opcode still returns `-26`. This is not
Mesa `glReadPixels`. `SfdEn` defaults to 0 and does not make
virgl legal. Remote 2026-09-30, shared with the keep and the
check: `tb_g6lc_apu_vgpu_sfd` 17 cases / 74 checks / 90 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 19 ports and no
cells; Enable=1 is 770 cells / 233 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_sfk` keeps that scene execbuffer descriptor.
Execbuffer at `64'h8800B000`, length 960, `NEXT` to 2. The
header descriptor and a jump record nothing. A second store
keeps the first. This is later than `g6lc_apu_vgpu_sfd`. This is
not `g6lc_apu_vgpu_qfk` and not `g6lc_apu_vgpu_qed`. `SfkEn`
defaults to 0 and does not make virgl legal. The same remote
run, `tb_g6lc_apu_vgpu_sfd`, errors=0. Fixture synth, no
latches: Enable=0 is 10 ports and no cells; Enable=1 is 306
cells / 117 flip-flops. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vgpu_sfx` requires the execbuffer at `64'h8800B000`
with `NEXT` to 2. The header descriptor and a jump record
nothing. A second store keeps the first. This is later than
`g6lc_apu_vgpu_sfk`. This is not `g6lc_apu_vgpu_qfx` and not
`g6lc_apu_vgpu_avail`. `SfxEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_sfd`,
errors=0. Fixture synth, no latches: Enable=0 is 11 ports and no
cells; Enable=1 is 431 cells / 85 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_swd` reads `virtq_desc` 2 at `64'h8800E120` after
that `NEXT`. The `WRITE` is the 24-byte response at
`64'h8800A800`. The execbuffer descriptor, the transfer table,
`NEXT`, and `INDIRECT` record nothing. This is later than
`g6lc_apu_vgpu_sfx`. This is not `g6lc_apu_vgpu_qwd`, not
`g6lc_apu_vgpu_qrs`, and not `g6lc_apu_vgpu_avail`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. The image is not
kept. The compiler TEX opcode still returns `-26`. This is not
Mesa `glReadPixels`. `SwdEn` defaults to 0 and does not make
virgl legal. Remote 2026-09-30, shared with the keep and the
check: `tb_g6lc_apu_vgpu_swd` 17 cases / 74 checks / 90 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 19 ports and no
cells; Enable=1 is 751 cells / 201 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_swk` keeps that scene `WRITE` descriptor. Response
at `64'h8800A800`, length 24. The execbuffer descriptor and
`NEXT` record nothing. A second store keeps the first. This is
later than `g6lc_apu_vgpu_swd`. This is not `g6lc_apu_vgpu_qwk`
and not `g6lc_apu_vgpu_qrs`. `SwkEn` defaults to 0 and does not
make virgl legal. The same remote run, `tb_g6lc_apu_vgpu_swd`,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and no
cells; Enable=1 is 272 cells / 101 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_swx` requires the `WRITE` of the 24-byte response
at `64'h8800A800`. The execbuffer descriptor and `NEXT` record
nothing. A second store keeps the first. This is later than
`g6lc_apu_vgpu_swk`. This is not `g6lc_apu_vgpu_qwx` and not
`g6lc_apu_vgpu_avail`. `SwxEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_swd`,
errors=0. Fixture synth, no latches: Enable=0 is 11 ports and no
cells; Enable=1 is 424 cells / 69 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_sok` writes the 24-byte virtio `OK_NODATA` at
`64'h8800A800` after that named `WRITE`. The fence is the scene
fence, not fence 2. The descriptor table and the transfer
response record nothing. This is later than `g6lc_apu_vgpu_swx`.
This is not `g6lc_apu_vgpu_qok`, not `g6lc_apu_vgpu_qso`, and
not `g6lc_apu_vgpu_gcw`. `g6lc_apu_vgpu_avail` still rejects
`NEXT`. The image is not kept. The compiler TEX opcode still
returns `-26`. This is not Mesa `glReadPixels`. `SokEn` defaults
to 0 and does not make virgl legal. Remote 2026-09-30, shared
with the keep and the check: `tb_g6lc_apu_vgpu_sok` 17 cases /
76 checks / 96 clocks, errors=0. Fixture synth, no latches:
Enable=0 is 18 ports and no cells; Enable=1 is 312 cells / 9
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_sol` reads that scene `OK_NODATA`. The fence is
the scene fence, not fence 2. A missing fence bit or the
transfer response records nothing. A second store keeps the
first. This is later than `g6lc_apu_vgpu_sok`. This is not
`g6lc_apu_vgpu_qol` and not `g6lc_apu_vgpu_qsp`. `SolEn`
defaults to 0 and does not make virgl legal. The same remote
run, `tb_g6lc_apu_vgpu_sok`, errors=0. Fixture synth, no
latches: Enable=0 is 20 ports and no cells; Enable=1 is 1,438
cells / 265 flip-flops. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vgpu_sox` requires the scene fence `OK_NODATA` at
`64'h8800A800`. Fence 2 and a missing fence bit record nothing.
A second store keeps the first. This is later than
`g6lc_apu_vgpu_sol`. This is not `g6lc_apu_vgpu_qox` and not
`g6lc_apu_vgpu_qsq`. `SoxEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_sok`,
errors=0. Fixture synth, no latches: Enable=0 is 11 ports and no
cells; Enable=1 is 688 cells / 101 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_slw` writes the used element at `64'h8800E400` and
`used.idx` 1 at `64'h8800E480` after that scene `OK_NODATA`.
Descriptor id is 0, not the transfer's 1. This is later than
`g6lc_apu_vgpu_sox`. This is not `g6lc_apu_vgpu_quw`, not
`g6lc_apu_vgpu_qsu`, and not `g6lc_apu_vgpu_gcw`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. The image is not
kept. The compiler TEX opcode still returns `-26`. This is not
Mesa `glReadPixels`. `SlwEn` defaults to 0 and does not make
virgl legal. Remote 2026-09-30, shared with the keep and the
check: `tb_g6lc_apu_vgpu_slw` 18 cases / 80 checks / 113 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 18 ports and no
cells; Enable=1 is 383 cells / 11 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_sll` reads that scene used element and index.
Descriptor 1 or index 2 records nothing. A second store keeps
the first. This is later than `g6lc_apu_vgpu_slw`. This is not
`g6lc_apu_vgpu_qul` and not `g6lc_apu_vgpu_qst`. `SllEn`
defaults to 0 and does not make virgl legal. The same remote
run, `tb_g6lc_apu_vgpu_slw`, errors=0. Fixture synth, no
latches: Enable=0 is 20 ports and no cells; Enable=1 is 936
cells / 171 flip-flops. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vgpu_slx` requires `used.idx` 1 after that scene
`OK_NODATA`. The transfer index 2 and descriptor id 1 record
nothing. A second store keeps the first. This is later than
`g6lc_apu_vgpu_sll`. This is not `g6lc_apu_vgpu_qux` and not
`g6lc_apu_vgpu_qsz`. `SlxEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_slw`,
errors=0. Fixture synth, no latches: Enable=0 is 11 ports and no
cells; Enable=1 is 398 cells / 53 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_siw` writes the used-buffer interrupt reason
`32'h1` at `64'h8800E500` after that scene used ring after
QueueNotify and raises the pin. Ack lowers it. The transfer
status at `64'h880C0000` records nothing. This is later than
`g6lc_apu_vgpu_slx`. This is not `g6lc_apu_vgpu_qsi`, not
`g6lc_apu_vgpu_qiw`, and not `g6lc_apu_vgpu_viw`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. The image is not kept.
The compiler TEX opcode still returns `-26`. This is not Mesa
`glReadPixels`. `SiwEn` defaults to 0 and does not make virgl
legal. Remote 2026-09-30, shared with the echo and the keep:
`tb_g6lc_apu_vgpu_siw` 15 cases / 70 checks / 86 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 22 ports and no
cells; Enable=1 is 349 cells / 8 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_sir` reads that reason. A zero reason records
nothing. A second store keeps the first. This is later than
`g6lc_apu_vgpu_siw`. This is not `g6lc_apu_vgpu_qsn` and not
`g6lc_apu_vgpu_qir`. `SirEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_siw`,
errors=0. Fixture synth, no latches: Enable=0 is 20 ports and no
cells; Enable=1 is 617 cells / 88 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_six` requires reason `32'h1` with `used.idx` 1 at
`64'h8800E500` after QueueNotify. Index 2 and the transfer
status record nothing. A second store keeps the first. This is
later than `g6lc_apu_vgpu_sir`. This is not `g6lc_apu_vgpu_qsm`
and not `g6lc_apu_vgpu_qix`. `SixEn` defaults to 0 and does not
make virgl legal. The same remote run, `tb_g6lc_apu_vgpu_siw`,
errors=0. Fixture synth, no latches: Enable=0 is 11 ports and no
cells; Enable=1 is 401 cells / 117 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_sga` reads the guest ack at `64'h8800E510` after
that interrupt after QueueNotify. The low word is `32'h1`.
Remain 0 is then written over `64'h8800E500`. A config ack or a
zero ack writes nothing. The transfer ack at `64'h880C0010`
records nothing. This is later than `g6lc_apu_vgpu_six`. This is
not `g6lc_apu_vgpu_qga`, not `g6lc_apu_vgpu_qaw`, and not
`g6lc_apu_vgpu_vaw`. `g6lc_apu_vgpu_avail` still rejects `NEXT`.
The image is not kept. The compiler TEX opcode still returns
`-26`. This is not Mesa `glReadPixels`. `SgaEn` defaults to 0 and
does not make virgl legal. Remote 2026-09-30, shared with the
echo and the keep: `tb_g6lc_apu_vgpu_sga` 23 cases / 101 checks /
130 clocks, errors=0. Fixture synth, no latches: Enable=0 is 29
ports and no cells; Enable=1 is 489 cells / 7 flip-flops. The
CVA6 cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_sgk` reads that ack and remain. A second store
keeps the first. This is later than `g6lc_apu_vgpu_sga`. This is
not `g6lc_apu_vgpu_qgk` and not `g6lc_apu_vgpu_qar`. `SgkEn`
defaults to 0 and does not make virgl legal. The same remote
run, `tb_g6lc_apu_vgpu_sga`, errors=0. Fixture synth, no
latches: Enable=0 is 20 ports and no cells; Enable=1 is 837
cells / 155 flip-flops. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vgpu_sgx` requires ack `32'h1` and remain 0 with
`used.idx` 1 after QueueNotify. Index 2 and the transfer ack
record nothing. A second store keeps the first. This is later
than `g6lc_apu_vgpu_sgk`. This is not `g6lc_apu_vgpu_qgx` and
not `g6lc_apu_vgpu_qay`. `SgxEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_sga`,
errors=0. Fixture synth, no latches: Enable=0 is 11 ports and no
cells; Enable=1 is 570 cells / 85 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_rnw` is a posted walker of the 64 by 64 transfer
chain after that scene guest ack. Descriptors 0 and 1 carry
`NEXT`. Descriptor 2 is `WRITE`. Avail index 2 names descriptor
0. Device index starts at 1. The scene chain at avail index 1
records nothing. This is later than `g6lc_apu_vgpu_sgx`. This is
not `g6lc_apu_vgpu_tnw`, not `g6lc_apu_vgpu_snw`, not
`g6lc_apu_vgpu_chn`, and not `g6lc_apu_vgpu_avail`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. This does not read
guest memory. The image is not kept. The compiler TEX opcode
still returns `-26`. This is not Mesa `glReadPixels`. `RnwEn`
defaults to 0 and does not make virgl legal. Remote 2026-10-01,
shared with the keep and the check: `tb_g6lc_apu_vgpu_rnw` 29
cases / 105 checks / 123 clocks, errors=0. Fixture synth, no
latches: Enable=0 is 12 ports and no cells; Enable=1 is 1,368
cells / 634 flip-flops. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vgpu_rnk` keeps that walked transfer chain. Avail
index 2. The scene index 1 and the scene table record nothing.
A second store keeps the first. This is later than
`g6lc_apu_vgpu_rnw`. This is not `g6lc_apu_vgpu_tnk`. `RnkEn`
defaults to 0 and does not make virgl legal. The same remote
run, `tb_g6lc_apu_vgpu_rnw`, errors=0. Fixture synth, no
latches: Enable=0 is 10 ports and no cells; Enable=1 is 598
cells / 245 flip-flops. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vgpu_rnx` requires avail index 2 with `NEXT` accepted
after scene guest ack. Index 1 and the scene table record
nothing. A second store keeps the first. This is later than
`g6lc_apu_vgpu_rnk`. This is not `g6lc_apu_vgpu_tnx`. `RnxEn`
defaults to 0 and does not make virgl legal. The same remote
run, `tb_g6lc_apu_vgpu_rnw`, errors=0. Fixture synth, no
latches: Enable=0 is 11 ports and no cells; Enable=1 is 312
cells / 101 flip-flops. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vgpu_rnt` writes QueueNotify of control queue 0 at
`64'h880D0200` after that walker. The cursor queue and the
scene doorbell at `64'h8800E220` record nothing. A cancel
before the beat writes nothing. This is later than
`g6lc_apu_vgpu_rnx`. This is not `g6lc_apu_vgpu_qnt`, not
`g6lc_apu_vgpu_snt`, and not `g6lc_apu_virtio_mmio`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. The image is not
kept. The compiler TEX opcode still returns `-26`. This is not
Mesa `glReadPixels`. `RntEn` defaults to 0 and does not make
virgl legal. Remote 2026-10-01, shared with the echo and the
keep: `tb_g6lc_apu_vgpu_rnt` 17 cases / 77 checks / 93 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 19 ports and no
cells; Enable=1 is 334 cells / 9 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_rnr` reads that notify word. Control queue 0. The
cursor queue and the scene doorbell record nothing. A second
store keeps the first. This is later than `g6lc_apu_vgpu_rnt`.
This is not `g6lc_apu_vgpu_qnr`. `RnrEn` defaults to 0 and does
not make virgl legal. The same remote run,
`tb_g6lc_apu_vgpu_rnt`, errors=0. Fixture synth, no latches:
Enable=0 is 20 ports and no cells; Enable=1 is 518 cells / 73
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_rny` requires control queue 0 after avail index 2
after scene guest ack. The cursor queue and scene index 1
record nothing. A second store keeps the first. This is later
than `g6lc_apu_vgpu_rnr`. This is not `g6lc_apu_vgpu_qnx`.
`RnyEn` defaults to 0 and does not make virgl legal. The same
remote run, `tb_g6lc_apu_vgpu_rnt`, errors=0. Fixture synth, no
latches: Enable=0 is 11 ports and no cells; Enable=1 is 293
cells / 53 flip-flops. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vgpu_rav` reads `virtq_avail.idx` 2 at `64'h880D0100`
after that QueueNotify after scene guest ack. The scene ring at
`64'h8800E200` and index 1 record nothing. This is later than
`g6lc_apu_vgpu_rny`. This is not `g6lc_apu_vgpu_qav`, not
`g6lc_apu_vgpu_sav`, and not `g6lc_apu_vgpu_avail`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. The image is not
kept. The compiler TEX opcode still returns `-26`. This is not
Mesa `glReadPixels`. `RavEn` defaults to 0 and does not make
virgl legal. Remote 2026-10-01, shared with the keep and the
check: `tb_g6lc_apu_vgpu_rav` 17 cases / 74 checks / 87 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 19 ports and no
cells; Enable=1 is 357 cells / 41 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_rak` keeps that avail index. Index 1 and the
scene ring record nothing. A second store keeps the first. This
is later than `g6lc_apu_vgpu_rav`. This is not
`g6lc_apu_vgpu_qak`. `RakEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_rav`,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and no
cells; Enable=1 is 271 cells / 85 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_ray` requires avail index 2 at `64'h880D0100`
after scene guest ack. Index 1 records nothing. A second store
keeps the first. This is later than `g6lc_apu_vgpu_rak`. This is
not `g6lc_apu_vgpu_qax`. `RayEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_rav`,
errors=0. Fixture synth, no latches: Enable=0 is 11 ports and no
cells; Enable=1 is 249 cells / 21 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_rrg` reads `virtq_avail.ring[0]` at `64'h880D0104`
after that index after scene guest ack. The entry names
descriptor 0. The scene ring at `64'h8800E204` and a nonzero id
record nothing. This is later than `g6lc_apu_vgpu_ray`. This is
not `g6lc_apu_vgpu_qrg`, not `g6lc_apu_vgpu_srg`, and not
`g6lc_apu_vgpu_avail`. `g6lc_apu_vgpu_avail` still rejects
`NEXT`. The image is not kept. The compiler TEX opcode still
returns `-26`. This is not Mesa `glReadPixels`. `RrgEn` defaults
to 0 and does not make virgl legal. Remote 2026-10-01, shared
with the keep and the check: `tb_g6lc_apu_vgpu_rrg` 16 cases /
70 checks / 83 clocks, errors=0. Fixture synth, no latches:
Enable=0 is 19 ports and no cells; Enable=1 is 342 cells / 41
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_rrk` keeps that ring name. A nonzero id and the
scene ring record nothing. A second store keeps the first. This
is later than `g6lc_apu_vgpu_rrg`. This is not
`g6lc_apu_vgpu_qrk`. `RrkEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_rrg`,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and no
cells; Enable=1 is 247 cells / 85 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_rrx` requires descriptor 0 at `64'h880D0104`
after scene guest ack. A nonzero id records nothing. A second
store keeps the first. This is later than `g6lc_apu_vgpu_rrk`.
This is not `g6lc_apu_vgpu_qrx`. `RrxEn` defaults to 0 and does
not make virgl legal. The same remote run,
`tb_g6lc_apu_vgpu_rrg`, errors=0. Fixture synth, no latches:
Enable=0 is 11 ports and no cells; Enable=1 is 224 cells / 21
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_rhd` reads `virtq_desc` 0 at `64'h880D0000` after
that ring name after scene guest ack. The attach is at
`64'h88090000`, length 64, `NEXT` to 1. The scene table at
`64'h8800E100`, `INDIRECT`, and a jump record nothing. This is
later than `g6lc_apu_vgpu_rrx`. This is not `g6lc_apu_vgpu_qhd`,
not `g6lc_apu_vgpu_shd`, and not `g6lc_apu_vgpu_avail`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. The image is not
kept. The compiler TEX opcode still returns `-26`. This is not
Mesa `glReadPixels`. `RhdEn` defaults to 0 and does not make
virgl legal. Remote 2026-10-01, shared with the keep and the
check: `tb_g6lc_apu_vgpu_rhd` 17 cases / 74 checks / 90 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 19 ports and no
cells; Enable=1 is 671 cells / 233 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_rhk` keeps that attach descriptor. The scene
table and a jump record nothing. A second store keeps the
first. This is later than `g6lc_apu_vgpu_rhd`. This is not
`g6lc_apu_vgpu_qhk`. `RhkEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_rhd`,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and no
cells; Enable=1 is 309 cells / 117 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_rhx` requires the attach at `64'h88090000` with
`NEXT` to 1 after scene guest ack. The scene table and a jump
record nothing. A second store keeps the first. This is later
than `g6lc_apu_vgpu_rhk`. This is not `g6lc_apu_vgpu_qhx`.
`RhxEn` defaults to 0 and does not make virgl legal. The same
remote run, `tb_g6lc_apu_vgpu_rhd`, errors=0. Fixture synth, no
latches: Enable=0 is 11 ports and no cells; Enable=1 is 438
cells / 85 flip-flops. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vgpu_rfd` reads `virtq_desc` 1 at `64'h880D0010` after
that `NEXT` after scene guest ack. The transfer is at
`64'h88080000`, length 96, `NEXT` to 2. The attach descriptor,
the scene table, `INDIRECT`, and `WRITE` record nothing. This
is later than `g6lc_apu_vgpu_rhx`. This is not
`g6lc_apu_vgpu_qfd`, not `g6lc_apu_vgpu_sfd`, and not
`g6lc_apu_vgpu_avail`. `g6lc_apu_vgpu_avail` still rejects
`NEXT`. The image is not kept. The compiler TEX opcode still
returns `-26`. This is not Mesa `glReadPixels`. `RfdEn` defaults
to 0 and does not make virgl legal. Remote 2026-10-01, shared
with the keep and the check: `tb_g6lc_apu_vgpu_rfd` 17 cases /
74 checks / 90 clocks, errors=0. Fixture synth, no latches:
Enable=0 is 19 ports and no cells; Enable=1 is 763 cells / 233
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_rfk` keeps that transfer descriptor. The attach
descriptor and a jump record nothing. A second store keeps the
first. This is later than `g6lc_apu_vgpu_rfd`. This is not
`g6lc_apu_vgpu_qfk`. `RfkEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_rfd`,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and no
cells; Enable=1 is 298 cells / 117 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_rfy` requires the transfer at `64'h88080000` with
`NEXT` to 2 after scene guest ack. The attach descriptor and a
jump record nothing. A second store keeps the first. This is
later than `g6lc_apu_vgpu_rfk`. This is not `g6lc_apu_vgpu_qfx`
and not `g6lc_apu_vgpu_rfx`. `RfyEn` defaults to 0 and does not
make virgl legal. The same remote run, `tb_g6lc_apu_vgpu_rfd`,
errors=0. Fixture synth, no latches: Enable=0 is 11 ports and no
cells; Enable=1 is 428 cells / 85 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_rwd` reads `virtq_desc` 2 at `64'h880D0020` after
that `NEXT` after scene guest ack. The `WRITE` is the 24-byte
response at `64'h880A0000`. The transfer descriptor, the scene
table, `NEXT`, and `INDIRECT` record nothing. This is later than
`g6lc_apu_vgpu_rfy`. This is not `g6lc_apu_vgpu_qwd`, not
`g6lc_apu_vgpu_swd`, and not `g6lc_apu_vgpu_avail`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. The image is not
kept. The compiler TEX opcode still returns `-26`. This is not
Mesa `glReadPixels`. `RwdEn` defaults to 0 and does not make
virgl legal. Remote 2026-10-01, shared with the keep and the
check: `tb_g6lc_apu_vgpu_rwd` 17 cases / 74 checks / 90 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 19 ports and no
cells; Enable=1 is 739 cells / 201 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_rwk` keeps that `WRITE` descriptor. The transfer
descriptor and `NEXT` record nothing. A second store keeps the
first. This is later than `g6lc_apu_vgpu_rwd`. This is not
`g6lc_apu_vgpu_qwk`. `RwkEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_rwd`,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and no
cells; Enable=1 is 263 cells / 101 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_rwx` requires the `WRITE` of the 24-byte response
at `64'h880A0000` after scene guest ack. The transfer descriptor
and `NEXT` record nothing. A second store keeps the first. This
is later than `g6lc_apu_vgpu_rwk`. This is not
`g6lc_apu_vgpu_qwx`. `RwxEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_rwd`,
errors=0. Fixture synth, no latches: Enable=0 is 11 ports and no
cells; Enable=1 is 420 cells / 69 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_rok` writes the 24-byte virtio `OK_NODATA` at
`64'h880A0000` after that named `WRITE` after scene guest ack.
The fence is 2. The scene response at `64'h8800A800` and the
descriptor table record nothing. This is later than
`g6lc_apu_vgpu_rwx`. This is not `g6lc_apu_vgpu_qok`, not
`g6lc_apu_vgpu_sok`, and not `g6lc_apu_vgpu_rfw`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. The image is not
kept. The compiler TEX opcode still returns `-26`. This is not
Mesa `glReadPixels`. `RokEn` defaults to 0 and does not make
virgl legal. Remote 2026-10-01, shared with the echo and the
keep: `tb_g6lc_apu_vgpu_rok` 17 cases / 76 checks / 96 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 18 ports and no
cells; Enable=1 is 307 cells / 9 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_rol` reads that response. Fence 2. The scene
fence and a missing fence bit record nothing. A second store
keeps the first. This is later than `g6lc_apu_vgpu_rok`. This is
not `g6lc_apu_vgpu_qol`. `RolEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_rok`,
errors=0. Fixture synth, no latches: Enable=0 is 20 ports and no
cells; Enable=1 is 1437 cells / 265 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_roy` requires fence 2 `OK_NODATA` at
`64'h880A0000` after scene guest ack. The scene fence and the
scene response record nothing. A second store keeps the first.
This is later than `g6lc_apu_vgpu_rol`. This is not
`g6lc_apu_vgpu_qox` and not `g6lc_apu_vgpu_rox`. `RoyEn` defaults
to 0 and does not make virgl legal. The same remote run,
`tb_g6lc_apu_vgpu_rok`, errors=0. Fixture synth, no latches:
Enable=0 is 11 ports and no cells; Enable=1 is 687 cells / 101
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_ruw` writes the used element at `64'h880B0000` and
`used.idx` 2 at `64'h880B0008` after that `OK_NODATA` after scene
guest ack. Descriptor id is 1. The scene id 0 and index 1 record
nothing. This is later than `g6lc_apu_vgpu_roy`. This is not
`g6lc_apu_vgpu_quw`, not `g6lc_apu_vgpu_slw`, and not
`g6lc_apu_vgpu_tuw`. `g6lc_apu_vgpu_avail` still rejects `NEXT`.
The image is not kept. The compiler TEX opcode still returns
`-26`. This is not Mesa `glReadPixels`. `RuwEn` defaults to 0
and does not make virgl legal. Remote 2026-10-01, shared with
the echo and the keep: `tb_g6lc_apu_vgpu_ruw` 18 cases / 80
checks / 113 clocks, errors=0. Fixture synth, no latches:
Enable=0 is 18 ports and no cells; Enable=1 is 383 cells / 11
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_rul` reads that used element and index. Descriptor
0 or index 1 records nothing. A second store keeps the first.
This is later than `g6lc_apu_vgpu_ruw`. This is not
`g6lc_apu_vgpu_qul`. `RulEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_ruw`,
errors=0. Fixture synth, no latches: Enable=0 is 20 ports and no
cells; Enable=1 is 909 cells / 171 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_rux` requires `used.idx` 2 and id 1 after scene
guest ack. The scene index 1 and id 0 record nothing. A second
store keeps the first. This is later than `g6lc_apu_vgpu_rul`.
This is not `g6lc_apu_vgpu_qux`. `RuxEn` defaults to 0 and does
not make virgl legal. The same remote run,
`tb_g6lc_apu_vgpu_ruw`, errors=0. Fixture synth, no latches:
Enable=0 is 11 ports and no cells; Enable=1 is 374 cells / 53
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_riw` writes the guest used-buffer interrupt
reason `32'h1` at `64'h880C0000` and raises the pin after
`used.idx` 2 after scene guest ack. Ack lowers the pin and
leaves the record. A cancel before the beat writes nothing.
This is later than `g6lc_apu_vgpu_rux`. This is not
`g6lc_apu_vgpu_qiw`, not `g6lc_apu_vgpu_siw`, not
`g6lc_apu_vgpu_tiw`, not `g6lc_apu_vgpu_viw`, and not PLIC
source 9. The image is not kept. TEX is not the compiler
opcode. This is not Mesa `glReadPixels`. `g6lc_apu_vgpu_avail`
still rejects `NEXT`. `RiwEn` defaults to 0 and does not make
virgl legal. Remote 2026-10-01, shared with the echo and the
keep: `tb_g6lc_apu_vgpu_riw` 15 cases / 70 checks / 86 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 22 ports and no
cells; Enable=1 is 349 cells / 8 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_rir` reads that reason. A zero word or the scene
status address `64'h8800E500` records nothing. A second store
keeps the first. This is later than `g6lc_apu_vgpu_riw`. This is
not `g6lc_apu_vgpu_qir`. `RirEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_riw`,
errors=0. Fixture synth, no latches: Enable=0 is 20 ports and no
cells; Enable=1 is 617 cells / 88 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_rix` requires reason `32'h1` at `64'h880C0000`
with `used.idx` 2 after scene guest ack. The scene status word
records nothing. A second store keeps the first. This is later
than `g6lc_apu_vgpu_rir`. This is not `g6lc_apu_vgpu_qix`.
`RixEn` defaults to 0 and does not make virgl legal. The same
remote run, `tb_g6lc_apu_vgpu_riw`, errors=0. Fixture synth, no
latches: Enable=0 is 11 ports and no cells; Enable=1 is 401
cells / 117 flip-flops. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vgpu_rga` reads the guest ack at `64'h880C0010` after
that used-buffer interrupt after scene guest ack. The low word
must be `32'h1`. Then it writes remain 0 over `64'h880C0000`. The
scene ack at `64'h8800E510` records nothing. A cancel before the
read writes nothing. This is later than `g6lc_apu_vgpu_rix`.
This is not `g6lc_apu_vgpu_qaw`, not `g6lc_apu_vgpu_sga`, and
not `g6lc_apu_vgpu_taw`. `g6lc_apu_vgpu_avail` still rejects
`NEXT`. The image is not kept. The compiler TEX opcode still
returns `-26`. This is not Mesa `glReadPixels`. `RgaEn` defaults
to 0 and does not make virgl legal. Remote 2026-10-01, shared
with the echo and the keep: `tb_g6lc_apu_vgpu_rga` 23 cases /
101 checks / 130 clocks, errors=0. Fixture synth, no latches:
Enable=0 is 29 ports and no cells; Enable=1 is 489 cells / 7
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_rgk` reads that ack and remain. The scene ack
records nothing. A second store keeps the first. This is later
than `g6lc_apu_vgpu_rga`. This is not `g6lc_apu_vgpu_qar`.
`RgkEn` defaults to 0 and does not make virgl legal. The same
remote run, `tb_g6lc_apu_vgpu_rga`, errors=0. Fixture synth, no
latches: Enable=0 is 20 ports and no cells; Enable=1 is 834
cells / 155 flip-flops. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vgpu_rgx` requires ack `32'h1` and remain 0 with
`used.idx` 2 after scene guest ack. The scene ack and index 1
record nothing. A second store keeps the first. This is later
than `g6lc_apu_vgpu_rgk`. This is not `g6lc_apu_vgpu_qay`.
`RgxEn` defaults to 0 and does not make virgl legal. The same
remote run, `tb_g6lc_apu_vgpu_rga`, errors=0. Fixture synth, no
latches: Enable=0 is 11 ports and no cells; Enable=1 is 567
cells / 85 flip-flops. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vgpu_gtx` names TEX of sampler view 5 after the guest
ack of the transfer chain after scene guest ack. `(0,0)` is the
clamp texel `32'hA5000000`. `(1,0)` is the half blend
`32'hD2008000`. `refused` is 0. `used.idx` is 2. The clear word,
a refused sample, and the scene used index record nothing. This
is later than `g6lc_apu_vgpu_ftk` and later than
`g6lc_apu_vgpu_rgx`. This is not `g6lc_apu_vgpu_ftx` and not
`g6lc_apu_vgpu_den`. The compiler TEX opcode still returns `-26`.
The sample was read from the backing. The image is not kept.
This is not Mesa `glReadPixels`. `g6lc_apu_vgpu_avail` still
rejects `NEXT`. `GtxEn` defaults to 0 and does not make virgl
legal. Remote 2026-10-01, shared with the keep and the check:
`tb_g6lc_apu_vgpu_gtx` 18 cases / 75 checks / 79 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and no
cells; Enable=1 is 415 cells / 85 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_gtr` keeps that TEX result. `refused` stays 0.
`used.idx` stays 2. The clear word, a refused sample, and the
scene used index record nothing. A second store keeps the first.
This is later than `g6lc_apu_vgpu_gtx`. This is not
`g6lc_apu_vgpu_ftr`. `GtrEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_gtx`,
errors=0. Fixture synth, no latches: Enable=0 is 11 ports and no
cells; Enable=1 is 393 cells / 85 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_gtk` requires `refused` 0 and origin
`32'hA5000000` with `used.idx` 2 after that guest ack. A refused
sample or the scene index records nothing. A second store keeps
the first. This is later than `g6lc_apu_vgpu_gtr`. This is not
`g6lc_apu_vgpu_ftk`. `GtkEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_gtx`,
errors=0. Fixture synth, no latches: Enable=0 is 11 ports and no
cells; Enable=1 is 347 cells / 53 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_hcw` writes the TEX sample pair into beat 0 of the
guest `TRANSFER_FROM_HOST_3D` buffer at `64'h88070000` after the
guest ack of the transfer chain after scene guest ack. Lane 0 is
`(0,0)`, the clamp texel. Lane 1 is `(1,0)`, the half blend. The
other 511 beats are not stored. The scene window and the
fragment-color beat record nothing. A 64-high scissor records
nothing. This is later than `g6lc_apu_vgpu_gtk` and later than
`g6lc_apu_vgpu_gtr`. This is not `g6lc_apu_vgpu_ocw`, not
`g6lc_apu_vgpu_pbw`, and not `g6lc_apu_vgpu_rpw`. The compiler
TEX opcode still returns `-26`. The image is not kept. This is
not Mesa `glReadPixels`. `g6lc_apu_vgpu_avail` still rejects
`NEXT`. `HcwEn` defaults to 0 and does not make virgl legal.
Remote 2026-10-01, shared with the echo and the keep:
`tb_g6lc_apu_vgpu_hcw` 23 cases / 103 checks / 120 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 19 ports and no
cells; Enable=1 is 594 cells / 137 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_hcr` reads that beat. Both words are the TEX pair,
not the clear color. The scene window at `64'h88020000` and the
fragment-color beat at `64'h88050000` record nothing. A second
store keeps the first. This is later than `g6lc_apu_vgpu_hcw`.
This is not `g6lc_apu_vgpu_ocr`. `HcrEn` defaults to 0 and does
not make virgl legal. The same remote run,
`tb_g6lc_apu_vgpu_hcw`, errors=0. Fixture synth, no latches:
Enable=0 is 21 ports and no cells; Enable=1 is 1132 cells / 137
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_hcx` requires byte 0 of `(0,0)` in that guest
buffer to be sample red `8'h00`. The word is not the clear
color. A clear red, a blue, or a high first byte records
nothing. A second store keeps the first. This is later than
`g6lc_apu_vgpu_hcr`. This is not `g6lc_apu_vgpu_ocx`. `HcxEn`
defaults to 0 and does not make virgl legal. The same remote
run, `tb_g6lc_apu_vgpu_hcw`, errors=0. Fixture synth, no
latches: Enable=0 is 10 ports and no cells; Enable=1 is 547
cells / 155 flip-flops. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vgpu_wld` names the covered TEX sample after that guest
transfer beat. `(0,0)` is the clamp texel `32'hA5000000` at byte
0. `(1,0)` is the half blend `32'hD2008000` at byte 4. `refused`
is 0. Any other coordinate, the clear word, and a refused sample
record nothing. This is later than `g6lc_apu_vgpu_hcx`. This is
not `g6lc_apu_vgpu_hld`, not `g6lc_apu_vgpu_dnr`, and not
`g6lc_apu_cover`. The compiler TEX opcode still returns `-26`.
The sample was read from the backing. The image is not kept.
This is not Mesa `glReadPixels`. `g6lc_apu_vgpu_avail` still
rejects `NEXT`. `WldEn` defaults to 0 and does not make virgl
legal. Remote 2026-10-01, shared with the keep and the check:
`tb_g6lc_apu_vgpu_wld` 17 cases / 71 checks / 75 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 11 ports and no
cells; Enable=1 is 418 cells / 39 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_wlr` keeps that covered sample. `refused` stays 0.
The clear word and a coordinate outside the pair record nothing.
A second store keeps the first. This is later than
`g6lc_apu_vgpu_wld`. This is not `g6lc_apu_vgpu_hld`. `WlrEn`
defaults to 0 and does not make virgl legal. The same remote
run, `tb_g6lc_apu_vgpu_wld`, errors=0. Fixture synth, no
latches: Enable=0 is 10 ports and no cells; Enable=1 is 291
cells / 65 flip-flops. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vgpu_wlk` requires `refused` 0 and a held word that is
the clamp texel or the half blend, not the clear word. A refused
sample records nothing. A second store keeps the first. This is
later than `g6lc_apu_vgpu_wlr`. This is not `g6lc_apu_vgpu_dnr`.
`WlkEn` defaults to 0 and does not make virgl legal. The same
remote run, `tb_g6lc_apu_vgpu_wld`, errors=0. Fixture synth, no
latches: Enable=0 is 11 ports and no cells; Enable=1 is 349
cells / 51 flip-flops. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vgpu_cyr` names the four channels of that covered TEX
sample. Byte 0 is red. The clamp texel `32'hA5000000` is the
bytes 00 00 00 A5. The half blend `32'hD2008000` is the bytes 00
80 00 D2. The clear channels 0D 0D 1A FF record nothing. This is
later than `g6lc_apu_vgpu_wlk`. This is not `g6lc_apu_vgpu_byr`.
The compiler TEX opcode still returns `-26`. The image is not
kept. This is not Mesa `glReadPixels`. `g6lc_apu_vgpu_avail`
still rejects `NEXT`. `CyrEn` defaults to 0 and does not make
virgl legal. Remote 2026-10-01, shared with the keep and the
check: `tb_g6lc_apu_vgpu_cyr` 15 cases / 63 checks / 67 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 9 ports and no
cells; Enable=1 is 189 cells / 51 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_cyk` keeps those four channels. A second store
keeps the first. The clear channels record nothing. This is
later than `g6lc_apu_vgpu_cyr`. This is not `g6lc_apu_vgpu_byk`.
`CykEn` defaults to 0 and does not make virgl legal. The same
remote run, `tb_g6lc_apu_vgpu_cyr`, errors=0. Fixture synth, no
latches: Enable=0 is 10 ports and no cells; Enable=1 is 313
cells / 83 flip-flops. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vgpu_cyx` requires byte 0 to be red `8'h00`. A first
byte of the clear red `8'h0D` or of `8'hFF` records nothing. A
second store keeps the first. This is later than
`g6lc_apu_vgpu_cyk`. This is not `g6lc_apu_vgpu_byx`. `CyxEn`
defaults to 0 and does not make virgl legal. The same remote
run, `tb_g6lc_apu_vgpu_cyr`, errors=0. Fixture synth, no
latches: Enable=0 is 11 ports and no cells; Enable=1 is 242
cells / 53 flip-flops. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vgpu_gnw` walks the scene `NEXT` chain from guest memory
after QueueNotify of control queue 0. Descriptor 0 is the 32-byte
header, descriptor 1 is the 960-byte execbuffer, descriptor 2 is
the `WRITE` of the 24-byte response. Avail index 1 names descriptor
0. The walk consumes device index 1. The transfer table, `INDIRECT`,
a broken link, and a jumped index record nothing. This is later
than `g6lc_apu_vgpu_sny`. This is not `g6lc_apu_vgpu_avail`, not
`g6lc_apu_vgpu_chn`, and not `g6lc_apu_vgpu_nxc`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. The compiler TEX opcode
still returns `-26`. The image is not kept. This is not Mesa
`glReadPixels`. `GnwEn` defaults to 0 and does not make virgl legal.
Remote 2026-10-01, shared with the keep and the check:
`tb_g6lc_apu_vgpu_gnw` 26 cases / 107 checks / 155 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 19 ports and no cells;
Enable=1 is 1557 cells / 396 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_gnk` keeps that guest-rung chain. Avail index 1,
consumed device index 1, the execbuffer, and the response. A
second store keeps the first. The transfer table records nothing.
This is later than `g6lc_apu_vgpu_gnw`. This is not
`g6lc_apu_vgpu_nxk`. `GnkEn` defaults to 0 and does not make virgl
legal. The same remote run, `tb_g6lc_apu_vgpu_gnw`, errors=0.
Fixture synth, no latches: Enable=0 is 10 ports and no cells;
Enable=1 is 498 cells / 181 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_gnx` requires avail index 1 and consumed device
index 1 with the execbuffer. Transfer avail index 2 records
nothing. A second store keeps the first. This is later than
`g6lc_apu_vgpu_gnk`. This is not `g6lc_apu_vgpu_avail`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. `GnxEn` defaults to 0
and does not make virgl legal. The same remote run,
`tb_g6lc_apu_vgpu_gnw`, errors=0. Fixture synth, no latches:
Enable=0 is 11 ports and no cells; Enable=1 is 481 cells / 101
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vgpu_gef` fetches the scene header and the 960-byte
execbuffer after that guest-rung walk consumed device index 1.
The first command word is the surface `CREATE_OBJECT`. Transfer
dest and an unconsumed device index record nothing. The buffer
is not kept. This is later than `g6lc_apu_vgpu_gnx`. This is not
`g6lc_apu_vgpu_fet`. `g6lc_apu_vgpu_avail` still rejects `NEXT`.
The compiler TEX opcode still returns `-26`. The image is not
kept. This is not Mesa `glReadPixels`. `GefEn` defaults to 0 and
does not make virgl legal. Remote 2026-10-01, shared with the
keep and the check: `tb_g6lc_apu_vgpu_gef` 20 cases / 81 checks /
161 clocks, errors=0. Fixture synth, no latches: Enable=0 is 19
ports and no cells; Enable=1 is 779 cells / 81 flip-flops. The
CVA6 cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_gek` keeps that submit type and first command
word. A second store keeps the first. Transfer dest records
nothing. This is later than `g6lc_apu_vgpu_gef`. This is not
`g6lc_apu_vgpu_fek`. `GekEn` defaults to 0 and does not make
virgl legal. The same remote run, `tb_g6lc_apu_vgpu_gef`,
errors=0. Fixture synth, no latches: Enable=0 is 10 ports and
no cells; Enable=1 is 295 cells / 70 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_gex` requires the first command word to be the
surface `CREATE_OBJECT` after consumed device index 1. Transfer
dest records nothing. A second store keeps the first. This is
later than `g6lc_apu_vgpu_gek`. This is not `g6lc_apu_vgpu_fet`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. `GexEn` defaults to
0 and does not make virgl legal. The same remote run,
`tb_g6lc_apu_vgpu_gef`, errors=0. Fixture synth, no latches:
Enable=0 is 11 ports and no cells; Enable=1 is 274 cells / 38
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_spirv` is a bounded SPIR-V-subset interpreter with an
immutable 128-word program store. Two StorageBuffer inputs feed
`OpIAdd` or `OpIMul`; an IRQ rises when `OpReturn` completes. A
second program store after commit faults until reset. Enable=0
is quiet. The unit is not in `g6lc_apu_sys` and does not make
virgl legal. The TB is a diagnostic client on a bytes+IRQ test
transport, not a Mesa ICD. `SpirvEn` defaults to 0. Remote
2026-10-01: `tb_g6lc_apu_spirv` 8 cases / 15 checks / 348
clocks, errors=0. Fixture synth, no latches: Enable=0 is 16
ports and no cells; Enable=1 is 35938 cells / 5365 flip-flops.
The CVA6 cookie was not re-run. The TEX opcode still returns
`-26`. `g6lc_apu_vgpu_avail` still rejects `NEXT`.

`g6lc_apu_chain` walks a programmed virtq_desc table. The base,
queue size, and head index are inputs. NEXT is followed up to
`max_chain`. INDIRECT, a loop, an OOB next, an overlong chain,
and a misaligned base fault and issue no further read. Relocating
the table and starting at head 2 changes the first and last
payload windows. Enable=0 is quiet. The unit is not
`g6lc_apu_vgpu_avail` and not `g6lc_apu_vgpu_gnw`. It is not in
`g6lc_apu_sys` and does not make virgl legal. `ChainEn` defaults
to 0. Remote 2026-10-01: `tb_g6lc_apu_chain` 9 cases / 27 checks /
73 clocks, errors=0. Fixture synth, no latches: Enable=0 is 19
ports and no cells; Enable=1 is 1917 cells / 503 flip-flops. The
CVA6 cookie was not re-run. The TEX opcode still returns `-26`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`.

`g6lc_apu_cdma` joins NextChain to checked DmaRead. Descriptor
fetches are 16-byte mapping-window AXI reads. Relocating the table
and starting at head 2 still changes the payload windows. INDIRECT
issues one AR; an address outside the mapping or an invalid mapping
issues none. Enable=0 is quiet. The unit is not in `g6lc_apu_sys`
and does not make virgl legal. `CdmaEn` defaults to 0. Remote
2026-10-01: `tb_g6lc_apu_cdma` 7 cases / 20 checks / 153 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 14 ports and no
cells; Enable=1 is 8471 cells / 1150 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`.

With `ShmEn`, virtio-mmio `SHM_SEL=1` returns base
`64'h82000000` and length 1 MiB. Other selectors still read
all-ones. `g6lc_apu_hvis` records a HOST3D MAPABLE blob, a map
into that window, and `CTX_CREATE` with Venus `context_init` 4.
Virgl capset 1 faults. `RESOURCE_BLOB` and `CONTEXT_INIT` stay
outside `APU_IMPL_FEATURES`. Enable=0 is quiet. `HvisEn` and
`ShmEn` default to 0 and do not make virgl legal. Remote
2026-10-01: `tb_g6lc_apu_hvis` 7 cases / 18 checks / 51 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 9 ports and no
cells; Enable=1 is 1386 cells / 197 flip-flops. P1
`tb_g6lc_apu_virtio_mmio` 4240 checks still PASS. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`.

`g6lc_apu_vncs` walks a HOST_VISIBLE ring: CREATE_MODULE loads
SPIR-V into `g6lc_apu_spirv`; DISPATCH runs it and writes the
result back into the ring. The same committed module mutates
2+3=5 then 4+5=9. An unknown opcode faults. This ring is a
diagnostic transport, not Mesa `vn_protocol`. Enable=0 is quiet.
`VncsEn` defaults to 0 and does not make virgl legal. Remote
2026-10-01: `tb_g6lc_apu_vncs` 4 cases / 10 checks / 341 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 13 ports and no
cells; Enable=1 is 74601 cells / 9601 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`.

`g6lc_apu_vcap` answers GET_CAPSET_INFO and GET_CAPSET for Venus
id 4 with the 160-byte `virgl_renderer_capset_venus` layout. Virgl
id 1 faults. `NumCapsets` stays 0. Enable=0 is quiet. `VcapEn`
defaults to 0 and does not make virgl legal. Remote 2026-10-01:
`tb_g6lc_apu_vcap` 5 cases / 56 checks / 28 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 11 ports and no cells;
Enable=1 is 222 cells / 4 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`.

`g6lc_apu_vnring` walks Mesa `vn_ring_get_layout`: head at byte
0, tail at 64, status at 128, buffer at 192, 256-byte buffer.
head/tail are byte seqnos. A consume advances tail and writes
idle status. Wrap, empty, unaligned, and oversize are covered.
This is stock ring geometry, not `vn_protocol` vk* encode.
Enable=0 is quiet. `VnringEn` defaults to 0 and does not make
virgl legal. Remote 2026-10-01: `tb_g6lc_apu_vnring` 6 cases /
13 checks / 59 clocks, errors=0. Fixture synth, no latches:
Enable=0 is 12 ports and no cells; Enable=1 is 13443 cells /
4228 flip-flops. The CVA6 cookie was not re-run. The TEX opcode
still returns `-26`. `g6lc_apu_vgpu_avail` still rejects `NEXT`.

`g6lc_apu_tdma` is a 2:1 AXI join: APU DMA (port A) wins over
AI DMA (port B). Enable=0 is quiet. Under `+define+G6LC_APU` the
testharness instantiates it with Enable=1 onto `slave[2]`.
`ApuHarness.DmaReadEn=0` keeps the APU side idle. `NrSlaves`
stays 3. `TdmaEn` defaults to 0 and does not make virgl legal.
The unit is not a child of `g6lc_apu_sys`. Remote 2026-10-01:
`tb_g6lc_apu_tdma` 4 cases / 10 checks / 18 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 8 ports and no cells;
Enable=1 is 321 cells / 4 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`.

`g6lc_apu_vnenc` decodes Mesa `vn_protocol` `vkCreateShaderModule`
CS: command type 59, LP64 handles, pointer presence, sType 16,
pCode array_size, module id. CS is 192 words, max 128 pCode words.
GENERATE_REPLY writes type, `VK_SUCCESS`, and the handle at word
184. vkCreateInstance, a null info pointer, and empty pCode fault.
Enable=0 is quiet. `VnencEn` defaults to 0 and does not make virgl
legal. The unit is not a child of `g6lc_apu_sys`. Remote 2026-10-01:
`tb_g6lc_apu_vnenc` 6 cases / 13 checks / 302 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 12 ports and no cells;
Enable=1 is 36136 cells / 6437 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`.

`g6lc_apu_vnp` takes a Mesa `vn_ring_layout` buffer of 512 bytes at
offset 192, decodes `vkCreateShaderModule`, and loads pCode into
SpirvSubset. The same committed module mutates 2+3=5 then 4+5=9.
Empty ring is quiet. Enable=0 is quiet. `VnpEn` defaults to 0 and
does not make virgl legal. The unit is not a child of
`g6lc_apu_sys`. Remote 2026-10-01: `tb_g6lc_apu_vnp` 6 cases / 11
checks / 768 clocks, errors=0. Fixture synth, no latches: Enable=0
is 16 ports and no cells; Enable=1 is 100179 cells / 20112
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`. `g6lc_apu_vgpu_avail` still rejects `NEXT`.

`g6lc_apu_avn` reads `virtq_avail.idx` and `ring[device_idx]`, then
NextChain follows NEXT. Empty when the indices match. 16-bit wrap and
two-index batching. INDIRECT and an unaligned avail base fault.
Enable=0 is quiet. `AvnEn` defaults to 0 and does not make virgl
legal. `g6lc_apu_vgpu_avail` still faults NEXT and was not edited.
The unit is not a child of `g6lc_apu_sys`. Remote 2026-10-01:
`tb_g6lc_apu_avn` 7 cases / 13 checks / 97 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 19 ports and no cells;
Enable=1 is 3521 cells / 988 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_avu` publishes `virtq_used_elem` then `used.idx` after an
AvailNext consume. EMPTY writes nothing. 16-bit used-index wrap.
INDIRECT issues no used store. Enable=0 is quiet. `AvuEn` defaults
to 0 and does not make virgl legal. `g6lc_apu_vgpu_avail` still
faults NEXT and was not edited. The unit is not a child of
`g6lc_apu_sys`. Remote 2026-10-01: `tb_g6lc_apu_avu` 5 cases / 9
checks / 82 clocks, errors=0. Fixture synth, no latches: Enable=0
is 27 ports and no cells; Enable=1 is 4754 cells / 1438 flip-flops.
The CVA6 cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_uir` raises virtio used-buffer ISR bit 0 after `used.idx`
publication. Guest ack of bit 0 lowers the pin. EMPTY and INDIRECT
raise no IRQ. Enable=0 is quiet. `UirEn` defaults to 0 and does not
make virgl legal. `g6lc_apu_vgpu_avail` still faults NEXT and was
not edited. The unit is not a child of `g6lc_apu_sys`. Remote
2026-10-01: `tb_g6lc_apu_uir` 4 cases / 9 checks / 63 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 31 ports and no
cells; Enable=1 is 3947 cells / 1141 flip-flops. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_cms` snapshots the first payload window (≤32 bytes) after
an AvailNext walk. Guest mutation of that address does not change
the snapshot. A second snapshot faults until reset. EMPTY stores
nothing. Enable=0 is quiet. `CmsEn` defaults to 0 and does not make
virgl legal. `g6lc_apu_vgpu_avail` still faults NEXT and was not
edited. The unit is not a child of `g6lc_apu_sys`. Remote 2026-10-01:
`tb_g6lc_apu_cms` 4 cases / 10 checks / 45 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 21 ports and no cells;
Enable=1 is 4227 cells / 1201 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_prs` stores a programmed WRITE-window response (≤32 bytes)
after an AvailNext walk whose last descriptor is WRITE. The TB
programs `VGPU_RESP_OK_NODATA`; this is not DISPLAY.md identity.
EMPTY writes nothing. Length mismatch faults. Enable=0 is quiet.
`PrsEn` defaults to 0 and does not make virgl legal.
`g6lc_apu_vgpu_avail` still faults NEXT and was not edited. The unit
is not a child of `g6lc_apu_sys`. Remote 2026-10-01:
`tb_g6lc_apu_prs` 4 cases / 8 checks / 71 clocks, errors=0. Fixture
synth, no latches: Enable=0 is 31 ports and no cells; Enable=1 is
3833 cells / 1234 flip-flops. The CVA6 cookie was not re-run. The
TEX opcode still returns `-26`.

`g6lc_apu_qdn` does one AvailNext walk, then stores a programmed
WRITE response, `virtq_used_elem`, `used.idx`, and virtio used-buffer
ISR. EMPTY writes nothing. Enable=0 is quiet. `QdnEn` defaults to 0
and does not make virgl legal. `g6lc_apu_vgpu_avail` still faults
NEXT and was not edited. The unit is not a child of `g6lc_apu_sys`.
Remote 2026-10-01: `tb_g6lc_apu_qdn` 3 cases / 8 checks / 52 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 35 ports and no
cells; Enable=1 is 5140 cells / 1453 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_gcs` walks AvailNext, snapshots GET_CAPSET_INFO /
GET_CAPSET, grants Venus id 4 through VenusCapset, writes the capset
response into the WRITE window, then `virtq_used_elem`, `used.idx`,
and virtio used-buffer ISR. Virgl id 1 faults. EMPTY writes nothing.
`NumCapsets` stays 0; this is not advertised virtio GET_CAPSET.
Enable=0 is quiet. `GcsEn` defaults to 0 and does not make virgl
legal. `g6lc_apu_vgpu_avail` still faults NEXT and was not edited.
The unit is not a child of `g6lc_apu_sys`. Remote 2026-10-01:
`tb_g6lc_apu_gcs` 5 cases / 12 checks / 116 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 31 ports and no cells;
Enable=1 is 9379 cells / 1813 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vnd` decodes Mesa `vn_protocol` `vkCmdDispatch` (command
type 110, LP64 command-buffer handle, groupCountX/Y/Z).
GENERATE_REPLY writes the command type. vkCreateShaderModule,
vkCreateInstance, a null command buffer, and `vkCmdDispatchIndirect`
fault. Enable=0 is quiet. `VndEn` defaults to 0 and does not make
virgl legal. The unit is not a child of `g6lc_apu_sys`. Remote
2026-10-01: `tb_g6lc_apu_vnd` 7 cases / 12 checks / 145 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 12 ports and no
cells; Enable=1 is 1729 cells / 741 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_gnh` is an eight-slot generational context/resource/
module/cmdbuf table. Alloc publishes `{gen, slot}`. Lookup/pin/
unpin/retire require a live matching generation. Retire is refused
while pinned. Duplicate live `(kind, object_id)` and a full table
fault. Enable=0 is quiet. `GnhEn` defaults to 0 and does not make
virgl legal. The unit is not a child of `g6lc_apu_sys`. Remote
2026-10-01: `tb_g6lc_apu_gnh` 6 cases / 25 checks / 122 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 9 ports and no
cells; Enable=1 is 3737 cells / 565 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_hdp` instantiates GenHandle and VenusDispatch. A dispatch
request decodes `vkCmdDispatch` and looks up `commandBuffer[31:0]`
as a live CMDBUF handle. Stale generation, a MODULE handle, an
unknown handle, and vkCreateInstance fault. Enable=0 is quiet.
`HdpEn` defaults to 0 and does not make virgl legal. The unit is
not a child of `g6lc_apu_sys`. Remote 2026-10-01: `tb_g6lc_apu_hdp`
6 cases / 11 checks / 146 clocks, errors=0. Fixture synth, no
latches: Enable=0 is 13 ports and no cells; Enable=1 is 5979 cells
/ 1491 flip-flops. The CVA6 cookie was not re-run. The TEX opcode
still returns `-26`.

`g6lc_apu_hph` instantiates VenusEncode, GenHandle, and
VenusDispatch. `vkCreateShaderModule` allocates a MODULE handle from
`module_id[31:0]`. `vkCmdDispatch` looks up a live CMDBUF.
Duplicate live module ids, a MODULE used as a command buffer, and
vkCreateInstance fault. Enable=0 is quiet. `HphEn` defaults to 0
and does not make virgl legal. The unit is not a child of
`g6lc_apu_sys`. Remote 2026-10-01: `tb_g6lc_apu_hph` 6 cases / 11
checks / 207 clocks, errors=0. Fixture synth, no latches: Enable=0
is 13 ports and no cells; Enable=1 is 41062 cells / 7481
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_hrn` instantiates VenusEncode, GenHandle, VenusDispatch,
and SpirvSubset. Create commits SPIR-V under a MODULE handle.
Dispatch looks up a live CMDBUF and kicks `2+3=5` then `4+5=9`.
Dispatch before create, a MODULE used as a command buffer, and
vkCreateInstance fault. Enable=0 is quiet. `HrnEn` defaults to 0
and does not make virgl legal. The unit is not a child of
`g6lc_apu_sys`. Remote 2026-10-01: `tb_g6lc_apu_hrn` 6 cases / 11
checks / 720 clocks, errors=0. Fixture synth, no latches: Enable=0
is 17 ports and no cells; Enable=1 is 77619 cells / 13025
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_rdn` instantiates HandleRun. Dispatch writes the SPIR-V
result (4 bytes), `virtq_used_elem`, `used.idx`, and virtio
used-buffer ISR. Create writes nothing. Dispatch before create
writes nothing. Enable=0 is quiet. `RdnEn` defaults to 0 and does
not make virgl legal. The unit is not a child of `g6lc_apu_sys`.
Remote 2026-10-01: `tb_g6lc_apu_rdn` 4 cases / 10 checks / 403
clocks, errors=0. Fixture synth, no latches: Enable=0 is 27 ports
and no cells; Enable=1 is 77606 cells / 13138 flip-flops. The CVA6
cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_qrn` instantiates AvailNext and RunDone. It walks the
virtqueue, DMA-reads the first payload into the CS, then CREATE or
DISPATCH. DISPATCH writes the SPIR-V result, `used.idx`, and ISR.
CREATE writes nothing. EMPTY fetches nothing. Enable=0 is quiet.
`QrnEn` defaults to 0 and does not make virgl legal.
`g6lc_apu_vgpu_avail` still faults NEXT and was not edited. The unit
is not a child of `g6lc_apu_sys`. Remote 2026-10-01:
`tb_g6lc_apu_qrn` 3 cases / 9 checks / 315 clocks, errors=0. Fixture
synth, no latches: Enable=0 is 33 ports and no cells; Enable=1 is
84956 cells / 15231 flip-flops. The CVA6 cookie was not re-run. The
TEX opcode still returns `-26`.

`g6lc_apu_qcm` instantiates GrantCapset and QueueRun. `capset=1`
walks GET_CAPSET/INFO through Venus; `capset=0` walks CREATE or
DISPATCH through RunDone. Virgl id 1 faults. EMPTY fetches nothing.
Enable=0 is quiet. `QcmEn` defaults to 0 and does not make virgl
legal. `NumCapsets` stays 0. This is not advertised GET_CAPSET.
`g6lc_apu_vgpu_avail` still faults NEXT and was not edited. The unit
is not a child of `g6lc_apu_sys`. Remote 2026-10-01:
`tb_g6lc_apu_qcm` 6 cases / 16 checks / 436 clocks, errors=0. Fixture
synth, no latches: Enable=0 is 33 ports and no cells; Enable=1 is
95709 cells / 17523 flip-flops. The CVA6 cookie was not re-run. The
TEX opcode still returns `-26`.

`g6lc_apu_qty` instantiates AvailNext and QueueCmd. It peeks the
first command word: GET_CAPSET/INFO selects GrantCapset;
CREATE/DISPATCH selects QueueRun. `gnh_only` skips the peek. EMPTY
fetches nothing. Enable=0 is quiet. `QtyEn` defaults to 0 and does
not make virgl legal. `NumCapsets` stays 0. This is not advertised
GET_CAPSET. `g6lc_apu_vgpu_avail` still faults NEXT and was not
edited. The unit is not a child of `g6lc_apu_sys`. Remote 2026-10-01:
`tb_g6lc_apu_qty` 6 cases / 16 checks / 516 clocks, errors=0. Fixture
synth, no latches: Enable=0 is 33 ports and no cells; Enable=1 is
100577 cells / 19138 flip-flops. The CVA6 cookie was not re-run. The
TEX opcode still returns `-26`.

`g6lc_apu_vct` instantiates VenusCapset and QueueType. Private
`virtio_gpu_config.num_capsets` reads as 1 and GET_CAPSET_INFO index
0 is Venus id 4. QueueNotify of control queue 0 fires QueueType.
Cursor queue 1 faults. Enable=0 is quiet. `VctEn` defaults to 0 and
does not make virgl legal. `ApuCfg.NumCapsets` stays 0. This is not
virtio_mmio advertisement. `g6lc_apu_vgpu_avail` still faults NEXT
and was not edited. The unit is not a child of `g6lc_apu_sys`.
Remote 2026-10-01: `tb_g6lc_apu_vct` 9 cases / 22 checks / 566
clocks, errors=0. Fixture synth, no latches: Enable=0 is 33 ports
and no cells; Enable=1 is 101726 cells / 19670 flip-flops. The CVA6
cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_qpu` instantiates VenusCtrl. QueueNotify of control queue
0 fires VenusCtrl until AvailNext is EMPTY. Two pending
GET_CAPSET_INFO descriptors publish twice. CFG and INFO pass through
once. `gnh_only` fires once. Cursor queue 1 faults. Enable=0 is
quiet. `QpuEn` defaults to 0 and does not make virgl legal.
`ApuCfg.NumCapsets` stays 0. `g6lc_apu_vgpu_avail` still faults NEXT
and was not edited. The unit is not a child of `g6lc_apu_sys`.
Remote 2026-10-01: `tb_g6lc_apu_qpu` 10 cases / 24 checks / 735
clocks, errors=0. Fixture synth, no latches: Enable=0 is 33 ports
and no cells; Enable=1 is 103215 cells / 20298 flip-flops. The CVA6
cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_ntk` instantiates QueuePump. `arm` latches control-queue
bases. virtio-mmio `notify_pending[0]` drains that queue and pulses
`notify_clear[0]`. A doorbell before `arm` faults and still clears.
Cursor `notify_pending[1]` faults. Enable=0 is quiet. `NtkEn`
defaults to 0 and does not make virgl legal. `ApuCfg.NumCapsets`
stays 0. `g6lc_apu_virtio_mmio` was not edited. The unit is not a
child of `g6lc_apu_sys`. Remote 2026-10-01: `tb_g6lc_apu_ntk` 6
cases / 12 checks / 160 clocks, errors=0. Fixture synth, no latches:
Enable=0 is 35 ports and no cells; Enable=1 is 105435 cells / 21314
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vqt` instantiates NotifyTake. virtio `vq_state[0]`
(`desc`/`avail`/`used`/`num`/`ready`) arms the control queue on
`notify_pending[0]`. A doorbell with `ready=0` faults and still
clears. Cursor `notify_pending[1]` faults. Enable=0 is quiet.
`VqtEn` defaults to 0 and does not make virgl legal.
`ApuCfg.NumCapsets` stays 0. `g6lc_apu_virtio_mmio` was not edited.
The unit is not a child of `g6lc_apu_sys`. Remote 2026-10-01:
`tb_g6lc_apu_vqt` 6 cases / 11 checks / 163 clocks, errors=0. Fixture
synth, no latches: Enable=0 is 37 ports and no cells; Enable=1 is
108797 cells / 22150 flip-flops. The CVA6 cookie was not re-run. The
TEX opcode still returns `-26`.

`g6lc_apu_vax` instantiates VqTake and converts guest beats to 64-bit
AXI. 4-byte windows use SIZE=2; 8-byte and longer windows use SIZE=3
INCR. Enable=0 is quiet. `VaxEn` defaults to 0 and does not make
virgl legal. `ApuCfg.NumCapsets` stays 0. `g6lc_apu_virtio_mmio` was
not edited. The unit is not a child of `g6lc_apu_sys` and is not
wired onto testharness `slave[2]`. Remote 2026-10-01:
`tb_g6lc_apu_vax` 6 cases / 11 checks / 287 clocks, errors=0. Fixture
synth, no latches: Enable=0 is 21 ports and no cells; Enable=1 is
111519 cells / 22766 flip-flops. The CVA6 cookie was not re-run. The
TEX opcode still returns `-26`.

`g6lc_apu_vac` instantiates GenHandle. Mesa `vn_protocol`
`vkAllocateCommandBuffers` (type 88, sType 40) with count 1 and
PRIMARY level ALLOCs a CMDBUF handle. GENERATE_REPLY writes type,
VK_SUCCESS, and the published handle. Enable=0 is quiet. `VacEn`
defaults to 0 and does not make virgl legal. `ApuCfg.NumCapsets`
stays 0. The unit is not a child of `g6lc_apu_sys`. Remote
2026-10-01: `tb_g6lc_apu_vac` 12 cases / 18 checks / 1016 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 12 ports and no
cells; Enable=1 is 4931 cells / 1569 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_hal` instantiates GenHandle and VenusDispatch on one
table. `vkAllocateCommandBuffers` ALLOCs a CMDBUF handle;
`vkCmdDispatch` looks that handle up. Dispatch before allocate and
a MODULE handle fault. Enable=0 is quiet. `HalEn` defaults to 0 and
does not make virgl legal. `ApuCfg.NumCapsets` stays 0. The unit is
not a child of `g6lc_apu_sys`. Remote 2026-10-01: `tb_g6lc_apu_hal`
8 cases / 15 checks / 479 clocks, errors=0. Fixture synth, no
latches: Enable=0 is 13 ports and no cells; Enable=1 is 9178 cells
/ 2262 flip-flops. The CVA6 cookie was not re-run. The TEX opcode
still returns `-26`.

`g6lc_apu_aru` instantiates VenusEncode, GenHandle, VenusDispatch,
and SpirvSubset on one table. `vkAllocateCommandBuffers` ALLOCs a
CMDBUF handle; CREATE commits SPIR-V; DISPATCH kicks 2+3=5 then
4+5=9. Dispatch before create and a MODULE handle as cmdbuf fault.
Enable=0 is quiet. `AruEn` defaults to 0 and does not make virgl
legal. `ApuCfg.NumCapsets` stays 0. The unit is not a child of
`g6lc_apu_sys`. Remote 2026-10-01: `tb_g6lc_apu_aru` 7 cases / 13
checks / 914 clocks, errors=0. Fixture synth, no latches: Enable=0
is 17 ports and no cells; Enable=1 is 81337 cells / 13796
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_qal` instantiates AvailNext and AllocRun. Guest CS
ALLOC/CREATE/DISPATCH on one table. DISPATCH writes the SPIR-V
result, `used.idx`, and ISR. ALLOC and CREATE write nothing. EMPTY
fetches nothing. Enable=0 is quiet. `QalEn` defaults to 0 and does
not make virgl legal. `ApuCfg.NumCapsets` stays 0. The unit is not a
child of `g6lc_apu_sys`. Remote 2026-10-01: `tb_g6lc_apu_qal` 4
cases / 11 checks / 377 clocks, errors=0. Fixture synth, no
latches: Enable=0 is 33 ports and no cells; Enable=1 is 86349 cells
/ 15155 flip-flops. The CVA6 cookie was not re-run. The TEX opcode
still returns `-26`.

`g6lc_apu_qta` instantiates AvailNext, GrantCapset, and QueueAlloc.
GET_CAPSET/INFO select Venus; ALLOC/CREATE/DISPATCH select
QueueAlloc. Enable=0 is quiet. `QtaEn` defaults to 0 and does not
make virgl legal. `ApuCfg.NumCapsets` stays 0. The unit is not a
child of `g6lc_apu_sys`. Remote 2026-10-01: `tb_g6lc_apu_qta` 6
cases / 16 checks / 547 clocks, errors=0. Fixture synth, no
latches: Enable=0 is 33 ports and no cells; Enable=1 is 100760
cells / 18263 flip-flops. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vca` instantiates VenusCapset and QueueTypeAlloc. Private
`num_capsets` reads as 1; GET_CAPSET_INFO index 0 is Venus id 4.
QueueNotify of control queue 0 fires QueueTypeAlloc. Cursor queue 1
faults. Enable=0 is quiet. `VcaEn` defaults to 0 and does not make
virgl legal. `ApuCfg.NumCapsets` stays 0. The unit is not a child of
`g6lc_apu_sys`. Remote 2026-10-01: `tb_g6lc_apu_vca` 9 cases / 22
checks / 597 clocks, errors=0. Fixture synth, no latches: Enable=0
is 33 ports and no cells; Enable=1 is 101912 cells / 18796
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_qpa` instantiates VenusCtrlAlloc. QueueNotify of control
queue 0 fires VenusCtrlAlloc until AvailNext is EMPTY. Two pending
GET_CAPSET_INFO descriptors publish twice. Type 88 ALLOC, CREATE,
and DISPATCH ride the same drain. CFG and INFO pass through once.
`gnh_only` fires once. Cursor queue 1 faults. QueueTypeAlloc holds
`capset_q` across Idle except `gnh_only` so a pump EMPTY peek keeps
the GrantCapset ISR. Enable=0 is quiet. `QpaEn` defaults to 0 and
does not make virgl legal. `ApuCfg.NumCapsets` stays 0.
`g6lc_apu_vgpu_avail` still faults NEXT and was not edited. The
unit is not a child of `g6lc_apu_sys`. Remote 2026-10-01:
`tb_g6lc_apu_qpa` 10 cases / 24 checks / 770 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 33 ports and no cells;
Enable=1 is 103410 cells / 19425 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_nta` instantiates QueuePumpAlloc. `arm` latches
control-queue bases. virtio-mmio `notify_pending[0]` drains that
ALLOC pump and pulses `notify_clear[0]`. A doorbell before `arm`
faults and still clears. Cursor `notify_pending[1]` faults. Type 88
ALLOC rides the doorbell. Enable=0 is quiet. `NtaEn` defaults to 0
and does not make virgl legal. `ApuCfg.NumCapsets` stays 0.
`g6lc_apu_virtio_mmio` was not edited. The unit is not a child of
`g6lc_apu_sys`. Remote 2026-10-01: `tb_g6lc_apu_nta` 7 cases / 13
checks / 241 clocks, errors=0. Fixture synth, no latches: Enable=0
is 35 ports and no cells; Enable=1 is 105632 cells / 20442
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vqa` instantiates NotifyTakeAlloc. virtio `vq_state[0]`
(desc/avail/used/num/ready) arms on `notify_pending[0]`. Ports are
`vq0_i`/`vq1_i`. A doorbell with `ready=0` faults and still clears.
Cursor `notify_pending[1]` faults. Type 88 ALLOC rides the doorbell.
Enable=0 is quiet. `VqaEn` defaults to 0 and does not make virgl
legal. `ApuCfg.NumCapsets` stays 0. `g6lc_apu_virtio_mmio` was not
edited. The unit is not a child of `g6lc_apu_sys`. Remote 2026-10-01:
`tb_g6lc_apu_vqa` 7 cases / 12 checks / 243 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 37 ports and no cells;
Enable=1 is 108997 cells / 21279 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vaa` instantiates VqTakeAlloc and converts rd/wr beats to
64-bit AXI. 4-byte windows use SIZE=2; longer windows use SIZE=3
INCR. Type 88 ALLOC rides the doorbell. Enable=0 is quiet. `VaaEn`
defaults to 0 and does not make virgl legal. `ApuCfg.NumCapsets`
stays 0. The converter does not use `dma_read`. The unit is not a
child of `g6lc_apu_sys`. Remote 2026-10-01: `tb_g6lc_apu_vaa` 7
cases / 12 checks / 426 clocks, errors=0. Fixture synth, no
latches: Enable=0 is 21 ports and no cells; Enable=1 is 111719
cells / 21895 flip-flops. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vbg` decodes Mesa `vn_protocol` `vkBeginCommandBuffer`
(command type 90, sType 42, LP64 command-buffer handle, PRIMARY
null inheritance). GENERATE_REPLY writes type + VK_SUCCESS.
`vkAllocateCommandBuffers`, `vkCreateShaderModule`,
`vkCreateInstance`, `vkCmdDispatch`, `vkEndCommandBuffer`, a null
info pointer, a null command buffer, and a non-null inheritance
pointer fault. Enable=0 is quiet. `VbgEn` defaults to 0 and does
not make virgl legal. `ApuCfg.NumCapsets` stays 0. The unit is not
a child of `g6lc_apu_sys`. Remote 2026-10-01: `tb_g6lc_apu_vbg` 11
cases / 17 checks / 350 clocks, errors=0. Fixture synth, no
latches: Enable=0 is 12 ports and no cells; Enable=1 is 1947 cells
/ 708 flip-flops. The CVA6 cookie was not re-run. The TEX opcode
still returns `-26`.

`g6lc_apu_bal` ALLOCs a CMDBUF from Mesa `vn_protocol`
`vkAllocateCommandBuffers` and looks that published handle up on
`vkBeginCommandBuffer` on one GenHandle table. Begin before
allocate, MODULE-as-cmdbuf, duplicate live object ids, and
`vkCreateInstance` fault. The record field is `begin_cmd` (`begin`
is a Verilog keyword). Packed-struct rec writes are whole-struct
`'{ }`. Enable=0 is quiet. `BalEn` defaults to 0 and does not make
virgl legal. `ApuCfg.NumCapsets` stays 0. The unit is not a child
of `g6lc_apu_sys`. Remote 2026-10-01: `tb_g6lc_apu_bal` 8 cases /
17 checks / 554 clocks, errors=0. Fixture synth, no latches:
Enable=0 is 13 ports and no cells; Enable=1 is 9018 cells / 2134
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_bru` ALLOCs a QUEUE from Mesa `vn_protocol`
`vkGetDeviceQueue`, ALLOCs a CMDBUF, looks it up on
`vkBeginCommandBuffer`, CREATE a MODULE, DISPATCH SpirvSubset,
END LOOKUP of the begun handle, SUBMIT of the ended handle
against that QUEUE, and WAIT of the prior submit on one GenHandle
table. DISPATCH requires a begun CMDBUF and a loaded module. END
clears recording. SUBMIT and WAIT require the published QUEUE.
Begin before allocate, dispatch before begin or create, end
before begin, submit before queue or end, MODULE-as-cmdbuf,
`vkEndCommandBuffer` as begin, and `vkCreateInstance` fault.
Record fields are `begin_cmd`, `end_cmd`, `wait_idle`, and
`get_queue`. Packed-struct rec writes are whole-struct `'{ }`.
Enable=0 is quiet. `BruEn` defaults to 0 and does not make virgl
legal. `ApuCfg.NumCapsets` stays 0. The unit is not a child of
`g6lc_apu_sys`. Remote 2026-10-01: `tb_g6lc_apu_bru` 12 cases /
34 checks / 1702 clocks, errors=0. Fixture synth, no latches:
Enable=0 is 17 ports and no cells; Enable=1 is 91383 cells /
16724 flip-flops. The CVA6 cookie was not re-run. The TEX opcode
still returns `-26`.

`g6lc_apu_qbn` walks AvailNext into BeginRun so guest CS type 88
ALLOC, 90 BEGIN, 59 CREATE, 110 DISPATCH, 91 END, 18 SUBMIT, 19
WAIT, and 17 QUEUE share one table. A WRITE last descriptor
publishes the SPIR-V result, handle, or VK_SUCCESS, then used.idx
and ISR. DISPATCH, SUBMIT, and WAIT without WRITE fault. EMPTY
fetches nothing. Enable=0 is quiet. `QbnEn` defaults to 0 and
does not make virgl legal. `ApuCfg.NumCapsets` stays 0. The unit
is not a child of `g6lc_apu_sys`. Remote 2026-10-01:
`tb_g6lc_apu_qbn` 7 cases / 20 checks / 783 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 33 ports and no cells;
Enable=1 is 92131 cells / 17187 flip-flops. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_qtb` peeks the first AvailNext command word then fires
GrantCapset or QueueBegin. GET_CAPSET_INFO and GET_CAPSET select
Venus; type 88 ALLOC, 90 BEGIN, 59 CREATE, 110 DISPATCH, 91 END,
18 SUBMIT, 19 WAIT, and 17 QUEUE select QueueBegin. Idle holds
`capset_q` except `gnh_only` so a later EMPTY peek keeps the
GrantCapset ISR. Virgl id 1 faults. EMPTY fetches nothing.
Enable=0 is quiet. `QtbEn` defaults to 0 and does not make virgl
legal. `ApuCfg.NumCapsets` stays 0. The unit is not a child of
`g6lc_apu_sys`. Remote 2026-10-01: `tb_g6lc_apu_qtb` 6 cases /
21 checks / 865 clocks, errors=0. Fixture synth, no latches:
Enable=0 is 33 ports and no cells; Enable=1 is 106507 cells /
20290 flip-flops. The CVA6 cookie was not re-run. The TEX opcode
still returns `-26`.

`g6lc_apu_vcb` is a private control face: `num_capsets` reads as 1
and GET_CAPSET_INFO index 0 is Venus id 4. QueueNotify of control
queue 0 fires QueueTypeBegin so type 90 BEGIN rides GET_CAPSET.
Cursor queue 1 faults. `ApuCfg.NumCapsets` stays 0; this is not
virtio_mmio advertisement. Enable=0 is quiet. `VcbEn` defaults to
0 and does not make virgl legal. The unit is not a child of
`g6lc_apu_sys`. Remote 2026-10-01: `tb_g6lc_apu_vcb` 9 cases /
23 checks / 654 clocks, errors=0. Fixture synth, no latches:
Enable=0 is 33 ports and no cells; Enable=1 is 103161 cells /
19254 flip-flops. The CVA6 cookie was not re-run. The TEX opcode
still returns `-26`.

`g6lc_apu_qpb` drains QueueNotify of control queue 0 through
VenusCtrlBegin until AvailNext is EMPTY so type 90 BEGIN rides
GET_CAPSET. CFG and INFO fire once. Cursor queue 1 faults. EMPTY
copies the prior record including IRQ. Enable=0 is quiet. `QpbEn`
defaults to 0 and does not make virgl legal. `ApuCfg.NumCapsets`
stays 0. The unit is not a child of `g6lc_apu_sys`. Remote
2026-10-01: `tb_g6lc_apu_qpb` 10 cases / 25 checks / 837 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 33 ports and no
cells; Enable=1 is 104658 cells / 19884 flip-flops. The CVA6
cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_ntb` consumes virtio `notify_pending[0]` into
QueuePumpBegin. `arm` latches control-queue bases. Type 88 ALLOC
and type 90 BEGIN ride the doorbell. Cursor `notify_pending[1]`
faults. A doorbell before `arm` faults and still clears. Enable=0
is quiet. `NtbEn` defaults to 0 and does not make virgl legal.
`ApuCfg.NumCapsets` stays 0. The unit is not a child of
`g6lc_apu_sys`. Remote 2026-10-01: `tb_g6lc_apu_ntb` 7 cases /
14 checks / 317 clocks, errors=0. Fixture synth, no latches:
Enable=0 is 35 ports and no cells; Enable=1 is 106882 cells /
20902 flip-flops. The CVA6 cookie was not re-run. The TEX opcode
still returns `-26`.

`g6lc_apu_vqb` arms NotifyTakeBegin from virtio `vq_state[0]` on
`notify_pending[0]`. Ports are `vq0_i`/`vq1_i`. Type 88 ALLOC and
type 90 BEGIN ride the doorbell. A doorbell with `ready=0` faults
and still clears. Cursor `notify_pending[1]` faults. Enable=0 is
quiet. `VqbEn` defaults to 0 and does not make virgl legal.
`ApuCfg.NumCapsets` stays 0. The unit is not a child of
`g6lc_apu_sys`. Remote 2026-10-01: `tb_g6lc_apu_vqb` 7 cases /
13 checks / 318 clocks, errors=0. Fixture synth, no latches:
Enable=0 is 37 ports and no cells; Enable=1 is 110250 cells /
21740 flip-flops. The CVA6 cookie was not re-run. The TEX opcode
still returns `-26`.

`g6lc_apu_vab` runs VqTakeBegin guest beats on 64-bit AXI.
4-byte windows use SIZE=2; longer windows use SIZE=3 INCR. Type
88 ALLOC and type 90 BEGIN ride the doorbell. Enable=0 is quiet.
`VabEn` defaults to 0 and does not make virgl legal.
`ApuCfg.NumCapsets` stays 0. The converter does not use
`dma_read`. The unit is not a child of `g6lc_apu_sys`. Remote
2026-10-01: `tb_g6lc_apu_vab` 7 cases / 13 checks / 553 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 21 ports and no
cells; Enable=1 is 112972 cells / 22356 flip-flops. The CVA6
cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_ven` decodes Mesa `vn_protocol` `vkEndCommandBuffer`
(command type 91, LP64 command-buffer handle). GENERATE_REPLY
writes type + `VK_SUCCESS` at word 4. Begin, allocate,
create-module, instance, dispatch, a null handle, and a high-half
handle fault. Enable=0 is quiet. `VenEn` defaults to 0 and does
not make virgl legal. `ApuCfg.NumCapsets` stays 0. The unit is
not a child of `g6lc_apu_sys`. Remote 2026-10-01:
`tb_g6lc_apu_ven` 10 cases / 16 checks / 165 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 12 ports and no cells;
Enable=1 is 1590 cells / 644 flip-flops. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgq` decodes Mesa `vn_protocol` `vkGetDeviceQueue`
(command type 17, LP64 device, family 0, index 0). GENERATE_REPLY
writes type. Submit, wait-idle, instance, a null device, a
high-half device, a nonzero family, and a nonzero index fault.
Enable=0 is quiet. `VgqEn` defaults to 0 and does not make virgl
legal. `ApuCfg.NumCapsets` stays 0. The unit is not a child of
`g6lc_apu_sys`. Remote 2026-10-01: `tb_g6lc_apu_vgq` 7 cases /
13 checks / 134 clocks, errors=0. Fixture synth, no latches:
Enable=0 is 12 ports and no cells; Enable=1 is 1781 cells / 708
flip-flops. BeginRun LOOKUPs the published DEVICE handle then
ALLOCs `APU_GNH_QUEUE`. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vcd` decodes Mesa `vn_protocol` `vkCreateDevice`
(command type 11, LP64 physicalDevice, sType 3 DEVICE_CREATE_INFO,
one queue family 0 count 1 priority 1.0, no layers/extensions).
GENERATE_REPLY writes type + `VK_SUCCESS`. GetDeviceQueue,
instance, a null physicalDevice, a nonzero family, and a wrong
sType fault. Enable=0 is quiet. `VcdEn` defaults to 0 and does
not make virgl legal. `ApuCfg.NumCapsets` stays 0. The unit is
not a child of `g6lc_apu_sys`. Remote 2026-10-01:
`tb_g6lc_apu_vcd` 7 cases / 13 checks / 926 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 12 ports and no cells;
Enable=1 is 4215 cells / 1412 flip-flops. BeginRun ALLOCs
`APU_GNH_DEVICE` from `physicalDevice[31:0]` after a live
INSTANCE. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

`g6lc_apu_vci` decodes Mesa `vn_protocol` `vkCreateInstance`
(command type 0, pCreateInfo, sType 1 INSTANCE_CREATE_INFO, no
application info, no layers/extensions, null allocator).
GENERATE_REPLY writes type + `VK_SUCCESS`. CreateDevice,
GetDeviceQueue, a null info, and a wrong sType fault. Enable=0 is
quiet. `VciEn` defaults to 0 and does not make virgl legal.
`ApuCfg.NumCapsets` stays 0. The unit is not a child of
`g6lc_apu_sys`. Remote 2026-10-02: `tb_g6lc_apu_vci` 7 cases /
13 checks / 566 clocks, errors=0. Fixture synth, no latches:
Enable=0 is 12 ports and no cells; Enable=1 is 2646 cells / 900
flip-flops. BeginRun ALLOCs `APU_GNH_INSTANCE` from `info[31:0]`.
The CVA6 cookie was not re-run. The TEX opcode still returns
`-26`.

`g6lc_apu_vep` decodes Mesa `vn_protocol`
`vkEnumeratePhysicalDevices` (command type 2, LP64 instance,
pCount, count 1, pDevices, array_size 1). GENERATE_REPLY writes
type + `VK_SUCCESS`. CreateInstance, CreateDevice, a null
instance, and a zero count fault. Enable=0 is quiet. `VepEn`
defaults to 0 and does not make virgl legal. `ApuCfg.NumCapsets`
stays 0. The unit is not a child of `g6lc_apu_sys`. Remote
2026-10-02: `tb_g6lc_apu_vep` 7 cases / 13 checks / 388 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 12 ports and no
cells; Enable=1 is 1814 cells / 644 flip-flops. BeginRun LOOKUPs
the published INSTANCE then ALLOCs `APU_GNH_PHYS`. CreateDevice
LOOKUPs that PHYS then ALLOCs DEVICE. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vqf` decodes Mesa `vn_protocol`
`vkGetPhysicalDeviceQueueFamilyProperties` (command type 7, LP64
physicalDevice, pCount, count 1, pProperties, array_size 1). Void
command. GENERATE_REPLY writes type. CreateInstance, Enumerate,
a null physicalDevice, and a zero count fault. Enable=0 is quiet.
`VqfEn` defaults to 0 and does not make virgl legal.
`ApuCfg.NumCapsets` stays 0. The unit is not a child of
`g6lc_apu_sys`. Remote 2026-10-02: `tb_g6lc_apu_vqf` 7 cases /
13 checks / 388 clocks, errors=0. Fixture synth, no latches:
Enable=0 is 12 ports and no cells; Enable=1 is 1816 cells / 644
flip-flops. BeginRun LOOKUPs the published PHYS (no new GenHandle
kind). CreateDevice requires that query. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vpf` decodes Mesa `vn_protocol`
`vkGetPhysicalDeviceFeatures` (command type 3, LP64
physicalDevice, pFeatures pointer). Void command. GENERATE_REPLY
writes type. CreateInstance, QueueFamily, a null physicalDevice,
a high-half handle, and a null pFeatures pointer fault. Enable=0
is quiet. `VpfEn` defaults to 0 and does not make virgl legal.
`ApuCfg.NumCapsets` stays 0. The unit is not a child of
`g6lc_apu_sys`. Remote 2026-10-02: `tb_g6lc_apu_vpf` 7 cases /
13 checks / 326 clocks, errors=0. Fixture synth, no latches:
Enable=0 is 12 ports and no cells; Enable=1 is 1651 cells / 644
flip-flops. BeginRun LOOKUPs the published PHYS (no new GenHandle
kind). Compact reply publishes `fragmentStoresAndAtomics`.
CreateDevice requires that query. The CVA6 cookie was not re-run.
The TEX opcode still returns `-26`.

`g6lc_apu_vpp` decodes Mesa `vn_protocol`
`vkGetPhysicalDeviceProperties` (command type 6, LP64
physicalDevice, pProperties pointer). Void command. GENERATE_REPLY
writes type. CreateInstance, Features, a null physicalDevice, a
high-half handle, and a null pProperties pointer fault. Enable=0
is quiet. `VppEn` defaults to 0 and does not make virgl legal.
`ApuCfg.NumCapsets` stays 0. The unit is not a child of
`g6lc_apu_sys`. Remote 2026-10-02: `tb_g6lc_apu_vpp` 7 cases /
13 checks / 326 clocks, errors=0. Fixture synth, no latches:
Enable=0 is 12 ports and no cells; Enable=1 is 1651 cells / 644
flip-flops. BeginRun LOOKUPs the published PHYS (no new GenHandle
kind). Compact reply publishes Vulkan 1.1 `apiVersion`
`32'h00401000` and `maxBoundDescriptorSets=4`. CreateDevice
requires that query. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vmp` decodes Mesa `vn_protocol`
`vkGetPhysicalDeviceMemoryProperties` (command type 8, LP64
physicalDevice, pMemoryProperties pointer). Void command.
GENERATE_REPLY writes type. CreateInstance, Properties, a null
physicalDevice, a high-half handle, and a null pMemoryProperties
pointer fault. Enable=0 is quiet. `VmpEn` defaults to 0 and does
not make virgl legal. `ApuCfg.NumCapsets` stays 0. The unit is not
a child of `g6lc_apu_sys`. Remote 2026-10-02: `tb_g6lc_apu_vmp`
7 cases / 13 checks / 326 clocks, errors=0. Fixture synth, no
latches: Enable=0 is 12 ports and no cells; Enable=1 is 1650
cells / 644 flip-flops. BeginRun LOOKUPs the published PHYS (no
new GenHandle kind). Compact reply publishes type count 2,
`DEVICE_LOCAL`, `HOST_VISIBLE|HOST_COHERENT`, and heap count 1.
CreateDevice requires that query. The CVA6 cookie was not re-run.
The TEX opcode still returns `-26`.

`g6lc_apu_vam` decodes Mesa `vn_protocol` `vkAllocateMemory`
(command type 21, LP64 device, pAllocateInfo, sType 5
MEMORY_ALLOCATE_INFO, nonzero size, memoryTypeIndex 0 or 1, null
allocator, pMemory pointer). GENERATE_REPLY writes type +
`VK_SUCCESS`. CreateDevice, MemoryProperties, a null device, a
zero size, and a type index of 2 or more fault. Enable=0 is quiet.
`VamEn` defaults to 0 and does not make virgl legal.
`ApuCfg.NumCapsets` stays 0. The unit is not a child of
`g6lc_apu_sys`. Remote 2026-10-02: `tb_g6lc_apu_vam` 8 cases /
14 checks / 631 clocks, errors=0. Fixture synth, no latches:
Enable=0 is 12 ports and no cells; Enable=1 is 2791 cells / 964
flip-flops. BeginRun LOOKUPs DEVICE then ALLOCs `APU_GNH_MEMORY`
from `pMemory[31:0]`. Requires the memory-properties query. The
CVA6 cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vxb` decodes Mesa `vn_protocol` `vkCreateBuffer`
(command type 50, LP64 device, pCreateInfo, sType 12
BUFFER_CREATE_INFO, nonzero size, usage STORAGE_BUFFER, exclusive
sharing, null allocator, pBuffer pointer). GENERATE_REPLY writes
type + `VK_SUCCESS`. AllocateMemory, a null device, a zero size,
and a non-storage usage fault. Enable=0 is quiet. `VxbEn` defaults
to 0 and does not make virgl legal. `ApuCfg.NumCapsets` stays 0.
The unit is not a child of `g6lc_apu_sys`. Remote 2026-10-02:
`tb_g6lc_apu_vxb` 8 cases / 14 checks / 815 clocks, errors=0.
Fixture synth, no latches: Enable=0 is 12 ports and no cells;
Enable=1 is 3339 cells / 1220 flip-flops. BeginRun LOOKUPs DEVICE
then ALLOCs `APU_GNH_BUFFER` from `pBuffer[31:0]`. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vbb` decodes Mesa `vn_protocol` `vkBindBufferMemory`
(command type 28, LP64 device, LP64 buffer, LP64 memory, offset 0).
GENERATE_REPLY writes type + `VK_SUCCESS`. CreateBuffer, a null
device, buffer, or memory, and a nonzero offset fault. Enable=0 is
quiet. `VbbEn` defaults to 0 and does not make virgl legal.
`ApuCfg.NumCapsets` stays 0. The unit is not a child of
`g6lc_apu_sys`. Remote 2026-10-02: `tb_g6lc_apu_vbb` 8 cases /
14 checks / 435 clocks, errors=0. Fixture synth, no latches:
Enable=0 is 12 ports and no cells; Enable=1 is 2039 cells / 772
flip-flops. BeginRun LOOKUPs BUFFER then LOOKUPs MEMORY. No new
GenHandle slot. The CVA6 cookie was not re-run. The TEX opcode
still returns `-26`.

`g6lc_apu_vmm` decodes Mesa `vn_protocol` `vkMapMemory`
(command type 23, LP64 device, LP64 memory, offset 0, nonzero size,
map flags 0, ppData pointer). GENERATE_REPLY writes type +
`VK_SUCCESS`. BindBufferMemory, a null device or memory, a zero
size, and a nonzero offset fault. Enable=0 is quiet. `VmmEn`
defaults to 0 and does not make virgl legal. `ApuCfg.NumCapsets`
stays 0. The unit is not a child of `g6lc_apu_sys`. Remote
2026-10-02: `tb_g6lc_apu_vmm` 9 cases / 15 checks / 548 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 12 ports and no
cells; Enable=1 is 2137 cells / 772 flip-flops. BeginRun LOOKUPs
MEMORY and publishes `APU_SHM_BASE`. No new GenHandle slot. The
CVA6 cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vum` decodes Mesa `vn_protocol` `vkUnmapMemory`
(command type 24, LP64 device, LP64 memory). Void command:
GENERATE_REPLY writes type. MapMemory, a null device, and a null
memory fault. Enable=0 is quiet. `VumEn` defaults to 0 and does
not make virgl legal. `ApuCfg.NumCapsets` stays 0. The unit is not
a child of `g6lc_apu_sys`. Remote 2026-10-02: `tb_g6lc_apu_vum`
6 cases / 12 checks / 268 clocks, errors=0. Fixture synth, no
latches: Enable=0 is 12 ports and no cells; Enable=1 is 1715
cells / 708 flip-flops. BeginRun requires a prior map, LOOKUPs
MEMORY, then clears map_ok. The CVA6 cookie was not re-run. The
TEX opcode still returns `-26`.

`g6lc_apu_vbm` decodes Mesa `vn_protocol`
`vkGetBufferMemoryRequirements` (command type 30, LP64 device, LP64
buffer, pMemoryRequirements pointer). Void command: GENERATE_REPLY
writes type. UnmapMemory, a null device or buffer, and a null out
pointer fault. Enable=0 is quiet. `VbmEn` defaults to 0 and does
not make virgl legal. `ApuCfg.NumCapsets` stays 0. The unit is not
a child of `g6lc_apu_sys`. Remote 2026-10-02: `tb_g6lc_apu_vbm`
7 cases / 13 checks / 349 clocks, errors=0. Fixture synth, no
latches: Enable=0 is 12 ports and no cells; Enable=1 is 1781
cells / 708 flip-flops. BeginRun LOOKUPs BUFFER and publishes size
4096, alignment 256, memoryTypeBits 3. The CVA6 cookie was not
re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vfm` decodes Mesa `vn_protocol`
`vkFlushMappedMemoryRanges` (command type 25, LP64 device, one
VkMappedMemoryRange, sType 6, offset 0, nonzero size).
GENERATE_REPLY writes type + `VK_SUCCESS`. UnmapMemory, a null
device or memory, a zero count, and a nonzero offset fault.
Enable=0 is quiet. `VfmEn` defaults to 0 and does not make virgl
legal. `ApuCfg.NumCapsets` stays 0. The unit is not a child of
`g6lc_apu_sys`. Remote 2026-10-02: `tb_g6lc_apu_vfm` 8 cases / 14
checks / 633 clocks, errors=0. Fixture synth, no latches: Enable=0
is 12 ports and no cells; Enable=1 is 2674 cells / 964 flip-flops.
BeginRun requires a prior map and LOOKUPs MEMORY. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vim` decodes Mesa `vn_protocol`
`vkInvalidateMappedMemoryRanges` (command type 26, LP64 device, one
VkMappedMemoryRange, sType 6, offset 0, nonzero size).
GENERATE_REPLY writes type + `VK_SUCCESS`. FlushMappedMemoryRanges,
a null device or memory, a zero count, and a nonzero offset fault.
Enable=0 is quiet. `VimEn` defaults to 0 and does not make virgl
legal. `ApuCfg.NumCapsets` stays 0. The unit is not a child of
`g6lc_apu_sys`. Remote 2026-10-02: `tb_g6lc_apu_vim` 8 cases / 14
checks / 633 clocks, errors=0. Fixture synth, no latches: Enable=0
is 12 ports and no cells; Enable=1 is 2674 cells / 964 flip-flops.
BeginRun requires a prior map and LOOKUPs MEMORY. The CVA6 cookie
was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vmc` decodes Mesa `vn_protocol`
`vkGetDeviceMemoryCommitment` (command type 27, LP64 device, LP64
memory, pCommittedMemoryInBytes pointer). Void command:
GENERATE_REPLY writes type. FlushMappedMemoryRanges, a null device
or memory, and a null out pointer fault. Enable=0 is quiet.
`VmcEn` defaults to 0 and does not make virgl legal.
`ApuCfg.NumCapsets` stays 0. The unit is not a child of
`g6lc_apu_sys`. Remote 2026-10-02: `tb_g6lc_apu_vmc` 7 cases / 13
checks / 349 clocks, errors=0. Fixture synth, no latches: Enable=0
is 12 ports and no cells; Enable=1 is 1781 cells / 708 flip-flops.
BeginRun LOOKUPs MEMORY and publishes committed size 4096. The
CVA6 cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_gnh` holds 16 generational slots. The published handle is
`{gen[31:16], 12'd0, slot[3:0]}`. Remote 2026-10-02: `tb_g6lc_apu_gnh`
6 cases / 33 checks / 162 clocks, errors=0. Enable=1 is 6131 cells /
1071 flip-flops.

`g6lc_apu_vdl` decodes Mesa `vn_protocol`
`vkCreateDescriptorSetLayout` (command type 72, sType 32, one
STORAGE_BUFFER compute binding). GENERATE_REPLY writes type +
`VK_SUCCESS`. Enable=0 is quiet. `VdlEn` defaults to 0 and does not
make virgl legal. `ApuCfg.NumCapsets` stays 0. Remote 2026-10-02:
`tb_g6lc_apu_vdl` 7 cases / 13 checks / 564 clocks, errors=0.
Enable=1 is 2745 cells / 964 flip-flops. BeginRun LOOKUPs DEVICE
then ALLOCs DSLAYOUT.

`g6lc_apu_vpl` decodes `vkCreatePipelineLayout` (command type 68,
sType 30, one set layout, no push constants). `VplEn` defaults to 0.
Remote 2026-10-02: `tb_g6lc_apu_vpl` 7 cases / 13 checks / 552
clocks, errors=0. Enable=1 is 2837 cells / 1028 flip-flops.
BeginRun requires dsl_ok, LOOKUPs DEVICE, then ALLOCs PLAYOUT.

`g6lc_apu_vcp` decodes `vkCreateComputePipelines` (command type 66,
sType 29, compute stage, module, layout). Packed field is `shader`.
`VcpEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vcp` 7 cases /
13 checks / 698 clocks, errors=0. Enable=1 is 3595 cells / 1348
flip-flops. BeginRun requires pl_ok and a loaded MODULE, LOOKUPs
DEVICE, then ALLOCs PIPELINE. The CVA6 cookie was not re-run. The
TEX opcode still returns `-26`.

`g6lc_apu_vda` decodes Mesa `vn_protocol`
`vkAllocateDescriptorSets` (command type 77, sType 34, one layout,
dummy pool). GENERATE_REPLY writes type + `VK_SUCCESS`. Enable=0
is quiet. `VdaEn` defaults to 0 and does not make virgl legal.
`ApuCfg.NumCapsets` stays 0. Remote 2026-10-02: `tb_g6lc_apu_vda`
7 cases / 13 checks / 542 clocks, errors=0. Enable=1 is 2803 cells
/ 1028 flip-flops. BeginRun requires dsl_ok, LOOKUPs DEVICE, then
ALLOCs DESCSET.

`g6lc_apu_vud` decodes `vkUpdateDescriptorSets` (command type 79,
sType 35, STORAGE_BUFFER write, offset 0). `VudEn` defaults to 0.
Remote 2026-10-02: `tb_g6lc_apu_vud` 7 cases / 11 checks / 682
clocks, errors=0. Enable=1 is 3437 cells / 1284 flip-flops.
BeginRun requires dset_ok, LOOKUPs DESCSET, then LOOKUPs BUFFER.

`g6lc_apu_vbp` decodes `vkCmdBindPipeline` (command type 93,
compute bind point). `VbpEn` defaults to 0. Remote 2026-10-02:
`tb_g6lc_apu_vbp` 7 cases / 11 checks / 336 clocks, errors=0.
Enable=1 is 1817 cells / 708 flip-flops. BeginRun requires a begun
CMDBUF, LOOKUPs PIPELINE, then sets pipe_bound.

`g6lc_apu_vbd` decodes `vkCmdBindDescriptorSets` (command type
103). `VbdEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vbd`
7 cases / 11 checks / 492 clocks, errors=0. Enable=1 is 2676 cells
/ 1028 flip-flops. BeginRun requires a begun CMDBUF and dset_ok,
LOOKUPs DESCSET, then sets desc_bound. DISPATCH requires both
binds.

`g6lc_apu_vpo` decodes Mesa `vn_protocol`
`vkCreateDescriptorPool` (command type 74, sType 33, one
STORAGE_BUFFER size). `VpoEn` defaults to 0. Remote 2026-10-02:
`tb_g6lc_apu_vpo` 7 cases / 12 checks / 588 clocks, errors=0.
Enable=1 is 2811 cells / 964 flip-flops. BeginRun LOOKUPs DEVICE
then ALLOCs POOL. AllocateDescriptorSets LOOKUPs that POOL.

`g6lc_apu_vxi` decodes `vkCreateImage` (command type 54, sType 14,
64x64 2D STORAGE linear R8G8B8A8). `VxiEn` defaults to 0. Remote
2026-10-02: `tb_g6lc_apu_vxi` 7 cases / 12 checks / 792 clocks,
errors=0. Enable=1 is 3616 cells / 1220 flip-flops. BeginRun
LOOKUPs DEVICE then ALLOCs IMAGE.

`g6lc_apu_vmi` decodes `vkGetImageMemoryRequirements` (command
type 31). `VmiEn` defaults to 0. Remote 2026-10-02:
`tb_g6lc_apu_vmi` 7 cases / 12 checks / 350 clocks, errors=0.
Enable=1 is 1847 cells / 708 flip-flops. BeginRun LOOKUPs IMAGE
and publishes size 16384.

`g6lc_apu_vbi` decodes `vkBindImageMemory` (command type 29,
offset 0). `VbiEn` defaults to 0. Remote 2026-10-02:
`tb_g6lc_apu_vbi` 7 cases / 12 checks / 374 clocks, errors=0.
Enable=1 is 2040 cells / 772 flip-flops. BeginRun LOOKUPs IMAGE
then LOOKUPs MEMORY. The CVA6 cookie was not re-run. The TEX
opcode still returns `-26`.

`g6lc_apu_vxv` decodes `vkCreateImageView` (command type 57, sType 15,
2D COLOR R8G8B8A8 identity swizzle). `VxvEn` defaults to 0. Remote
2026-10-02: `tb_g6lc_apu_vxv` 7 cases / 12 checks / 766 clocks,
errors=0. Enable=1 is 3674 cells / 1284 flip-flops. BeginRun LOOKUPs
IMAGE then ALLOCs VIEW.

`g6lc_apu_vsm` decodes `vkCreateSampler` (command type 70, sType 31,
linear mag/min/mip, repeat U/V/W). `VsmEn` defaults to 0. Remote
2026-10-02: `tb_g6lc_apu_vsm` 7 cases / 12 checks / 588 clocks,
errors=0. Enable=1 is 2813 cells / 964 flip-flops. BeginRun LOOKUPs
DEVICE then ALLOCs SAMPLER.

`g6lc_apu_vrp` decodes `vkCreateRenderPass` (command type 82, sType 38,
one color attachment). `VrpEn` defaults to 0. Remote 2026-10-02:
`tb_g6lc_apu_vrp` 7 cases / 12 checks / 588 clocks, errors=0.
Enable=1 is 2814 cells / 964 flip-flops. BeginRun LOOKUPs DEVICE then
ALLOCs RPASS.

`g6lc_apu_vgp` decodes `vkCreateGraphicsPipelines` (command type 65,
sType 28, one VERTEX stage). `VgpEn` defaults to 0. Remote 2026-10-02:
`tb_g6lc_apu_vgp` 7 cases / 12 checks / 730 clocks, errors=0.
Enable=1 is 3820 cells / 1412 flip-flops. BeginRun requires rp_ok,
pl_ok, and a loaded MODULE, LOOKUPs DEVICE, then ALLOCs PIPELINE.
Four creates share GENERATE_REPLY at CS mux slot 31
(`APU_BRU_TAIL_REPLY=248`). GenHandle is 32 slots.

`g6lc_apu_vfb` decodes `vkCreateFramebuffer` (command type 80, sType 37,
one 64x64 color view). `VfbEn` defaults to 0. Remote 2026-10-02:
`tb_g6lc_apu_vfb` 7 cases / 12 checks / 610 clocks, errors=0.
Enable=1 is 3131 cells / 1092 flip-flops. BeginRun requires rp_ok,
LOOKUPs DEVICE, then ALLOCs FBUF.

`g6lc_apu_vrb` decodes `vkCmdBeginRenderPass` (command type 133,
sType 43, 64x64 INLINE). `VrbEn` defaults to 0. Remote 2026-10-02:
`tb_g6lc_apu_vrb` 7 cases / 12 checks / 574 clocks, errors=0.
Enable=1 is 2907 cells / 1028 flip-flops. BeginRun requires a begun
CMDBUF, fbuf_ok, and rp_ok, then LOOKUPs that CMDBUF.

`g6lc_apu_vdw` decodes `vkCmdDraw` (command type 106, three vertices,
one instance). `VdwEn` defaults to 0. Remote 2026-10-02:
`tb_g6lc_apu_vdw` 7 cases / 12 checks / 350 clocks, errors=0.
Enable=1 is 1788 cells / 676 flip-flops. BeginRun requires begun,
in_rp, and pipe_bound, then LOOKUPs the CMDBUF.

`g6lc_apu_vre` decodes `vkCmdEndRenderPass` (command type 135).
`VreEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vre` 7 cases /
12 checks / 302 clocks, errors=0. Enable=1 is 1589 cells / 644
flip-flops. BeginRun requires in_rp, LOOKUPs the CMDBUF, then clears
in_rp.

`g6lc_apu_vvb` decodes `vkCmdBindVertexBuffers` (command type 105, one
binding, offset 0). `VvbEn` defaults to 0. Remote 2026-10-02:
`tb_g6lc_apu_vvb` 7 cases / 12 checks / 372 clocks, errors=0.
Enable=1 is 1914 cells / 708 flip-flops. BeginRun requires a begun
CMDBUF, LOOKUPs that CMDBUF, then LOOKUPs BUFFER and sets vtx_bound.

`g6lc_apu_vib` decodes `vkCmdBindIndexBuffer` (command type 104,
UINT16, offset 0). `VibEn` defaults to 0. Remote 2026-10-02:
`tb_g6lc_apu_vib` 7 cases / 12 checks / 360 clocks, errors=0.
Enable=1 is 1879 cells / 708 flip-flops. BeginRun requires a begun
CMDBUF, LOOKUPs that CMDBUF, then LOOKUPs BUFFER and sets idx_bound.

`g6lc_apu_vdi` decodes `vkCmdDrawIndexed` (command type 107, three
indices, one instance). `VdiEn` defaults to 0. Remote 2026-10-02:
`tb_g6lc_apu_vdi` 7 cases / 12 checks / 362 clocks, errors=0.
Enable=1 is 1822 cells / 676 flip-flops. BeginRun requires begun,
in_rp, pipe_bound, vtx_bound, and idx_bound, then LOOKUPs the
CMDBUF. GENERATE_REPLY shares CS mux slot 31.

`g6lc_apu_vvp` decodes `vkCmdSetViewport` (command type 94, one 64x64
viewport, float width/height 64.0). `VvpEn` defaults to 0. Remote
2026-10-02: `tb_g6lc_apu_vvp` 7 cases / 12 checks / 422 clocks,
errors=0. Enable=1 is 1932 cells / 676 flip-flops. BeginRun requires
a begun CMDBUF, then LOOKUPs that CMDBUF.

`g6lc_apu_vsi` decodes `vkCmdSetScissor` (command type 95, one 64x64
scissor). `VsiEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vsi`
7 cases / 12 checks / 398 clocks, errors=0. Enable=1 is 1856 cells /
676 flip-flops. BeginRun requires a begun CMDBUF, then LOOKUPs that
CMDBUF.

`g6lc_apu_vpb` decodes `vkCmdPipelineBarrier` (command type 126,
TOP_OF_PIPE, zero memory/buffer/image barriers). `VpbEn` defaults to
0. Remote 2026-10-02: `tb_g6lc_apu_vpb` 7 cases / 12 checks / 374
clocks, errors=0. Enable=1 is 1855 cells / 676 flip-flops. BeginRun
requires a begun CMDBUF, then LOOKUPs that CMDBUF.

`g6lc_apu_vns` decodes `vkCmdNextSubpass` (command type 134, INLINE).
`VnsEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vns` 7 cases /
12 checks / 314 clocks, errors=0. Enable=1 is 1685 cells / 676
flip-flops. The decoder accepts the compact CS. BeginRun FAULTS
because the compact render pass has one subpass. GENERATE_REPLY
shares CS mux slot 31. The CVA6 cookie was not re-run. The TEX opcode
still returns `-26`.

`g6lc_apu_vdf` decodes `vkDestroyFramebuffer` (command type 81).
`VdfEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vdf` 7 cases /
12 checks / 350 clocks, errors=0. Enable=1 is 1846 cells / 708
flip-flops. BeginRun LOOKUPs FBUF then `APU_GNH_RETIRE` and clears
`fbuf_ok`.

`g6lc_apu_vdx` decodes `vkDestroyImageView` (command type 58).
`VdxEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vdx` 7 cases /
12 checks / 350 clocks, errors=0. Enable=1 is 1847 cells / 708
flip-flops. BeginRun LOOKUPs VIEW then RETIRE.

`g6lc_apu_vdk` decodes `vkDestroySampler` (command type 71).
`VdkEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vdk` 7 cases /
12 checks / 350 clocks, errors=0. Enable=1 is 1847 cells / 708
flip-flops. BeginRun LOOKUPs SAMPLER then RETIRE.

`g6lc_apu_vdr` decodes `vkDestroyRenderPass` (command type 83).
`VdrEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vdr` 7 cases /
12 checks / 350 clocks, errors=0. Enable=1 is 1847 cells / 708
flip-flops. BeginRun LOOKUPs RPASS then RETIRE and clears `rp_ok`.
GENERATE_REPLY shares CS mux slot 31. The CVA6 cookie was not re-run.
The TEX opcode still returns `-26`.

`g6lc_apu_vdb` decodes `vkDestroyBuffer` (command type 51). `VdbEn`
defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vdb` 7 cases / 12
checks / 350 clocks, errors=0. Enable=1 is 1847 cells / 708
flip-flops. BeginRun LOOKUPs BUFFER then `APU_GNH_RETIRE`.

`g6lc_apu_vdg` decodes `vkDestroyImage` (command type 55). `VdgEn`
defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vdg` 7 cases / 12
checks / 350 clocks, errors=0. Enable=1 is 1848 cells / 708
flip-flops. BeginRun LOOKUPs IMAGE then RETIRE.

`g6lc_apu_vfe` decodes `vkFreeMemory` (command type 22). `VfeEn`
defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vfe` 7 cases / 12
checks / 350 clocks, errors=0. Enable=1 is 1846 cells / 708
flip-flops. BeginRun LOOKUPs MEMORY then RETIRE after buffer and
image are retired.

`g6lc_apu_vdm` decodes `vkDestroyShaderModule` (command type 60).
`VdmEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vdm` 7 cases /
12 checks / 350 clocks, errors=0. Enable=1 is 1847 cells / 708
flip-flops. BeginRun LOOKUPs MODULE then RETIRE and clears
`loaded_q`. GENERATE_REPLY shares CS mux slot 31. The CVA6 cookie was
not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vdp` decodes `vkDestroyPipeline` (command type 67). `VdpEn`
defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vdp` 7 cases / 12
checks / 350 clocks, errors=0. Enable=1 is 1846 cells / 708
flip-flops. BeginRun LOOKUPs PIPELINE then RETIRE and clears
`pipe_bound`. Happy path retires graphics then compute pipeline.

`g6lc_apu_vdy` decodes `vkDestroyPipelineLayout` (command type 69).
`VdyEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vdy` 7 cases /
12 checks / 350 clocks, errors=0. Enable=1 is 1846 cells / 708
flip-flops. BeginRun LOOKUPs PLAYOUT then RETIRE and clears `pl_ok`.

`g6lc_apu_vdt` decodes `vkDestroyDescriptorSetLayout` (command type
73). `VdtEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vdt` 7
cases / 12 checks / 350 clocks, errors=0. Enable=1 is 1846 cells /
708 flip-flops. BeginRun LOOKUPs DSLAYOUT then RETIRE and clears
`dsl_ok`.

`g6lc_apu_vdq` decodes `vkDestroyDescriptorPool` (command type 75).
`VdqEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vdq` 7 cases /
12 checks / 350 clocks, errors=0. Enable=1 is 1847 cells / 708
flip-flops. BeginRun LOOKUPs POOL then RETIRE and clears `pool_ok`.

`g6lc_apu_vfs` decodes `vkFreeDescriptorSets` (command type 78).
`VfsEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vfs` 7 cases /
12 checks / 372 clocks, errors=0. Enable=1 is 2043 cells / 772
flip-flops. Compact CS count 1; pool is not LOOKed up. BeginRun
LOOKUPs DESCSET then RETIRE and clears `dset_ok`.

`g6lc_apu_vrc` decodes `vkResetCommandBuffer` (command type 92).
`VrcEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vrc` 7 cases /
12 checks / 314 clocks, errors=0. Enable=1 is 1622 cells / 644
flip-flops. BeginRun LOOKUPs CMDBUF and clears recording flags.
No RETIRE.

`g6lc_apu_vfc` decodes `vkFreeCommandBuffers` (command type 89).
`VfcEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vfc` 7 cases /
12 checks / 372 clocks, errors=0. Enable=1 is 2043 cells / 772
flip-flops. Compact CS count 1; vac pool `64'hA1` is not LOOKed up.
BeginRun LOOKUPs CMDBUF then RETIRE.

`g6lc_apu_vdd` decodes `vkDestroyDevice` (command type 12).
`VddEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vdd` 7 cases /
12 checks / 328 clocks, errors=0. Enable=1 is 1652 cells / 644
flip-flops. CS is (device, allocator). BeginRun LOOKUPs DEVICE then
RETIRE. `apu_bru_op_e` is 7 bits. bru FSM state enum is 8 bits.
GENERATE_REPLY shares CS mux slot 31.

`g6lc_apu_vpc` decodes `vkResetCommandPool` (command type 87).
`VpcEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vpc` 7 cases /
12 checks / 336 clocks, errors=0. Enable=1 is 1816 cells / 708
flip-flops. Compact CS reset flags 0; vac pool `64'hA1` is not
LOOKed up. BeginRun LOOKUPs DEVICE.

`g6lc_apu_vdc` decodes `vkDestroyCommandPool` (command type 86).
`VdcEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vdc` 7 cases /
12 checks / 350 clocks, errors=0. Enable=1 is 1847 cells / 708
flip-flops. Compact CS null allocator; pool is not LOOKed up.
BeginRun LOOKUPs DEVICE.

`g6lc_apu_vdn` decodes `vkDestroyInstance` (command type 1).
`VdnEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vdn` 7 cases /
12 checks / 328 clocks, errors=0. Enable=1 is 1651 cells / 644
flip-flops. CS is (instance, allocator). BeginRun LOOKUPs INSTANCE
then RETIRE and clears `instanced_q`.

`g6lc_apu_vgf` decodes `vkGetPhysicalDeviceFormatProperties`
(command type 4). `VgfEn` defaults to 0. Remote 2026-10-02:
`tb_g6lc_apu_vgf` 7 cases / 12 checks / 340 clocks, errors=0.
Enable=1 is 1750 cells / 676 flip-flops. Compact format 37 FEATURES
`32'h00006083`. BeginRun LOOKUPs PHYS.

`g6lc_apu_vip` decodes `vkGetPhysicalDeviceImageFormatProperties`
(command type 5). `VipEn` defaults to 0. Remote 2026-10-02:
`tb_g6lc_apu_vip` 7 cases / 12 checks / 388 clocks, errors=0.
Enable=1 is 1885 cells / 676 flip-flops. Compact 64×64 STORAGE
linear. BeginRun LOOKUPs PHYS.

`g6lc_apu_vxe` decodes `vkEnumerateDeviceExtensionProperties`
(command type 14). `VxeEn` defaults to 0. Remote 2026-10-02:
`tb_g6lc_apu_vxe` 7 cases / 12 checks / 366 clocks, errors=0.
Enable=1 is 1750 cells / 644 flip-flops. Compact count 0. BeginRun
LOOKUPs PHYS.

`g6lc_apu_vrd` decodes `vkResetDescriptorPool` (command type 76).
`VrdEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vrd` 7 cases
/ 12 checks / 336 clocks, errors=0. Enable=1 is 1814 cells / 708
flip-flops. Compact reset flags 0. BeginRun LOOKUPs POOL and clears
`desc_bound`.

`g6lc_apu_vie` decodes `vkEnumerateInstanceExtensionProperties`
(command type 13). `VieEn` defaults to 0. Remote 2026-10-02:
`tb_g6lc_apu_vie` 7 cases / 12 checks / 344 clocks, errors=0.
Enable=1 is 1557 cells / 580 flip-flops. Compact count 0. BeginRun
does not LOOKUP a handle.

`g6lc_apu_vwl` decodes `vkDeviceWaitIdle` (command type 20).
`VwlEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vwl` 7 cases
/ 12 checks / 300 clocks, errors=0. Enable=1 is 1587 cells / 644
flip-flops. BeginRun LOOKUPs DEVICE after submit.

`g6lc_apu_vsl` decodes `vkGetImageSubresourceLayout` (command type
56). `VslEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vsl` 7
cases / 12 checks / 388 clocks, errors=0. Enable=1 is 1945 cells /
708 flip-flops. Compact rowPitch 256. BeginRun LOOKUPs IMAGE.

`g6lc_apu_vrg` decodes `vkGetRenderAreaGranularity` (command type
84). `VrgEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vrg` 7
cases / 12 checks / 350 clocks, errors=0. Enable=1 is 1845 cells /
708 flip-flops. Compact 1×1. BeginRun LOOKUPs RPASS.

`g6lc_apu_vlw` decodes `vkCmdSetLineWidth` (command type 96).
`VlwEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vlw` 7 cases /
12 checks / 312 clocks, errors=0. Enable=1 is 1627 cells / 644
flip-flops. Compact width 1.0. BeginRun LOOKUPs CMDBUF after begin.

`g6lc_apu_vzb` decodes `vkCmdSetDepthBias` (command type 97).
`VzbEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vzb` 7 cases /
12 checks / 336 clocks, errors=0. Enable=1 is 1687 cells / 644
flip-flops. Compact factors 0. BeginRun LOOKUPs CMDBUF after begin.

`g6lc_apu_vbc` decodes `vkCmdSetBlendConstants` (command type 98).
`VbcEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vbc` 7 cases /
12 checks / 348 clocks, errors=0. Enable=1 is 1720 cells / 644
flip-flops. Compact zeros. BeginRun LOOKUPs CMDBUF after begin.

`g6lc_apu_vbo` decodes `vkCmdSetDepthBounds` (command type 99).
`VboEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vbo` 7 cases /
12 checks / 324 clocks, errors=0. Enable=1 is 1662 cells / 644
flip-flops. Compact min 0 max 1.0. BeginRun LOOKUPs CMDBUF after
begin.

`g6lc_apu_vcm` decodes `vkCmdSetStencilCompareMask` (command type
100). `VcmEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vcm` 7
cases / 12 checks / 324 clocks, errors=0. Enable=1 is 1688 cells /
644 flip-flops. Compact FRONT_AND_BACK mask all-ones. BeginRun
LOOKUPs CMDBUF after begin.

`g6lc_apu_vwm` decodes `vkCmdSetStencilWriteMask` (command type 101).
`VwmEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vwm` 7 cases /
12 checks / 324 clocks, errors=0. Enable=1 is 1689 cells / 644
flip-flops. Compact FRONT_AND_BACK mask all-ones. BeginRun LOOKUPs
CMDBUF after begin.

`g6lc_apu_vrf` decodes `vkCmdSetStencilReference` (command type 102).
`VrfEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vrf` 7 cases /
12 checks / 324 clocks, errors=0. Enable=1 is 1657 cells / 644
flip-flops. Compact FRONT_AND_BACK ref 0. BeginRun LOOKUPs CMDBUF
after begin.

`g6lc_apu_vcc` decodes `vkCmdCopyBuffer` (command type 112).
`VccEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vcc` 8 cases /
13 checks / 505 clocks, errors=0. Enable=1 is 2205 cells / 772
flip-flops. Compact one 2048-byte non-overlapping region. BeginRun
LOOKUPs CMDBUF then BUFFER src then BUFFER dst; extra `!begun` /
`in_rp`.

`g6lc_apu_vcy` decodes `vkCmdCopyImage` (command type 113).
`VcyEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vcy` 8 cases /
13 checks / 785 clocks, errors=0. Enable=1 is 3714 cells / 1284
flip-flops. Compact TRANSFER layouts, 32x64 half-window. BeginRun
LOOKUPs CMDBUF then IMAGE src then IMAGE dst; extra `!begun` / `in_rp`.

`g6lc_apu_vbl` decodes `vkCmdBlitImage` (command type 114).
`VblEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vbl` 8 cases /
13 checks / 839 clocks, errors=0. Enable=1 is 3849 cells / 1284
flip-flops. Compact NEAREST 32x64 blit. BeginRun LOOKUPs CMDBUF then
IMAGE src then IMAGE dst; extra `!begun` / `in_rp`.

`g6lc_apu_vbt` decodes `vkCmdCopyBufferToImage` (command type 115).
`VbtEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vbt` 8 cases /
13 checks / 727 clocks, errors=0. Enable=1 is 3577 cells / 1284
flip-flops. Compact 32x32 color window (4096 bytes). BeginRun LOOKUPs
CMDBUF then BUFFER src then IMAGE dst; extra `!begun` / `in_rp`.

`g6lc_apu_vic` decodes `vkCmdCopyImageToBuffer` (command type 116).
`VicEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vic` 8 cases /
13 checks / 727 clocks, errors=0. Enable=1 is 3575 cells / 1284
flip-flops. Compact 32x32 color window (4096 bytes). BeginRun LOOKUPs
CMDBUF then IMAGE src then BUFFER dst; extra `!begun` / `in_rp`.

`g6lc_apu_vub` decodes `vkCmdUpdateBuffer` (command type 117).
`VubEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vub` 8 cases /
13 checks / 421 clocks, errors=0. Enable=1 is 1947 cells / 708
flip-flops. Compact offset 0 size 4 data 0. BeginRun LOOKUPs CMDBUF
then BUFFER; extra `!begun` / `in_rp`.

`g6lc_apu_vfl` decodes `vkCmdFillBuffer` (command type 118).
`VflEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vfl` 8 cases /
13 checks / 419 clocks, errors=0. Enable=1 is 1947 cells / 708
flip-flops. Compact size 4096 data 0. BeginRun LOOKUPs CMDBUF then
BUFFER; extra `!begun` / `in_rp`.

`g6lc_apu_vcl` decodes `vkCmdClearColorImage` (command type 119).
`VclEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vcl` 8 cases /
13 checks / 671 clocks, errors=0. Enable=1 is 3219 cells / 1220
flip-flops. Compact TRANSFER_DST zeros. BeginRun LOOKUPs CMDBUF then
IMAGE; extra `!begun` / `in_rp`.

`g6lc_apu_vio` decodes `vkCmdDrawIndirect` (command type 108).
`VioEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vio` 8 cases /
13 checks / 405 clocks, errors=0. Enable=1 is 1915 cells / 708
flip-flops. Compact drawCount 1 stride 16. BeginRun LOOKUPs CMDBUF
then BUFFER; extra `begun` / `in_rp` / `pipe_bound`. CS prefix is
`APU_DRI_*` so DestroyInstance keeps `APU_DIN_*`.

`g6lc_apu_vix` decodes `vkCmdDrawIndexedIndirect` (command type 109).
`VixEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vix` 8 cases /
13 checks / 405 clocks, errors=0. Enable=1 is 1917 cells / 708
flip-flops. Compact drawCount 1 stride 20. BeginRun LOOKUPs CMDBUF
then BUFFER; extra also `vtx_bound` / `idx_bound`.

`g6lc_apu_vds` decodes `vkCmdClearDepthStencilImage` (command type
120). `VdsEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vds` 8
cases / 13 checks / 685 clocks, errors=0. Enable=1 is 3158 cells /
1220 flip-flops. Compact TRANSFER_DST depth 1.0 ASPECT_DEPTH.
BeginRun LOOKUPs CMDBUF then IMAGE; extra `!begun` / `in_rp`.

`g6lc_apu_vat` decodes `vkCmdClearAttachments` (command type 121).
`VatEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vat` 8 cases /
13 checks / 659 clocks, errors=0. Enable=1 is 3123 cells / 1156
flip-flops. Compact one COLOR 64x64 rect. BeginRun LOOKUPs CMDBUF;
extra `begun` / `in_rp`.

`g6lc_apu_vin` decodes `vkCmdDispatchIndirect` (command type 111).
`VinEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vin` 8 cases /
13 checks / 379 clocks, errors=0. Enable=1 is 1849 cells / 708
flip-flops. Compact offset 0. BeginRun LOOKUPs CMDBUF then BUFFER;
extra `begun` / `!in_rp` / `pipe_bound` / `desc_bound` / `loaded`.
Does not Kick the compute add.

`g6lc_apu_vrs` decodes `vkCmdResolveImage` (command type 122).
`VrsEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vrs` 8 cases /
13 checks / 783 clocks, errors=0. Enable=1 is 3715 cells / 1284
flip-flops. Compact TRANSFER layouts, 32x32 half-window. BeginRun
LOOKUPs CMDBUF then IMAGE src then IMAGE dst; extra `!begun` / `in_rp`.

`g6lc_apu_vgs` decodes `vkGetFenceStatus` (command type 38).
`VgsEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vgs` 8 cases /
13 checks / 377 clocks, errors=0. Enable=1 is 1781 cells / 708
flip-flops. Compact VK_SUCCESS. BeginRun LOOKUPs DEVICE. No FENCE kind.

`g6lc_apu_vwf` decodes `vkWaitForFences` (command type 39).
`VwfEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vwf` 8 cases /
13 checks / 405 clocks, errors=0. Enable=1 is 1915 cells / 708
flip-flops. Compact count 1 waitAll timeout 0. BeginRun LOOKUPs DEVICE
after submit.

`g6lc_apu_vfr` decodes `vkResetFences` (command type 37).
`VfrEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vfr` 8 cases /
13 checks / 391 clocks, errors=0. Enable=1 is 1815 cells / 708
flip-flops. Compact count 1. BeginRun LOOKUPs DEVICE.

`g6lc_apu_vfn` decodes `vkDestroyFence` (command type 36).
`VfnEn` defaults to 0. Remote 2026-10-02: `tb_g6lc_apu_vfn` 8 cases /
13 checks / 379 clocks, errors=0. Enable=1 is 1845 cells / 708
flip-flops. BeginRun LOOKUPs DEVICE; no RETIRE. CreateFence=35 skipped.
The CVA6 cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_eal` ALLOCs a CMDBUF from `vkAllocateCommandBuffers`,
looks that published handle up on `vkBeginCommandBuffer`, then
looks the begun handle up on `vkEndCommandBuffer` on one
GenHandle table. Record field is `end_cmd`. End before allocate
or begin, MODULE-as-cmdbuf, a second end, and `vkCreateInstance`
fault. Enable=0 is quiet. `EalEn` defaults to 0 and does not make
virgl legal. `ApuCfg.NumCapsets` stays 0. The unit is not a child
of `g6lc_apu_sys`. Remote 2026-10-01: `tb_g6lc_apu_eal` 10 cases /
22 checks / 778 clocks, errors=0. Fixture synth, no latches:
Enable=0 is 13 ports and no cells; Enable=1 is 10853 cells / 2749
flip-flops. The CVA6 cookie was not re-run. The TEX opcode still
returns `-26`.

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
