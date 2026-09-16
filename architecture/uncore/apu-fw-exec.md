# APU firmware-bound native execution

**Domain:** graphics uncore · **Status:** default-off mailbox/local-exec prototype

`g6lc_apu_fw.sv` and `g6lc_apu_exec_bind.sv` expose native IMEM load,
RF poke/peek, RUN and DMEM peek through `ACTRL_MAIL_*` at control+`0x80`.
EGL/GLES remain in Mesa/client software. Mailbox access is private management,
not a replacement Linux graphics driver or a BIOS public rendering ABI.

## Current composition

`g6lc_apu_sys` selects the memory backend when resource/command/DMA/SG
configuration is active; native execution is selected only for
`ExecEn && !MemEn`. Enabling both does **not** combine them: memory wins and
exec is absent. `ApuHarness` keeps native execution and DMA off. No native
render job currently consumes a protected DRAM resource from the memory box.

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

1. Compose memory, immutable program storage and execution as independent
   clients beneath one protected scheduler. Unsupported combinations must
   reject explicitly until this path exists; do not silently select a subset.
2. Carry resource/context/epoch/tag/program identity and completion status
   end to end. `exec_bind` currently returns mostly zero metadata; that is
   insufficient to publish context-scoped fences or service health.
3. Only handle-resolved pinned mappings may reach native LSU/SG/used-ring work.
   The existing memory mailbox still accepts raw mapping structs; insertion
   into a table does not prove subsequent DMA used that table or retained a lease.
4. Define cancellation and disable handshakes. `exec_bind` currently drops to
   Idle on cancel and can present ready while disabled without accepting a job.
   Held completions, mailbox words and all program/resource leases must survive
   stalls until acknowledged or explicitly invalidated by a coordinated reset.
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

Rerun `APU_EXEC=1 APU_SYNTH=1` and `run-th-exec.sh` through the remote proxy
after related RTL edits. Add MemEn+ExecEn, cancel/disable, stale generation,
no-early-publication and cross-context negative tests for the combined path.
