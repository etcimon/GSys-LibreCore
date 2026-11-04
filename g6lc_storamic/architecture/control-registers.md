# Control registers, health, interrupts and map publication: ST-010 design

This document specifies the standalone AXI-Lite control block, which is
`ctrl_req_i`/`ctrl_resp_o` on `g6lc_storamic_top`. Until now that port only
refused. The register layout belongs to standalone contract version 4.
ST-010C gives it a native window and IRQ through the existing map owner,
`corev_apu/tb/ariane_soc_pkg.sv` (see "Native aperture" below). It is not yet
a Linux driver ABI: no driver exists and the DTS fragment ships disabled.

## Access rules

- The window is 4 KiB and holds 32-bit registers. Accesses must be naturally
  aligned 32-bit words. AXI-Lite carries no burst, only `prot`.
- A read of an unmapped offset returns `SLVERR` with data 0. A write to an
  unmapped or read-only offset returns `SLVERR` and changes nothing.
- Writes honour `wstrb` per byte. A W1C register clears only the bits set in
  bytes whose strobe is enabled.
- One read and one write are accepted independently. Responses are held stable
  until ready, as in the data frontend.
- AXI-Lite writes do **not** order data traffic. Software must use the drain
  token, described below.

## Register map

| Offset | Name | Access | Content |
| --- | --- | --- | --- |
| 0x000 | `ID` | RO | `0x5354_524D` |
| 0x004 | `VERSION` | RO | `[15:0]` contract version, which is 4 |
| 0x008 | `CONFIG` | RO | `[1:0]` profile, `[7:4]` MaxSticks, `[12:8]` region capacity (Regions), `[23:16]` log2 data bytes |
| 0x00C | `STATUS` | RO | `[0]` service_ready, `[1]` model_ready, `[2]` map_committed, `[3]` sequence_exhausted, `[4]` drain_pending |
| 0x010 | `CAPS` | RO | `ImplementedMediaCaps`, currently 0 |
| 0x014 | `FAULTS` | W1C | sticky: `[2:0]` frontend faults, `[3]` stray completion, `[4]` discovery fault event, `[5]` map commit error |
| 0x018 | `IRQ_ENABLE` | RW | same bit positions as `IRQ_PENDING` |
| 0x01C | `IRQ_PENDING` | W1C | `[0]` any `FAULTS` bit set, `[1]` slot ready change, `[2]` map commit done, `[3]` drain done |
| 0x020 | `MAP_CTRL` | RW/RO | write `[0]=1` to request a commit; RO `[1]` busy, `[2]` committed, `[12:8]` last `map_status_t` |
| 0x024 | `DRAIN_TOKEN` | RW | write a token, then read back the last written token |
| 0x028 | `DRAIN_DONE` | RO | last token whose drain completed |
| 0x02C | `COUNT_ACCEPT` | RO | AW+AR handshakes, including requests later refused (wrapping) |
| 0x030 | `COUNT_REFUSE` | RO | AW+AR refusals, a subset of accepts (wrapping) |
| 0x034 | `COUNT_COMPLETE` | RO | B handshakes + R handshakes with RLAST, i.e. transactions (wrapping) |
| 0x038 | `COUNT_ERROR` | RO | completed transactions with SLVERR (wrapping; an R burst counts once if any beat erred) |
| 0x100 + 0x20·s | `SLOT[s]` | | per slot `s < MaxSticks` |
| +0x00 | `STATE` | RO | `[3:0]` discovery state, `[11:8]` fault code, `[16]` dup |
| +0x04 | `IDENTITY` | RO | published identity, or 0 |
| +0x08/0x0C | `RAM_LO/HI` | RO | published RAM bytes |
| +0x10/0x14 | `RSV_LO/HI` | RO | published reserved bytes |
| +0x18 | `CTRL` | WO-pulse | `[0]` quiesce request, `[1]` fault clear |
| 0x400 + 0x20·i | `REGION[i]` | RW | staged entry `i < Regions`; writable only while not committed and not busy |
| +0x00/0x04 | `BASE_LO/HI` | RW | |
| +0x08/0x0C | `BYTES_LO/HI` | RW | |
| +0x10/0x14 | `OFFSET_LO/HI` | RW | |
| +0x18 | `SLOT_ID` | RW | `[7:0]` slot index |
| +0x1C | `ATTR` | RW | `[0]` valid, `[1]` read, `[2]` write, `[31:8]` reserved, which must be 0 (writing a nonzero value returns SLVERR) |

The region entry stores the expected slot identity implicitly. At commit time,
the identity of the slot published by discovery is captured into the committed
map, so a later stick change cannot silently inherit the mapping.

Offsets that the configuration does not populate (`s >= MaxSticks`,
`i >= Regions`) are unmapped.

## Map commit

A commit request is accepted only while uncommitted and idle. The block then
runs a **sequential validator**. It is bounded by the number of
`Regions + Regions*(Regions-1)/2` steps, and it uses the same rules and status
codes as `g6lc_storamic_region_pkg::map_check`. It checks the staged table
against the discovery `slot_map` snapshot taken when the request was accepted,
using `word_bytes` = the data bus bytes. `n_regions` is the count of leading
entries whose valid bit is set; an empty table is `MapRegionCount`.

- **On `MapOk`** the staged table and snapshot are copied into the committed
  map that drives the frontend. `MAP_CTRL.committed` is set, and the commit-done
  interrupt is raised.
- **On failure** the status is recorded, `FAULTS[5]` and the done interrupt are
  set, and nothing is committed.

A committed map is immutable until reset (ST-010 grants no live remap or
compaction). Until a map is committed, the mapped frontend refuses every
request (`mem_ready`/coverage both fail). The frontend's map therefore becomes
a runtime input (`map_valid_i`, `slot_map_i`, `region_map_i`). The
elaboration-time parameter remains as an optional boot-time default: when
`BootMapEn` is set, the parameter map is validated at elaboration and committed
at reset, which keeps the ST-008 benches unchanged.

The validator must be sequential so that no Regions² comparator array sits on
a single cycle. The register block owns it; the frontend never does validation
over its whole table.

## Drain token

A write to `DRAIN_TOKEN` latches the token and sets `drain_pending`. The block
keeps a **snapshot of the frontend's monotonic accept count** (`COUNT_ACCEPT`,
widened internally to 33 bits) taken at the write. It completes the drain when
the retirement count reaches that snapshot and no command is in flight. Then
`DRAIN_DONE` takes the token value and the drain-done interrupt is raised.

The guarantee is: every AXI data transaction accepted before the token write's
B response has completed before `DRAIN_DONE` equals the token. It does not
order flushes to media, because there is no persistence.

## Interrupt

`irq_o` = `|(IRQ_PENDING & IRQ_ENABLE)`. It is a level signal, registered, and
deasserts in the cycle after the last enabled pending bit is cleared. Events
set pending bits even while disabled. An event in the same cycle as a W1C clear
of the same bit leaves the bit set, because the event wins.

ST-010A note: until ST-010B, `MAP_CTRL` reads `committed=1` with status `MapOk`
in the mapped profile, because the boot map is an elaboration-time parameter.
In the other profiles it reads 0. A commit request returns SLVERR, and the
`REGION[]` window is unmapped. Discovery inputs at the top are tied to "absent"
until ST-014 adds a pad binding. The bench drives the register block's
discovery view directly.

## Delivery

- **ST-010A: register block.** `g6lc_storamic_regs.sv` with the map above,
  counters and drain token, and the discovery view and controls (with the
  ST-009 slot set). It is integrated into the top for all profiles: the refuse
  and off profiles expose only ID/VERSION/CONFIG/STATUS/CAPS, and every other
  offset returns SLVERR.
  - Bench checks: decode, strobes, RO/W1C, a simultaneous event and clear, IRQ
    level and deassertion, reset, unmapped and misaligned errors.
  - Gates: a negative oracle, synthesis and formal safety (response stability,
    and no write effect on RO/unmapped offsets).
- **ST-010B: runtime map.** The staged table, the sequential commit validator,
  and the frontend runtime map inputs.
  - Bench checks: commits accepted and rejected for each status code (compared
    with the package `map_check` *and* hand values), immutability after commit,
    refusal before commit, and identities captured at commit.
  - Gates: the existing mapped benches still pass with `BootMapEn`.
- **ST-010C (native, with ST-011B): SoC integration.** Allocate the SoC
  aperture and IRQ in `ariane_soc_pkg`, and keep the DTS, config and register
  views consistent.

## Native aperture (ST-010C)

The control window is mapped at `0x5000_0000` (`ariane_soc_pkg::StoramicBase`),
length `0x10_0000` (1 MiB). Offsets `0x0000..0x0FFF` are the AXI-Lite register
block above; `0x1000..0xF_FFFF` are reserved for future per-stick virtio-blk
MMIO apertures and currently answer `DECERR` with no AXI-Lite traffic. The
block sources PLIC interrupt **10** (`irq_sources[9]`).

`g6lc_storamic_ctrl_bridge` converts AXI4 to AXI-Lite on that window. An
access is legal only when `len==0`, `size<=2` and `atop==0` inside the 4 KiB
control page; any other shape is `SLVERR` after the W beats are drained
(writes) or `len+1` error beats are returned (reads). The 32-bit AXI-Lite
word is selected from the 64-bit AXI beat by `addr[2]`; reads replicate the
register value into both halves of `r_data`. IDs echo, exclusive accesses
never return `EXOKAY`, and one read plus one write may be outstanding
independently. The opt-in DTS fragment is
`corev_apu/bootrom/g6lc-storamic.dtsi`.
