# Extension point: out-of-order execution (production path)

Program: `../router-core-upgrade-program.md` (U4 / U5).

**Status: production.** Full multi-issue OoO is a **shipping, config-gated** backend
(`OoOEn=1`). Minimal / default packages keep `OoOEn=0` for **netlist identity** with the
in-order dual-issue path — that is a product option, not an “experimental” quality label.

## Pipeline (OoOEn=1)

```
decode → scoreboard (in-order alloc + commit)
              │
              ▼
     g6lc_ooo_dispatch
        multi-port rename (g6lc_rename)  ── freelist 32+ pool
        precise free+busy+map ckpt on branch
        age-ordered IQ + same-cycle chain wakeup + multi-grant
        ROB multi-WB complete (by trans_id)
        LSQ multi-alloc + live AGU + CAM/STL + memdep
        PRF write-through + WB bypass → IRO operands
        mispredict: SB cancelled_mask → squash younger IQ/ROB/LSQ + gate PRF WB
              │
              ▼
     issue_read_operands  (PRF cutover when ooo_renamed)
              │
              ▼
            EX → WB → commit
```

**OoOEn=0:** identity (no dispatch module). **SliceOoOEn ⊕ OoOEn.**

## Bottleneck optimizations

| Bottleneck | Mitigation |
|------------|------------|
| Rename WAW/WAR multi-issue | Single-cycle multi-port rename; later ports see earlier allocs |
| Mispredict recovery | Precise map+free+busy checkpoint; **SB cancel mask** squashes younger IQ/ROB/LSQ; PRF WB gated |
| Wakeup latency | Busy-table clear on WB + IQ tag wakeup same cycle |
| Dependent ALU bubbles | Same-cycle IQ producer→consumer chain wakeup |
| PRF read latency | Write-through PRF + same-cycle **WB bypass** into issue operands |
| Issue width | IQ grants up to `NrIssuePorts` oldest-ready; mem_stall only blocks LD/ST |
| Mem dependence | Store-set predictor + LSQ CAM; stall only unknown/match-no-data |
| STL | Live AGU (`imm+rs1`) + store data at issue; youngest match forwards into load op A |
| LSQ capacity | Full `LsqLoad/StoreEntries` (no hard-8 cap); multi-port alloc |
| ROB complete | Multi-WB complete by scoreboard `trans_id` |
| Arch RAW stalls | IRO skips scoreboard RAW stall when `ooo_renamed` |
| Dual/multi commit free | Commit ports free old phys regs |
| Observability | PMU group 1 events 0–7 (rename/IQ/ROB/LSQ/STL); phys tags on `scoreboard_entry_t` |

## Modules (`core/ooo/`)

| File | Role |
|------|------|
| `g6lc_rename.sv` | Multi-port RAT + free pool + busy + full-state branch ckpt (any port) |
| `g6lc_iq.sv` | Compacting IQ, chain wakeup, multi-grant ready select + cancel squash |
| `g6lc_rob.sv` | ROB with multi-WB complete-by-tid + cancel complete |
| `g6lc_lsq.sv` | Multi-alloc LSQ + live addr CAM + STL + cancel drop |
| `g6lc_memdep.sv` | Store-set |
| `g6lc_prf.sv` | Multi-port PRF with write-through |
| `g6lc_ooo_dispatch.sv` | Glue + AGU + PRF operand outs + PMU probes |

`scoreboard_entry_t` carries `p_rs1/p_rs2/p_rd/ooo_renamed` (zero when off). RVFI/commit sees tags via the SBE.

## Packages (production profiles)

| Package | Role |
|---------|------|
| `g6lc64_ooo_server_config_pkg.sv` | **Server production**: 4-issue, 4c×2h, L2/L3 auto, `DeepSpecEn`, `MemDepPredEn` |
| `g6lc64_ooo_config_pkg.sv` | **Dual-issue production lite**: 2-issue OoO + DeepSpec (bring-up / area-lean) |
| Default `cv64a6_imafdc_sv39` etc. | `OoOEn=0` identity (still production in-order) |

ROB/IQ/LSQ/PRF depths 0 → scaled from issue width in `build_config_pkg`.

## Tests

| Suite | Path |
|-------|------|
| Directed list | `verif/tests/testlist_ooo_l3.yaml` |
| Regress | `verif/regress/ooo-l3-tests.{sh,ps1}` (`DV_TARGET=g6lc64_ooo_server`) |
| ILP / rename | `verif/tests/custom/ooo/ooo_ilp_chain.S` |
| Memdep / STL | `verif/tests/custom/ooo/ooo_mem_dep.S` |
| L2/L3 stream | `verif/tests/custom/l3/l3_stride_stream.S` |

`build-platform` suite id: **`ooo-l3-tests` (optional / lengthy)** — not in
default `verify.targets` or `defaultSuites` (runtime cost, not maturity).

```
cva6-build test --suite ooo-l3-tests
cva6-build verify --target g6lc64_ooo_server
cva6-build verify --target g6lc64_ooo
```

## PMU group 1 (`mhpmevent[7:5]==1`)

| Idx | Event |
|-----|-------|
| 0 | SB full \| rename stall \| ROB full |
| 1 | Issue stall \| IQ full |
| 2 | Branch mispredict |
| 3 | Load commit |
| 4 | Store commit |
| 5 | LSQ / memdep / STL stall |
| 6 | STL forward hit |
| 7 | Rename/freelist stall alone |

## Formal (optional CI)

| Artifact | Role |
|----------|------|
| `core/ooo/formal/g6lc_ooo_freelist_props.sv` | freelist/busy mutex + index bounds |
| `core/ooo/formal/g6lc_ooo_rob_props.sv` | ROB count/head/tail bounds |

## Related

- Recovery ordering: [`recovery-timeline.md`](recovery-timeline.md)
- FSE depth plane: `architecture/speculative-execution/` (`DeepSpecEn`, STQ, PMU g3)
- Slice MLP (U4): still off by default; mutually exclusive with U5

## Remaining hardening (production backlog, not “experimental”)

1. Associative IQ / FU-class split queues when area allows  
2. ~~Expand formal to live freelist / ROB / multi-port rename~~ **done** (`core/ooo/formal/`)  
3. Inclusive L3 back-inval polish  
4. Optional default-on for selected server board packages only  

## Status

**Production path live behind `OoOEn`.**  
`OoOEn=0` remains the identity default for small targets; **`OoOEn=1` is the production OoO backend**, not a scaffold.
