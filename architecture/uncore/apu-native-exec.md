# APU native execution cluster

**Domain:** graphics uncore · **Status:** standalone default-off leaf (P1)

One physical FP32/integer lane time-multiplexes four lockstep fragment-quad
contexts. EGL/GLES stay in client Mesa; this leaf executes a compact native
instruction stream, not TGSI and not a service-hart shader loop. `LDC`
loads a 32-bit constant from the following IMEM word.

## Intent

P1 step 6 of the API-neutral APU plan: native arithmetic, predication,
uniform lockstep BR, local privilege-separated LD/ST, and quad-context
state on existing FPnew/integer units, with microprogram versus
application-shader access.

## Seams

| Piece | Path |
|---|---|
| Config | `ExecEn`, `ExecQuadThreads=4`, `ExecRegs=8` in `g6lc_apu_cfg_pkg` |
| ISA | `apu_exec_inst_t` / `apu_exec_op_e` in `g6lc_apu_pkg` |
| RTL | `corev_apu/apu/g6lc_apu_exec.sv` |
| FPnew | `fpnew_fma` FP32 only — not `g6lc_ai_fp_mac`, not the CPU `fpu_wrap` |
| Flist | `corev_apu/apu/Flist.apu_exec` (not production / testharness) |

## Invariants

- Default-off: `ExecEn=0` is zero cells. `FeatureVirgl` remains illegal.
- Four threads share a PC; one thread issues per cycle onto one FMA/ALU.
- Predicated ops skip the register write when the thread mask is clear.
- `priv=1` instructions fault in a shader job; micro jobs may execute them.
- `QUADX` reads a snapshot of `rs1` so pair 0↔1 and 2↔3 exchange without tearing.
- Uniform `BR` is lockstep: taken if `|mask`, else `pc+1`. Out-of-range
  targets fault. `LDC` writes `imem[pc+1]` and advances `pc+2` (fault if the
  payload slot is missing). Local `LD`/`ST` use byte `ea=rs1+sext(imm)`,
  word-aligned; micro sees all `ExecMemWords`, shader only the low half.
  DMEM is local SRAM, not DRAM. Mailbox `DPEEK` reads it back as a headless
  color word. A microprogram BR loop can fill a 4-pixel span. No triangle
  coverage, sampler, blending, or DRAM LSU in this leaf.

## Verification

`APU_EXEC=1 APU_SYNTH=1` on `verif/tb/apu/run-virtio-mmio.sh`. Remote
Verilator 5.008 (2026-09-15): **12 cases / 29 checks / 886 clocks / errors=0**.
Enabled generic synth 23,329 cells / 3,888 sequential bits; disabled zero
cells (asserted). Directed cases: integer add with `TID`, predicated writes,
FP32 `FMADD` 1×2+3=5, `FSUB` 2−1=1, `FNEG` 1.0→−1.0, `LDC` 1.0f, quad
exchange, shader rejection of a micro op, taken BR (skip delay slot),
not-taken BR after `SETMASK 0`, micro `ST`/`LD` 42, shader store to byte 128
(word 32 = M/2) faults. Not mapped area or STA. Results also live in
`AGENTS-todo.md`.
