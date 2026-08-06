# AMOCAS.Q microarchitecture plan (Zacas on CVA6V-EC)

**Status:** **functional** on g6lc64_server_math Variane (P4 green). Q no longer deferred-illegal.  
**Spec:** Vol I §5.9 `#ext:zacas` · `agents/spec/riscv-spec-I-5.9-zacas.html`.  
**Baseline:** AMOCAS.W/D already gated by `CVA6Cfg.RVZacas`.

### Progress (bring-up)

| Item | State |
|------|--------|
| Decode `AMO_CASQ` + odd-rd/rs2 illegal | **done** (`decoder.sv`) |
| `amo_req_t`/`resp_t` `is_quad` + hi halves + `dual_we` | **done** (`ariane_pkg.sv`) |
| Issue 2-phase pair RF gather | **done** (stall until `casq_ready_q`) |
| LSU/store/amo_buffer 128b sideband | **done** |
| HPDCache multi-beat CASQ FSM | **done** (`CASD_LD_HI`/`ST_HI`) |
| Commit dual-write (`NrCommitPorts` 1 and ≥2) | **done** (single-port sticky hi) |
| `mini_amocas_q_illegal` | **PASS** |
| `mini_amocas_w` / `_d` | **PASS** |
| `mini_amocas_q` functional | **PASS** (`zacas-policy` hard golden) |

## 1. ISA requirements (RV64)

| Item | Rule |
|------|------|
| Encoding | AMO opcode, `funct5=00101`, **`funct3=100`** (quadword) |
| Operands | **Register pairs**: if `rd≠x0`, `rd` and `rd+1` are sources (expected) and destinations (old); if `rs2≠x0`, `rs2` and `rs2+1` are sources (new) |
| Pairing | `rd` and `rs2` must be **even** (illegal-instruction if odd) |
| Address | **16-byte aligned** (else misaligned fault) |
| Semantics | Atomic load 128b, compare to `{rd+1,rd}`, if equal store `{rs2+1,rs2}`, write old to `{rd+1,rd}` |

## 2. Why W/D alone were not enough

| Width | Expected / new | Result | Memory path today |
|-------|----------------|--------|-------------------|
| W | 1×32 in `rd` / `rs2` | 1×32 → `rd` | HPDCache AMO / AXI AtomicCompare pack |
| D | 1×64 in `rd` / `rs2` | 1×64 → `rd` | Local UC RMW FSM (`CASD_*` / WT `AMO_CAS_*`) |
| Q | **2×64 pairs** | **2×64 dual write** | Needs 128b RMW + 5th-ish RF sources + dual WB |

Constraints in current RTL:

- `OPERANDS_PER_INSTR == 3` when Zacas (rs1, rs2, rd) — not 5.
- `amo_req_t` / `amo_resp_t` carry single 64b data/result.
- Commit AMO path writes **one** GPR; dual-commit is disabled during AMO.

## 3. Target microarchitecture

```
 decode AMO_CASQ (even rd/rs2, 16B align)
    → issue: 2-phase RF gather
         phase0: rs1=addr, rs2=new_lo, rd=exp_lo
         phase1:         rs2+1=new_hi, rd+1=exp_hi  (stall issue)
    → LSU/store_unit: size=quad, operand_b/c + hi
    → amo_buffer: extended payload
    → cache: CASQ local RMW (two UC dword LD/ST + line inval), single amo_pending window
    → commit: dual write lo→rd, hi→rd+1 (port1 if present; else 2-cycle pending hi write)
```

### 3.1 Decode (`core/decoder.sv`)

- `funct3==3'h4` && `RVZacas` && `IS_XLEN64` → `AMO_CASQ`.
- If `rd[0]` or `rs2[0]` set → **illegal**.
- `imm_select = MUX_RD_RS3` (expected base in `result`/`rd` as W/D).

### 3.2 Issue RF pair gather (`issue_read_operands.sv`)

- Detect `AMO_CASQ`; force one-cycle stall to capture hi halves.
- Latches: `casq_new_hi`, `casq_exp_hi` (and lo from normal operands).
- Forward into `fu_data` via extended fields or reuse `imm`/sideband into LSU.

**Preferred sideband:** extend `fu_data_t` / LSU ctrl with `data_hi` / `data_cmp_hi` when `RVZacas` (parameter-gated).

### 3.3 `amo_req_t` / `amo_resp_t` / buffer

```systemverilog
// additive fields (default 0 when not Q)
logic [63:0] operand_b_hi;  // new high
logic [63:0] operand_c_hi;  // expected high
logic        is_quad;
// resp:
logic [63:0] result_hi;
logic        dual_we;
```

### 3.4 Cache RMW

Extend HPDCache adapter CASD FSM → **CASQ** (or shared multi-beat CAS):

1. UC load `[addr+0]`
2. UC load `[addr+8]`
3. Compare 128b to `{c_hi,c_lo}`
4. If match: UC store new_lo, UC store new_hi
5. CMO inval covering 16B
6. `ack` + `{result_hi,result_lo}=old`

Same pattern in `wt_dcache_missunit` for WT packages.

Atomicity: exclusive AMO port + `amo_pending` already serializes; no intervening core mem ops on that channel.

### 3.5 Commit dual write

| `NrCommitPorts` | Mechanism |
|-----------------|-----------|
| ≥2 | Same-cycle: port0 ← rd/lo, port1 ← rd+1/hi (override AMO dual-commit block for CASQ only) |
| 1 | Two-phase: cycle0 write lo + hold commit; cycle1 write hi then `commit_ack`+flush |

## 4. Implementation phases

| Phase | Deliverable | Gate |
|-------|-------------|------|
| **P0** | This plan + type/decode skeleton | decode Q not always illegal |
| **P1** | amo_* 128b + CASQ RMW (HPDCache + WT) | unit-level / mini |
| **P2** | Pair RF gather + LSU wire | issue path |
| **P3** | Dual WB | functional Q |
| **P4** | `mini_amocas_q.S` hard green; update `zacas-policy` | **Q no longer “deferred illegal”** |

Spike still **not** a Zacas golden.

## 5. Config / DTS

- Remain behind `RVZacas` (no separate bit unless area forces `RVZacasQ`).
- DTS `zacas` already advertised on Zacas packages; Q is part of Zacas when implemented.
- PMA: memory must support AMOCASQ-level atomics (spec); sim DRAM is fine.

## 6. Risks

- Timing: multi-beat RMW latency on critical AMO path (already multi-cycle for D).
- OoO/scoreboard: ensure CASQ not partially observed; commit flush after AMO retained.
- SMT: pair reads must use active hart RF bank (existing SMT regfile).
- Verification: alignment faults, odd-reg illegal, mismatch path, success path, overlap with cache.

## 7. References

- RTL W/D: `decoder.sv`, `amo_alu.sv`, `cva6_hpdcache_if_adapter.sv` (`CASD_*`), `wt_dcache_missunit.sv`
- Policy: `software/zacas/README.md`
- Tests: `mini_amocas_{w,d,q*}.S`, `zacas-policy.sh`, `mc-mini-veri.sh`
