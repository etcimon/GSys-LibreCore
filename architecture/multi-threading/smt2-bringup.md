# SMT2 bring-up notes (U6.1 follow-on)

Profile: `core/include/g6lc64_smt2_config_pkg.sv` (`NrHarts=2`, `SMT_HYBRID`).

## Software view

| Item | Value |
|------|--------|
| `mhartid` thread *h* | `hart_id_base + h` (base from SoC pin) |
| ISA | Same string both threads; SBI/OpenSBI treat as two harts |
| CLINT | Two MSIP/MTIMECMP slots if `NR_CORES`/`NR_HARTS` covers SMT |
| Linux | Two `cpu@` nodes with consecutive hartids; enable only after OpenSBI knows both |

## What the RTL guarantees

1. **Per-hart arch state:** RF banks, CSR banks, PC bank, RAS banks, GHR banks  
2. **Fine-grain switch:** IF flush + unissued drop; EX/scoreboard drain; BP preserved  
3. **Commit isolation:** CSR write path keyed by `commit_instr.hart_id`  
4. **Fetch view:** Privilege/MMU CSRs muxed by active fetch hart  

## Recommended bring-up sequence

1. Lint/synth with default `NrHarts=1` (identity) — always green  
2. Select `g6lc64_smt2_config_pkg` for sim; boot bare-metal on hart 0 only  
3. Park hart 1 in WFI (`wfi` loop at reset vector +1 page or secondary entry)  
4. Exercise switch-on-miss: force D$ misses on hart 0, confirm peer fetch  
5. Dual-thread `rdcycle` / store-buffer litmus before Linux  
6. OpenSBI: set `expected_harts` / domain for two harts  
7. Linux: `maxcpus=2` smoke  

## Dual-hart Linux / CI sketch

**DTS of record:** `corev_apu/bootrom/ariane-smt2.dts`  
**Validate against Linux tree:** see `dts-linux-smt.md` (fetch + `validate-cva6-dts.ps1`).

```
# 0) .\build-platform\scripts\fetch-linux-dts.ps1
#    .\build-platform\scripts\validate-cva6-dts.ps1
# 1) dtc -I dts -O dtb -o ariane-smt2.dtb corev_apu/bootrom/ariane-smt2.dts
# 2) OpenSBI: expected_harts = NrCores × NrHarts, embed DTB
# 3) Boot Linux maxcpus=2 earlycon=… root=…
# 4) cat /proc/cpuinfo ; taskset -c 0,1 stress-ng --cpu 2
```

**RTL path (landed):** CLINT `NR_HARTS=NrCores×NrHarts`, per-bank timer/IPI/PLIC into CSR
banks, `mhartid=base+h`, decode `irq_active=irq_i[smt_active_hart]`.  
**Gates:**
- R0 DTS/RTL: `verif/regress/smt-linux-boot-path.{ps1,sh}` (`smt-linux-boot-path`)
- R1–R3 rootfs track: `verif/regress/smt-linux-rootfs.{ps1,sh}` (`smt-linux-rootfs`)
  — dual-park directed + preflight; set `CVA6_LINUX_PAYLOAD` for full image sim  
  — plan: `architecture/multi-threading/smt-linux-rootfs.md`

CI job (optional, not default verify):

| Stage | Command / note |
|-------|----------------|
| Lint | `g6lc64_smt2` or `g6lc64_ooo_server` (NrHarts=2) |
| Bare-metal | `smt_dual_park.S` (hart1 WFI; hart0 self-check) |
| SBI | OpenSBI domain with 2 harts |
| Linux | boot to prompt; `cat /proc/cpuinfo` shows 2 (`CVA6_LINUX_PAYLOAD` / cva6-sdk) |

Combine with **H** (`server_math`) only after SMT bare-metal is green — KVM-on-SMT is out of scope for bring-up.

## Known limits

- BHT/BTB tables are **shared** (only RAS + GHR banked) — mild cross-hart BP pollution  
- Dual-commit of two different harts in the same cycle is not specialized (single CSR port)  
- Full KVM-on-SMT not a bring-up target; use H package separately  

## Debug tips

- RVFI: `mhartid` differs per bank; trace `smt_active_hart` / `smt_switch`  
- If hang: check both CSRs not in permanent WFI with no peer IRQ  
- Mispredict after switch should only zero the **active** RAS/GHR bank

## Dual-hart bare-metal Variane (live residual)

Linux Verilator **5.008** builds `work-ver-smt2`
(`make verilate target=g6lc64_smt2 ver-library=work-ver-smt2`).

**Fix (core):** SMT thread select holds switches until the primary has committed
outside the boot ROM page and for a short DRAM grace (`SMT_DRAM_GRACE` in
`core/cva6.sv`). Mid-bootrom / early-DRAM switches were PC-bank restoring past
bootrom `jr s0` into zeros (`ILLEGAL_INSTR` @ 0x10020).

**Green:** bare `mini_tohost` + `smt_dual_park` on `work-ver-smt2`; Spike dual-park;
`DUAL_HART_LIVE=1 DUAL_HART_LIVE_HARD=1 bash verif/regress/dual-hart-ci.sh`.

**Peer post-grace green:** `smt_peer_tohost` (hart1 tohost PASS after primary
WFI) on `work-ver-smt2` after: delayed switch pulse, ready≠sticky-miss, miss-switch
blackout, longer `SmtFetchQuantum`, bootrom all-harts→DRAM (no mhartid WFI park).

**Hard dual-active gate:** `smt_peer_tohost` (primary WFI yield → peer tohost).

**RTL isolation landed:** commit RF writes banked by `commit_instr.hart_id` (was stuck
at hart 0); RAW hazards hart-qualified in `raw_checker` (no cross-hart forward/stall).

**Still open:** concurrent `smt_dual_active` (peer tohost while primary stays ready —
no WFI). Live still times out with primary FAIL before peer scores; Spike `-p2` OK.
Also open: dual-WFI without IPI; OpenSBI dual-hart + Linux R3 Image lab.

**Hold policy (`cva6.sv`):** primary DRAM grace + hold while active NPC is in bootrom
(unless active is WFI/halted — escape so a peer can run).

