# APU firmware-bound native exec

**Domain:** graphics uncore · **Status:** standalone default-off leaf (P1)

Firmware mailbox ops load IMEM/RF, run the native exec cluster, and peek
RF or local DMEM. EGL/GLES stay in client Mesa. Testharness compositor
binds exec when `ExecEn=1 && !MemEn`. `ApuHarness.ExecEn` stays 0.

## Intent

Bind `g6lc_apu_exec` under the protected control mailbox so resident firmware
can start a micro or shader job without a debug-port TB. Local SRAM only.

## Seams

| Piece | Path |
|---|---|
| Ops | `APU_MEM_EXEC_{IMEM,POKE,PEEK,RUN,DPEEK}` in `g6lc_apu_pkg` |
| Bind | `corev_apu/apu/g6lc_apu_exec_bind.sv` |
| Wrapper | `corev_apu/apu/g6lc_apu_fw.sv` (AXI-lite + mailbox + bind) |
| SoC | `g6lc_apu_sys` `gen_exec` when `ExecEn && !MemEn` |
| Flist | `Flist.apu_fw`; exec also on `Flist.apu_soc` |

## Invariants

- Default-off: `ExecEn=0` is AXI-lite bookkeeping only. `FeatureVirgl` remains illegal.
- Mailbox lives at `ControlBase+0x80`. Guest virtio cannot reach it.
- `RUN` with `priv=1` in a shader job faults (`APU_DMA_PROTOCOL`).
- Non-exec mailbox ops complete `APU_DMA_PERMISSION` on this wrapper.
- `DPEEK` returns local DMEM word `job.data[5:0]`. Shader `ST` of `1.0f` to
  byte 0 peeks `0x3f800000` (headless color, not `glReadPixels`).
- No DRAM DMA, raster, or sampler. `MemEn && ExecEn` together is not this
  leaf. Production `ApuHarness.ExecEn=0`.

## Verification

`APU_EXEC=1 APU_SYNTH=1` on `verif/tb/apu/run-virtio-mmio.sh`. Remote
Verilator 5.008 (2026-09-15): **`tb_g6lc_apu_fw` 27 cases / 202 checks /
849 clocks / errors=0**. Enabled generic synth 46,181 cells / 7,063
sequential bits; disabled 522 / 162 (AXI-lite bookkeeping, no FPnew).
Directed cases: mailbox IMEM load, micro `TID`+`IADD` peek 10/11, shader
`priv` fault, non-exec mailbox op `PERMISSION`. `run-th-exec.sh` rc=0:
**`tb_g6lc_apu_th_exec` 64 cases / 513 checks / 3,071 clocks** (compositor
AXI4 control, peek 10/11, shader MOV, shader `ST`+`DPEEK` `1.0f`,
scanline-fill microprogram DMEM[0..3], packed `size=3` IDX+DATA).
Screening synth 4 KiB enabled 155,978 / 40,114 sequential; disabled
275 / 27. Not mapped area or STA. Results also live in `AGENTS-todo.md`.
