# APU TGSI subset compiler

**Domain:** graphics uncore · **Status:** host-testable firmware leaf (P2)

Compile frozen `gles2-min` TGSI **text** to native APU exec words. EGL/GLES
stay in client Mesa. This is not a virgl command decoder and not TEX/control-flow.
Immediates lower through native `LDC` (next IMEM word).

## Intent

Three compartments:

1. **Compiler** (`g6lc_apu_tgsi.c`) — host-testable, freestanding, no libc.
2. **Job policy** (`g6lc_apu_tgsi_job.c`) — host `tgsi_fw_check`: TEX fail closed,
   then `MOV TEMP[0], TEMP[1]`.
3. **Mini-hart image** (`apu_tgsi_fw.c`) — pre-encoded MOV + shader RUN
   + peek. Does not link the compiler (`ld`/`sd` exceed the mini-hart).
4. **CVA6 compile image** (`apu_tgsi_cc.c`) — links compiler + job.
   On-hart `compile()` walks TGSI (`tch`/`pinc` 64-bit add): TEX → `-26`,
   MOV opcode → `-1`. Job emits frozen `APU_TGSI_JOB_MOV_WORD`+HALT
   (emit inside `compile()` hung the scan loop). Cookie `0x600D000B`.
   Bring-up `apu_fw.elf` stays TID+IADD (`0x600D000A`).

No FeatureVirgl.

## Seams

| Piece | Path |
|---|---|
| API | `software/apu-fw/include/g6lc_apu_tgsi.h` |
| Compiler | `software/apu-fw/src/g6lc_apu_tgsi.c` |
| Job policy | `g6lc_apu_tgsi_job.{h,c}` (TEX fail-closed, then MOV; `APU_TGSI_JOB_MOV_WORD`) |
| Encodings | `software/apu-fw/include/g6lc_apu_exec.h` (`APU_EX_ENC`) |
| Host tests | `tgsi_check.c`, `tgsi_fw_check.c` |
| TGSI job | `software/apu-fw/src/apu_tgsi_fw.c` → `verif/tb/apu/apu_tgsi.hex` |
| CVA6 compile image | `software/apu-fw/src/apu_tgsi_cc.c` → `verif/tb/apu/apu_tgsi_cc.hex` |
| DUT harness | `verif/tb/apu/g6lc_apu_minihart_sys.sv` (shared with bring-up hart TB) |
| TB | `verif/tb/apu/tb_g6lc_apu_tgsi_fw.sv`, `tb_g6lc_apu_cva6_tgsi.sv` |
| ISA | `apu_exec_op_e` in `g6lc_apu_pkg.sv` (`FSUB`/`FNEG`/`LDC`) |

## Register map

| TGSI | Native |
|---|---|
| `IN[n]` / `OUT[n]` / `CONST[n]` | `r[n]` (`n < 8`) |
| `TEMP[n]` | `r[4+n]` (`4+n < 8`) |

Identity `.xyzw` and splat `.xxxx/.yyyy/.zzzz/.wwww` are accepted. Other
swizzles, `TEX`, `IF`, src0 register-negate, or `SAMP` use is rejected.
`IMM[n] FLT32 {a,b,c,d}` and inline `{0, 0.5, 1, 2}` (and negatives) emit
`LDC` plus a 32-bit payload. Non-splat IMM requires `.xxxx/.yyyy/.zzzz/.wwww`.
Unknown immediates fail closed.

| TGSI | Native |
|---|---|
| `MOV dst, src` | `MOV` |
| `MOV dst, IMM` / `MOV dst, 1.0` | `LDC` + payload |
| `MOV dst, -src` | `FNEG` |
| `ADD dst, a, b` | `FADD` |
| `ADD dst, a, -b` / `SUB dst, a, b` | `FSUB` |
| `SUB dst, a, -b` | `FADD` |
| `MUL` / `MAD` | `FMUL` / `FMADD` |
| `END` | `HALT` |

## Invariants

- Encodings equal SV `apu_exec_enc` (`enc_check`).
- Fail closed on unsupported tokens. Do not emit a successful no-op.
- `FeatureVirgl` remains illegal. No DRAM DMA. SMT OpenSBI unchanged.
- Compiler is not linked into `apu_fw.elf` or the mini-hart `apu_tgsi_fw`
  image. CVA6 `apu_tgsi_cc.elf` links compiler + job. Host keeps the full
  parser; the RISC-V path is opcode-only plus frozen MOV emit.
- Bring-up cookie `0x600D000A` vs TGSI job cookie `0x600D000B`.
- Firmware MOV word must equal `g6lc_apu_tgsi_job_compile` output.

## Verification

Host `gcc` (`make -C software/apu-fw tgsi-check tgsi-fw-check`) (2026-09-15):
**`PASS tgsi_check`**, **`PASS tgsi_fw_check`**. Remote `run-exec.sh`:
**`tb_g6lc_apu_tgsi_fw` 188 checks / 3,486 clocks**, cookie `0x600D000B`,
peek `r4=1.0f` on threads 0/1 (pre-encoded MOV image; compiler not
resident). Mini-hart now executes `ld`/`sd`/`addw`/`srli` used by the
peek CPL0 ordering. **`tb_g6lc_apu_exec` 12/29/886** includes `LDC r4, 1.0f`.
Directed host cases cover `MOV`/`MAD`/`ADD`+`MUL`/`SUB`/negate/`CONST`/
`IMM[n]`/`-1.0` and reject `TEX`/`IF`/src0 negate/`0.3`. Remote
`run-cva6-tgsi.sh` rc=0: **`tb_g6lc_apu_cva6_tgsi` 14 checks / 2,081 clocks**,
cookie `0x600D000B` (pre-encoded MOV through compositor). Remote
`run-cva6-tgsi-cc.sh` rc=0: **14 checks / 10,511 clocks**, cookie
`0x600D000B` (resident compile image; mailbox IDX+DATA forced `sw`).
Peek CPL0 is address-dependent on GO/STAT so CVA6 cannot issue that
uncached load while an earlier mailbox store is still in the write
buffer. Not Mesa, not TEX.
