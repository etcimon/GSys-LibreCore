# Disposition ledger — every kept increment

Companion to [`NEGATIVE.md`](NEGATIVE.md). Corpus: `I4b`…`I4cf` + `g1aa`…`g1mf`, tag **`g1-archive`**.

**Handoff then capabilities:** §1 rows are `core/fetch` combos ([`VALUES.md`](VALUES.md)). §2 stays
in **`smt_legacy` only** and must not be ported to fetch. After fetch hold matches slfix, g1\*
frontend **moves** to `core/smt_legacy/` — not a delete. Capability A/B starts **after** that.

Invariant ids: [`../firmware-boot-principles.md`](../firmware-boot-principles.md) §B.
Layers: [`SPEC.md`](SPEC.md) §0.

---

## 1. Subsumed — behaviour survives, expressed generically

| Increments | What they did | Subsumed by |
|---|---|---|
| `I4ab` | Per-hart realign leftover banking | **I4**; L1 leftover array indexed by `hart_i` (structural) |
| `I4ad` | Leftover completable only if low half is a legal RVI prefix | **I5**; L1 `lo_hw[1:0]==2'b11` guard |
| `I4ae`, `G1av`, `G1aw` | Complete only from the immediately-next window; keep otherwise | **I3**; L1 `is_next_win` |
| `I4aa` | Compressed followed by a straddling RVI must not be fused | **I2**; L1 cursor walk (no case split to get wrong) |
| `G1gx`, `G1ia`, `G1fu`, `G1bf`, `G1ed` | Mid-window start must decode from the halfword at that PC | **I2**; L1 explicit `start_pc_i` input |
| `I4z`, `I4bq`, `I4bs`, `I4bt` | Hold the exception-vector fetch until decode consumes it | **I9**; L4 priority-1 latch with bounded release |
| `I4y` | SMT restore must not outrank trap / eret / pc-commit | **I8**, **I10**; L4 priority table rows 1–5 |
| `I4u` | Bank the outgoing next-PC only on switch | **I10**; retained in `g6lc_smt_pc_bank` |
| `I4p` | Never bank a zero next-PC over a valid one | **I10**; retained |
| `I4br` | Do not switch threads mid-trap-entry | **I9**, **I23**; L4 masks priority 5 while the trap latch is held, *with a bound* |
| `I4t`, `I4v`, `I4ah`, `E2` | Do not *predict* to an unfetchable target | **I19**; moved to L4 priority 8 only. The *resolution* half is reverted (**I11**, red line) |
| `I4m` (RAS half) | An invalid/zero return-stack entry is not a Return prediction | **I19**, **I20**; retained in the predictor |
| `I4l`, `I4w`, `I4ag` | Execute-region PMA windows must match the actual text extent | correct config hygiene; retained in `g6lc64_smt2_config_pkg` |
| `G1az`, `G1cx`, `G1ej`, `G1bm` | If slot 0 cannot be queued, later slots must not be either | **I7**; L2 all-or-nothing acceptance |
| `G1be` | An older same-window instruction issues before a younger branch | **I6**; L3 oldest-PC-per-hart |
| `G1cy` | A leftover-complete instruction precedes younger decode | **I6**; L3 oldest-PC |
| `G1em`, `G1ev`, `G1ey`, `G1fh`, `G1ee` | A CSR/ALU write must precede a dependent branch | genuine RAW hazards → **normal RAW detection**, not queue-order policy. Fixed by extending the scoreboard/ID RAW check to writers still in decode; the opcode-specific and register-specific forms are deleted |
| `G1o`, `G1ae`, `G1ag`, `G1al`, `G1ai`, `G1an` | A store of a link/frame register must wait for its writer | same as above — genuine RAW against a writer not yet in the scoreboard; generalised to *any* register, not link/frame specifically |
| `unresolved_cf_q`, `unresolved_csr_q` | Per-hart barrier past an unresolved control transfer / CSR | **I13**, **I22**; retained in `g6lc_issue_barrier`, reduced to these two bits |
| `I4au` | Clear the CF barrier on commit; do not arm it on `flush_unissued` | **I13**; retained |
| same-cycle CSR pair | Dual-issue `csrrw mtvec` + probe CSR truncated `__sbi_expected_trap` (no `mret`) | **I13**; `stall_csr_older` in `g6lc_issue_barrier` (not fetch) |
| `G1ah` | A store that has forwarded may not be silently dropped | **I16**; retained in `store_buffer` |
| `G1ao` | Replay the last forward to a later same-address load | **I16**; retained (covers the store-queue→cache handoff) |
| `I4am`, `I4ar`, `I4cc` | Wide-AMO response/write-address paths only when actually retiring that AMO | ordinary ownership checks; retained |
| `I4o` | Diagnostic hang decode (test-bench only) | retained as TB instrumentation |
| `I4ba`, `I4bc` | Bounded switch delay while decode/queue drains | **I23**; retained *only because bounded*; bound moves to `cva6_cfg_t` |
| `iter-004` | Cancelled AMO must not wedge the AMO buffer | genuine; retained |
| `iter-005` | No pipeline flush after a load-reserved; store barrier until the paired store-conditional | genuine; retained |
| `iter-006` | Barrier past a CSR until it commits | retained (`unresolved_csr_q`) |
| `iter-011` | `FETCH_WIDTH` ≥ 64 when multi-issue and RVC | retained in `build_fetch_width`, **but** see RC1/RC2 — this is what created the 4-slot geometry the corpus then fought |

## 2. Frozen in `smt_legacy` — program-specific, must not enter B

| Increments | What they did | Why deleted |
|---|---|---|
| `G1kk`, `G1kl`, `G1kz`, `G1le`, `G1lf`, `G1lh`, `G1li`, `G1lq`, `G1lr`, `G1ls`, `G1lt`, `G1lu`, `G1lo`, `G1lp`, `G1lz`, `G1ln`, `G1md`, `G1me`, `G1mf`, `G1ma`, `G1mb`, `G1mc`, `G1ks`, `G1kt`, `G1ko`, `G1kq`, `G1kr`, `G1kw`, `G1kn`, `G1ky`, `G1lj`, `G1ll`, `G1lv`, `G1km` | Latch an aligned load's destination register and use it to synthesise an indirect-jump encoding at a sibling offset | Violates **I1**, **I2**. The instruction handed to decode is not the instruction in memory. RC3. |
| `G1ie`, `G1ir`, `G1id`, `G1ik`, `G1ih`, `G1hx`, `G1hy`, `G1hj`, `G1hk`, `G1jk`, `G1jy`, `G1jz`, `G1ka`, `G1kb`, `G1kc`, `G1kd`, `G1ke`, `G1kf`, `G1kg`, `G1kh`, `G1iq`, `G1ju`, `G1jv`, `G1jx`, `G1hl`, `G1hm`, `G1hz`, `G1ib`, `G1hh`, `G1hi`, `G1ha`, `G1hb`, `G1hc`, `G1fq`, `G1et`, `G1io`, `G1ip`, `G1gw`, `G1gy`, `G1hd`, `G1ij` | Stash / re-present / rewrite instruction slots from siblings, stashes and the registered cache line | Same. All are compensation for the wrong bytes arriving. RC3. |
| `G1iw`, `G1jj`, `G1jl`, `G1ki` | Smuggle a second cache half to the frontend through the fetch `user` field | `SPEC.md` §7 — the cache returns the requested window only |
| `G1dc`, `G1ds`, `G1dv`, `G1da`, `G1dp`, `G1ef`, `G1dn`, `G1dt`, `G1en`, `G1eg`, `G1ei`, `G1er`, `G1fs`, `G1fe`, `G1ff`, `G1fo`, `G1fp`, `G1fd`, `G1fi`, `G1fj`, `G1fl`, `G1ex`, `G1bc` | Queue head selection and hiding by opcode class / destination register | Violates **I6**. `SPEC.md` §4 restores program order at the source. |
| `G1y`, `G1aq`, `G1au`, `G1bl`, `G1bp`, `G1ca`, `G1cb`, `G1cp`, `G1cv`, `G1cr`, `G1ek`, `G1el`, `G1ep`, `G1ez`, `G1fa`, `G1ge`, `G1jm`, `G1ic`, `load00_vs_off16`, `load00_vs_lj` | Hold or reject a registered cache window based on what is unconsumed | Replaced by **I7** all-or-nothing acceptance + `expected_pc` match (`SPEC.md` §3) |
| `G1cq`, `G1hs`, `G1ht`, `G1jo`, `G1hv`, `G1hw`, `G1jq`, `G1jt`, `G1ix`, `G1jn`, `g6lc_lo_lo8_s2` | Spare specific kill signals | Unnecessary: a killed window is inert in L1 (`SPEC.md` §2.2) |
| `G1fu`…`G1gd` (+2 stepping), `G1gl`, `G1gm`, `G1ge` | Step the PC by an instruction rather than a window | Replaced by **I12** + `expected_pc` reporting (`SPEC.md` §5.1) |
| `G1bv`, `G1cc`, `G1cs`, `G1ct`, `G1cz`, `G1eq`, `G1ft`, `G1du`, `G1dx`, `G1gi`, `G1gh`, `g6lc_lj_hide`, `g6lc_leftover::skip_*` | Stash a branch target, mask slots, hide a leftover unconditional jump | All compensation for L1/L2 defects |
| `G1bj`, `G1cw`, `G1do`, `G1gs`, `G1hf`, `G1hg` | Reclassify control-flow type from re-derived bytes | Classification is computed once from the correct bytes (**I1**) |
| `g6lc_sb_keep::keep` exemption list (`I4n`, `I4ai`, `I4aj`, `I4al`, `I4aq`, `I4at`, `I4ap`, `I4ax`, `I4ay`, `I4bn`, `I4bu`, `I4bw`, `I4bx`, `I4cb`, `I4cd`, `I4cf`, `G1`, `G1b`–`G1g`) | Exempt instructions from squash by register / immediate form / functional unit | Violates **I13**. RC4 identifies the real defect. |
| `I4ao`, `I4as` | Drop committed register writes by result value | **ISA violation** — `firmware-boot-principles.md` §E |
| `G1s`, `G1an` (commit half) | Force register writes for *cancelled* instructions | **ISA violation** — violates **I15** |
| `I4by`, `G1k`, `G1h`, `G1gg` | Choose between a forwarded operand and the register file by inspecting the value | Violates **I17** |
| `I4ak`, `G1u`, `G1p`, `G1r`, `G1t`, `G1v`, `G1w`, `G1x`, `G1q`, `G1gp`, `G1gq` | Patch around shared execute-stage result/identity aliasing | Symptom of RC4. Replaced by structural fix: one fixed-latency claim per cycle, asserted; per-port result/identity pairing |
| `g6lc_rvc_enc::mash_*`, `expand_*` | Recover a mashed encoding | No such thing once **I1** holds |
| `I4bg`, `I4bi`, `I4bk`, `I4bl`, `I4bp` | Bank or rewind the thread PC around an immediate-write pattern | Program-specific; **I10** + `SPEC.md` §5 priority 5 |

## 3. Reverted before the revamp

See [`NEGATIVE.md`](NEGATIVE.md). Roughly 90 mechanism classes, ~45 of them `HOLD-FAIL`.

---

## 4. Accounting

| Category | Increments | Fate |
|---|---|---|
| Subsumed by an invariant | ~35 | behaviour survives generically |
| Deleted as program-specific | ~230 | removed with the layer they lived in |
| Reverted during the campaign | ~90 classes | already gone; recorded in `NEGATIVE.md` |
| ISA violations to revert | 6 sites | `firmware-boot-principles.md` §E |

The ratio — 35 durable rules extracted from ~380 increments — is the honest measure of the campaign.
The 35 are real and hard-won; they are now expressed once each instead of ~250 times.
