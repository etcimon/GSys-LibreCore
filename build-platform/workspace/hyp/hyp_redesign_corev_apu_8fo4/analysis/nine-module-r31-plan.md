# r31–r39 — consecutive single-module tasks (methodology of r20–r30)

Implementation record: [nine-module-r31-r39.md](nine-module-r31-r39.md).
All nine reduction tasks are implemented and their focused gates collected.
The final caller gate also repairs island AXI response ownership: the small
and default 512-lane configurations pass with invalidation enabled. Aggregate
core verification remains failed/unqualified as detailed in the record.
The final designs below evolved through measurement: r33 uses bank-local seed
capture rather than retiming store reads; r34 uses carry-save reduction; r36
factors normalization without another stage; r38 retains the package encoder
with parallel comparison and separate publication fields. See the record for
countercases and the generated-level measurement limitation.

Each task: execution-path analysis from the frozen r20 analyzer IR, transform
chosen from ALGORITHMS-EXPERTS (A20 parallel schedule, A33 relocation tiers,
A104 one-hot/masked-OR, A134 prepared facts, A140 explicit arithmetic depth)
and the landed program patterns (ownership tokens, registered facts, wired
rows + carry-save, interleaved stages), implemented, lint + its bench, board
remeasured, recorded with countercases. Order follows the r30 ranking.

| Task | Module | Max | Owner path (r30 IR) | Mechanism | Gate |
|---|---|---:|---|---|---|
| r31 | `g6lc_ai_pe_dot_float_pipe` | 50.77 | S1: `fp_dot_decode_value(a/b)` (12.5 each) then `fp_dot_product` into `s1_prod_d` (27.1 bundle) | decode stage S1a ahead of the product (the R8 form, `LATENCY = LEVELS+5`, `DOT_LATENCY` +1 in gemm_seq, int pipe O2 restored); gate the float leaf on system Verilator 5.020 and gemm-backend DPF=1/2 (the r13 float build failure was the script's 5.008 fork binary) | gemm-backend DPF=1,2 remote + float/int pipe leaves |
| r32 | `g6lc_ai_policy_subcode` | 49.74 | `better` (25.8) → `choose` (16.0) → winner selects | register `better_q` one state ahead (COMPARE split); prepared `m/n_align_ok[0..4]`; literal gain/row-bytes tables; per-register clamps | policy pipeline bench |
| r33 | `g6lc_ai_gemm_seq` | 48.70 | accumulate-mode seed read: read-stage facts → bank select → latency-0 C read → `mac_seed_q` | C bank at `ReadLatency 1` with the seed capture and store W fetch retimed one cycle (fetch cursor already independent of retirement) | 15-case remote GEMM + wide |
| r34 | `g6lc_ai_pe_dot_float` | 47.14 | combinational float dot (DPF=0 ablation arm) | same decode/product split as r31 inside the comb cell, or retire the comb arm in favour of the pipe (default DotPipeFloat=1 in the hyp tree) | gemm-backend DPF=0 |
| r35 | `g6lc_ai_inval_queue` | 46.54 | `aw_last_byte` add → `tail_same` → `aw_hold_o` (same-cycle DMA AW backpressure) | two-entry in-order AW skid: `hold = skid_full` (registered), line arithmetic one cycle later, B-side counts include skid entries | inval-queue bench + island DMA |
| r36 | `g6lc_ai_gemm_fp32_norm` | 46.25 | `finite_result` masked OR (10) after `diff_yx` (9.3) and `magnitude` select; `subnormal_fraction` variable shift (5.7) | leading detect as a prefix tree beside the adders; subnormal shift amount from `ec` precomputed in align (A33 T1 relocation into stage 1); candidate masks narrowed | FP32 100k miter ×2 (in the GEMM runs) |
| r37 | `g6lc_ai_pe_dot` | 45.80 | `while` fold `node[i] = node[2i] + node[2i+1]` levels | explicit generate levels (A140) with 32-bit→width-growing adders, odd-tail promotion kept | gemm-backend DPF=0 |
| r38 | `g6lc_ai_policy_codec` | 39.40 | `candidate = evaluate ? policy_encode(f1) : state.candidate` (11) chain | one-hot class bits × constant codes for `policy_encode`; per-register warm/prediction processes | policy pipeline bench |
| r39 | `g6lc_ai_desc_engine` | 39.00 | span capture arms (degenerate selects + saturating 64-bit add) | arms as parallel assigns with one-hot select (A104); ST_GEMM bundle per family (P6) | island DMA bench |

Standing rules carried from r20–r30: snapshot before edit, frozen analyzer
for matched numbers, bit-exact identities with translate_off assertions,
record countercases (one-hot shift forms and operand casts measured worse;
only structural splits move atomic operators), never promote module maxima
to connected arrivals or STA. 8-FO4 closure is not claimed by any task.


## Follow-up: r40/r41

Subcode and GEMM reductions (SHAPE + ranked choose; bounded receive
arithmetic + indexed C-bank mux) — see `subcode-gemm-r40-r41-plan.md`
and `subcode-gemm-r40-r41-results.json`; measurements here remain the
r31–r39 frozen record.
