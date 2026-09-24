# APU firmware-bound native execution

**Domain:** graphics uncore · **Status:** default-off mailbox/local-exec prototype

`g6lc_apu_fw.sv` and `g6lc_apu_exec_bind.sv` expose native IMEM load,
RF poke/peek, RUN and DMEM peek through `ACTRL_MAIL_*` at control+`0x80`.
EGL/GLES remain in Mesa/client software. Mailbox access is private management,
not a replacement Linux graphics driver or a BIOS public rendering ABI.

## Current composition

`g6lc_apu_sys` selects memory, native execution, or both.
`g6lc_apu_sched` is the pair: one mailbox presents each op to exactly one
client. The other client is not presented that op. `ApuHarness` keeps
native execution and the memory clients off. `ApuSchedBoth` is the proof
profile, not the boot config. Exec does not read the mapping. A handle
resolver is still open.

| Operation | Diagnostic effect |
|---|---|
| `APU_MEM_EXEC_IMEM` | Load a native word into the 16-word program array |
| `APU_MEM_EXEC_POKE/PEEK` | Set/read one invocation register |
| `APU_MEM_EXEC_RUN` | Start a microjob or shader job |
| `APU_MEM_EXEC_DPEEK` | Return local DMEM word indexed by `job.data[5:0]` |

Shader privilege is checked for fetch-only and ordinary instructions after
the decode review. Non-exec mailbox commands return PERMISSION on the exec-only
wrapper. DMEM is currently a resettable array, not a tc_sram-backed surface.

## Required integration, before new graphics grants

1. `g6lc_apu_sched` composes memory and execution under one mailbox.
   Each op is presented to one client. Exec does not consume the mapping.
   Command DMA resolves a published slot. Scatter-gather and the used ring
   still take raw maps.
2. Carry resource/context/epoch/tag/program identity and completion status
   end to end. `exec_bind` currently returns mostly zero metadata; that is
   insufficient to publish context-scoped fences or service health.
3. A mapping slot, the command snapshot, and a scatter-gather table stay
   published until the child DMA is idle. `g6lc_apu_storage` takes
   `child_idle_i`. Insert, invalidate, and command release wait for it, and
   a one-cycle invalidate or release is applied when the child later goes
   idle. `g6lc_apu_mem` ties that pin to read, write, and SG idle. The SG
   table stays visible through invalidate until its list reader and fragment
   DMA are idle and the unit is not mid-query. Remote 2026-09-22: storage
   36 cases / 170 checks / 668 clocks; SG entries=64, 122 cases / 6,593
   checks / 11,352 clocks. Storage post-synth: disabled ports only; enabled
   1,296 cells / 91 flip-flops. SG post-synth, no latches: disabled ports
   only; enabled 58,237 cells / 13,266 flip-flops, one memory before mapping.
   Command DMA does not use the mailbox base. `g6lc_apu_mem` looks the
   request's resource, context, and epoch up in that table (`write_access`
   0) and pins `apu_handle_pin` of the published slot before the read.
   A missing id is `APU_DMA_BAD_RESOURCE`, a mismatched epoch is
   `APU_DMA_STALE`, and neither issues a read. Dropping the pin while the
   DMA is idle makes the next command DMA of that id fail the same way.
   Scatter-gather list and backing maps, and the used ring, still take the
   raw mailbox mapping. Exec `LD`/`ST` remains local DMEM. A command-read
   word already presented stays until the consumer takes it; a new read
   waits for that. Remote 2026-09-22: `tb_g6lc_apu_mem` 10 cases / 19
   checks / 227 clocks, errors=0. Mem fixture synth: Enable=0 is 35 ports
   and no cells; Enable=1 is 48,788 cells / 12,119 flip-flops, and the
   final netlist has no latch cells. Coverage, a shader surface load, and
   the virtqueue decoder remain open.
4. Cancellation of an accepted exec op produces a completion and holds it
   until acknowledged. A disabled exec op is not marked ready. A GO the
   mailbox has not handed off is recorded as cancelled immediately; a job
   the backend already took stays busy until that completion arrives.
   Program and resource leases are the storage/SG pin above, not this handshake.
5. Include both mailbox and all backend work in stop/reset drain. Aggregate
   per-queue stop as well as device reset; software acknowledgement alone is
   not proof that a memory transaction or shader is retired.
6. Program/RF/DMEM peeks are diagnostics. Final headless readback is a normal
   resource transfer with cache visibility and fence ordering, not DPEEK.

## BIOS and Linux relationship

The optional BIOS manager requests load/start/health through the trusted
supervisor contract in `apu-firmware-domain.md`. It does not become a second
private-mailbox owner while the resident service is running. BIOS rendering
uses standard virtio queues, then drains/resets them before Linux ownership.
The service and common surface contract are shared; build systems, BIOS UI,
Linux boot journal and firmware implementation cycles remain independent.

A ready response must identify the running firmware/native ISA/config and
fresh instance, not merely show a successful mailbox job. Firmware restart
must invalidate guest epochs and drain bus work before replacing code.

## Verification

Historical `d74010111` evidence: mailbox leaf 27 cases / 202 checks / 849
clocks; compositor `run-th-exec.sh` 64 cases / 513 checks / 3,071 clocks.
The latter covers TID/IADD, shader MOV, local `ST`/`DPEEK`, a four-word
scanline fill and packed AXI4 stores. It is not a real framebuffer or Linux
GLES2 proof. Generic 4-KiB compositor screening: 155,978 cells / 40,114
sequential bits, disabled 275 / 27; not macro area or STA.

Review revalidation: mailbox 27 cases / 201 checks / 844 clocks; compositor
64 / 513 / 3,071 passes again. Enabled 4-KiB compositor screening now reports
156,122 generic cells / 40,178 sequential bits. This remains local-exec
bring-up, not protected memory/exec composition or hardware GLES2.

2026-09-22: memory plus exec was rejected, then the scheduler replaced
that reject. `run-th-exec.sh` rc=0: 64 cases / 518 checks / 3,071 clocks.
The exec-only job stream is unchanged. The earlier 4 KiB screen of that
exec-only fixture was disabled 355 cells / 28 flip-flops and enabled
156,263 cells / 40,180 flip-flops, no latches. `tb_g6lc_apu_sched` is
4 cases / 107 checks / 161 clocks, errors=0. A mapping insert and lookup
complete, a local LDI/HALT job peeks 10, and the same lookup still
returns the mapping. No DMA runs in that profile. Fixture synth, no
latches: Enable=0 is 10 ports and no cells; Enable=1 is 28,966 cells /
4,839 flip-flops. The CVA6 cookie was not re-run.

2026-09-22: an accepted exec op that is cancelled still completes.
`tb_g6lc_apu_exec_bind` is 5 cases / 26 checks / 45 clocks, errors=0.
The completion status is CANCELLED and stays stable until acknowledged.
A completion that has already finished stays OK across a later cancel.
With exec disabled, a run op is not ready. The mailbox records the same
cancel completion. `g6lc_apu_exec_bind_fixture` synth has no latches.
Disabled is ports only. Enabled is 25,829 cells / 4,006 flip-flops.

Rerun `tb_g6lc_apu_sched` and `run-th-exec.sh` through the remote proxy
after related RTL edits. Command DMA now rejects a stale epoch and an
unknown id without a read. Scatter-gather, the used ring, and shader
surface loads are still open. The CVA6 cookie was not re-run.
