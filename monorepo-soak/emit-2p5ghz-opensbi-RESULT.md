# Emit 2.5GHz OpenSBI multi-core boot result (2026-08-04)

## Setup
- Target: cv64a6_server_math NrCores=2, dual-issue + SpeculativeSb, full_core 2.5GHz emit overlay
- Harness: work-ver/Variane_testharness (built 13:37 with emit-overlay-cv64a6_server_math-full_core.f)
- Payload: build-platform/workspace/smt2-linux/fw_payload.elf +tohost_addr=0x80041730
- Timeout: +time_out=20000000 (avoids known 5M premature timeout; historical SUCCESS ~6.5M)

## Results
| Test | Result | Cycles | Notes |
|------|--------|--------|-------|
| mini_tohost (+tohost_addr=0x80001000) | SUCCESS | 359 | Emit harness functional |
| OpenSBI fw_payload 20M | FAILED (timeout) | 20000013 | tohost=2147483647; wall ~26.2 min |
| OpenSBI MC_PC_PROBE 100k | hang | 100013 | stuck from cycle ~500 |

## Not the 5M pitfall
Even with 20M (3x historical 6.5M SUCCESS budget), boot never completes. MC_PC_PROBE shows a **memory/I$ hang** long before OpenSBI could signal tohost:

```
@100   c0.npc=0x10020  c1.npc=0x10020   (bootrom)
@500   c0.npc=0x80000084 c0.iq_pc=0x80000068  c1.npc=0x10050
       ic0=3 pend0=1 l2st=4 l2a=0x80000080 ar_ot=1 ar0=0 ar1=0
@2k..20k  same frozen state
```

Core0 reached DRAM OpenSBI but is stuck on I$ miss for 0x80000080; L2 shows outstanding addr, ar_ot=1, but AXI AR valids are 0 (request appears stranded in hub/L2 path). Core1 remains in bootrom at 0x10050.

## Logs
- monorepo-soak/emit-2p5ghz-opensbi-mc-20260804-133937.log
- monorepo-soak/emit-opensbi-mc-pc-probe.log
