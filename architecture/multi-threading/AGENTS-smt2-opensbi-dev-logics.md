# SMT2 × OpenSBI development logics — heuristic planning pseudo-code

**Status: planning aid, not law and not evidence.** The normative documents are
[`../firmware-boot-principles.md`](../firmware-boot-principles.md) (capabilities R1–R12,
invariants I1–I28), [`../core-fetch/SPEC.md`](../core-fetch/SPEC.md) (what `core/fetch_B` must be),
[`../core-fetch/VALUES.md`](../core-fetch/VALUES.md) (which combo owns a value),
[`../core-fetch/NEGATIVE.md`](../core-fetch/NEGATIVE.md) (what has already failed), and
[`soft-ladder/README.md`](soft-ladder/README.md) (P0–P6, I1–I6). Evidence comes only from
[`testharness-proxy.md`](testharness-proxy.md).

**Grounded in** [`AGENTS-SMT2-opensbi-reasoning-pattern-workflow.md`](AGENTS-SMT2-opensbi-reasoning-pattern-workflow.md)
— the philosophy layer (propositions P1–P7, thought patterns T1–T10, the feedback-latency ladder)
that explains *why* the procedure below has the shape it has. Read that first if you need to
re-derive a rule rather than apply one.

**Generalized by** [`../AGENTS-g6lc-opensbi-dev-heuristics.md`](../AGENTS-g6lc-opensbi-dev-heuristics.md) — the
workload-agnostic form of this loop (seven weighted heuristics), which replaces the
propose→prune→soak search below with derive→prove→gate wherever the behaviour is a pure function.
Read this file for the SMT2 instance; read that one when planning how to *stop* needing peel, soak
and hold.

This file is the **missing middle**: the *inference procedure* that turns "OpenSBI does X here"
into "therefore the RTL must guarantee Y, therefore the candidate SystemVerilog change is Z on
combo C, and here is why Z is not one of the 314 things that already failed." It is written as
Python-shaped pseudo-code with deliberately verbal predicate names, because the value is in the
**wording of the inference**, not in an executable. Nothing here compiles, nothing here is a gate.

> **Honest caveat, stated once.** The priors in §10 were fitted on **one** firmware image
> (OpenSBI v1.5 `fw_payload`) on **one** configuration (`g6lc64_smt2`, `N=1 T=2 I=2 FW=64`).
> They are decision aids for ordering experiments, not measurements of the design. A prior that
> disagrees with a proxy log loses.

**Firmware of record for every line/offset cited below:** OpenSBI **v1.5**, commit
`455de672dd7c2aa1992df54dfb08dc11abbc1b1a` (2024-06-30), fetched by
`software/smt2-linux/scripts/fetch-opensbi.sh` into `$OUT/opensbi`
(`build-platform/workspace/smt2-linux/opensbi`, gitignored). Line numbers below are that tree.
Re-pin them if `fetch-opensbi.sh` moves.

---

## 0. The inference chain

Every increment in the soft-ladder history is, in retrospect, one traversal of this chain. Most of
the ~380 that failed did so by **skipping a link** — usually link 2 (naming an architectural
obligation) or link 5 (pruning against prior negatives).

```text
  1  OpenSBI source locus            "fdt_ro_probe_ assembles a BE u32 with lbu"
  2  architectural obligation        "mixed RVC/RVI at every 2-byte alignment"   (R4)
  3  invariant                       I3 / I5  leftover completes only from the next window
  4  owning combo / home             L1 align_slots   (or: not fetch at all)
  5  candidate class, pruned         one generic rule, config-gated, SI-identical
  6  mini with fail-codes            reproduce the class without the firmware
  7  soak verdict                    hold cookie -> nat -> peel
  8  retire a soft / add a capability
```

Direction matters. **Never** run the chain backwards from a symptom to a patch ("`npc` is stuck at
`0x800138d8`, so special-case that PC"). Backwards traversal is exactly what produced the
`g1*` predicate soup that now lives in `core/smt_legacy/` as an oracle rather than as a design.

---

## 1. Reading OpenSBI for obligations, not for symptoms

```python
def what_the_firmware_is_really_asking(locus):
    """Read the OpenSBI source until the demand is architectural, not textual.

    A good obligation survives recompiling the firmware with a different compiler,
    a different DTB, and a different link address. If your sentence contains a PC,
    a register name, or an OpenSBI symbol, you have not finished reading.
    """
    demand = literal_reading_of(locus)          # "sw a0,0(s2) at 0x12eb2 faults"
    while mentions_an_address_or_register(demand) or mentions_a_symbol(demand):
        demand = ask_why_once_more(demand)
        # sw a0,0(s2)              -> *lenp = err
        # *lenp = err              -> callee stores through a caller-supplied pointer
        # caller-supplied pointer  -> callee-saved regs and sp survive speculation
    assert is_expressible_in(demand, vocabulary=CVA6Cfg_and_the_ISA)
    return demand
```

The stop condition is the useful part: **an obligation is finished when it can be written using
only `CVA6Cfg` fields and ISA vocabulary.** "`s3` must not become `0x12b2a`" is not finished.
"a callee-saved register restored from the frame must observe the youngest architectural store to
that address" is finished — and it immediately tells you the home is the LSU/STQ, not fetch.

```python
def derive_obligations(opensbi_tree):
    """Walk the coldboot path once; emit one obligation per activity, not per fault."""
    for activity in coldboot_path(opensbi_tree):        # O0..O8 order, see section 7
        demand = what_the_firmware_is_really_asking(activity)
        yield Obligation(
            activity   = activity,
            capability = nearest_of(demand, R1..R12),      # firmware-boot-principles A
            invariants = invariants_that_imply(demand),    # firmware-boot-principles B
            home       = home_of(invariants),              # section 4
            observable = what_the_log_would_show(activity),# section 7, "Observe" column
        )
```

`what_the_log_would_show` is not optional. An obligation with no observable is unfalsifiable, and
an unfalsifiable obligation is how a boot-time crutch (`SMT_COLD_EXCL`) becomes permanent.

---

## 2. The obligation table (source-anchored)

Derived by running §1 over the coldboot path. Each entry is a *demand*, its OpenSBI locus, and where
the corresponding RTL guarantee lives. §3–§5 consult these definitions.

**These are labels for capabilities, not an ordered work list.** `R7` is not "after `R6`"; the
numbering matches `firmware-boot-principles.md` §A so the two documents can cite each other.

- **R1 — Reset-time election and per-hart stack.**
  *Locus:* `firmware/fw_base.S:38` `_start`, `:48` `_try_lottery`, `:292` `_wait_for_boot_hart`,
  `:302` `_start_warm`. *Code:* `amoswap.w` on `_boot_status` elects one relocator; losers spin.
  `sp` is written only by `_start`'s own path (`_fw_end + 2*SBI_SCRATCH_SIZE`).
  *Obligation:* per-hart state from reset; a non-boot hart legitimately runs with `sp == 0` until
  **its own** code writes it — the scheduler must not read that as "ready and healthy".
  *Invariants:* I10, I22, I23. *Home:* `arch_redirect` restore + `g6lc_smt_pc_bank`; thread select.
- **R2 — Ordinary supervisor init.**
  *Locus:* `lib/sbi/sbi_init.c:505` `sbi_init`, `:212` `init_coldboot`, `:194` `coldboot_done`.
  *Code:* ordinary loads/stores/branches; `coldboot_done` is set **early**, before `sbi_hart_init`.
  *Obligation:* ordinary correctness — and the warning that **`coldboot_done=1` proves nothing about
  the FDT walk**. *Invariants:* —. *Home:* —.
- **R2′ — Cross-hart release/acquire.**
  *Locus:* `lib/sbi/sbi_init.c:196` `wait_for_coldboot` → `__smp_load_acquire` + `cpu_relax()`.
  *Code:* a peer hart spins on an acquire load until the boot hart releases.
  *Obligation:* cross-hart RVWMO **and** a starvation bound — a spinning peer must not be able to
  hold fetch. *Invariants:* I23, I24. *Home:* thread-select bound; not fetch.
- **R3 — Self-armed CSR trap probe.**
  *Locus:* `include/sbi/sbi_csr_detect.h:17` `csr_read_allowed`; `lib/sbi/sbi_expected_trap.S:23`;
  `lib/sbi/sbi_hart.c:771` `hart_detect_features`, `:721` `hart_pmp_get_allowed_addr`.
  *Code:* `csrrw mtvec, tmp` / `csrr <probe>` / `csrw mtvec, tmp`, repeated dozens of times over
  HPM / PMP / priv / extension CSRs; the handler blindly does `mepc += 4`.
  *Obligation:* (a) precise trap; (b) the handler at `mtvec` is fetched and executed as written;
  (c) the blind `+4` is sound only because `csrr` is always a 4-byte RVI — so a realigner that
  presents a 16-bit fragment at the probe's address (the `csrr; c.sd; csrr` straddle inside one
  64-bit window, I4aa/I4ad/I4ae) turns a legal probe into an illegal instruction *and* mis-advances
  `mepc`; (d) `csrrw mtvec` must not dual-issue with the CSR it is arming.
  *Invariants:* I1, I2, I9, I13. *Home:* `align_slots` + `arch_redirect` trap hold; `stall_csr_older`
  (issue, **not** fetch).
- **R4 — libfdt structure walk.**
  *Locus:* `lib/utils/libfdt/fdt.c:18` `fdt_ro_probe_`, `:143` `fdt_offset_ptr`, `:165`
  `fdt_next_tag`, `:219` `fdt_check_node_offset_`, `:243` `fdt_next_node`;
  `lib/utils/libfdt/fdt_ro.c:356` `fdt_get_property_by_offset_`, `:394`
  `fdt_get_property_namelen_`, `:451` `fdt_getprop_namelen`.
  *Code:* deeply nested, heavily RVC, big-endian `lbu` assembly, `*lenp = err` stores through a
  caller-supplied pointer, and `fdt_offset_ptr` returning small offsets that later become addresses.
  *Obligation:* mixed RVC/RVI at **every** 2-byte alignment; callee-saved regs / `ra` / `sp` survive
  speculation; a restore observes the youngest store; small non-zero values are legal data.
  *Invariants:* I1–I5, I13–I17. *Home:* `align_slots` (L1) **or** STQ/scoreboard — this entry is the
  ambiguity §3 exists to resolve.
- **R5 — Indirect dispatch through platform ops.**
  *Locus:* `include/sbi/sbi_platform.h:73` `struct sbi_platform_operations`, `:265`
  `sbi_platform_ops()` — every `sbi_platform_*` inline is `if (ops->f) return ops->f(...)`.
  *Code:* `c.jalr` through a function-pointer table.
  *Obligation:* indirect branch; a mispredicted `jalr` **always** recovers to the architectural
  target — resolution is never filtered by value or by PMA. *Invariants:* I11, I19.
  *Home:* `arch_redirect` priority 6.
- **R6 — Heap freelist.**
  *Locus:* `lib/sbi/sbi_heap.c`. *Code:* freelist link chasing.
  *Obligation:* store-to-load forwarding complete and transparent. *Invariants:* I16, I17.
  *Home:* LSU.
- **R7 — Ticket lock and reservation.**
  *Locus:* `lib/sbi/riscv_locks.c:48` `spin_lock` (`amoadd.w.aqrl` then `lw` + acquire barrier),
  `:22` `spin_trylock` (`lr.w.aq` / `sc.w.rl`). *Code:* ticket lock; LR/SC retry loop.
  *Obligation:* AMO forward progress; the reservation is not clobbered by an unrelated store or by a
  squash. *Invariants:* I15, I24. *Home:* `amo_buffer`, `store_unit`, issue.
- **R8 — Byte-string walk.**
  *Locus:* `lib/sbi/sbi_string.c:43` `sbi_strlen`; `sbi_printf`. *Code:* byte walks, format loops.
  *Obligation:* **identical class to R4** — mixed C/I plus pointer liveness. *Invariants:* I1–I5.
  *Home:* same as R4.
- **R9 — HSM and per-hart interrupt state.**
  *Locus:* `lib/sbi/sbi_hsm.c:165` `sbi_hsm_hart_wait`, `:244` `sbi_hsm_init`, `:144`
  `sbi_hsm_hart_start_finish`. *Code:* per-hart state machine, IPI wait.
  *Obligation:* per-hart HSM/CLINT; `mhartid` unique. *Invariants:* I22, I25.
  *Home:* CSR banks, CLINT `S = N×T`.
- **R10 — Privilege handoff.**
  *Locus:* `lib/sbi/sbi_hart.c:1019` `sbi_hart_switch_mode`. *Code:* `mret` into S-mode.
  *Obligation:* `mret`, privilege, `mstatus`. *Invariants:* I8 (eret).
  *Home:* `arch_redirect` priority 3.
- **R11 — Hart count as the walk's only durable output.**
  *Locus:* `platform/generic/platform.c:144` `fw_platform_init` → `:187` `platform.hart_count`;
  `firmware/fw_base.S:115`, then `lwu s7, SBI_PLATFORM_HART_COUNT_OFFSET`.
  *Code:* `fdt_path_offset("/cpus")` then `fdt_for_each_subnode`, counting enabled `cpu@` nodes via
  `fdt_parse_hart_id`. *Obligation:* **`plat_hc` is the single best observable of a correct FDT
  walk** — `plat_hc==2` ⇔ two enabled `cpu@` nodes were counted, and `plat_hc==0x80` is the ELF's
  uninitialised default, meaning `fw_platform_init` never stored. *Invariants:* —.
  *Home:* R4's home, observed here.
- **R12 — Supervisor paging.**
  *Locus:* Linux. *Code:* Sv39; two-stage under `RVH`. *Obligation:* MMU. *Invariants:* —.
  *Home:* not fetch.

Two consequences that the history validates and that should shape every plan:

1. **R4 ≡ R8** (both are "mixed C/I plus pointer liveness") and **R3 ≡ R5** (both are "redirect
   priority"). There are **two** capability gaps, not ten. `firmware-boot-principles.md` §A states
   R1/R3/R4/R5/R8 were ~90% of 380 increments.
2. **`plat_hc` is the progress unit, and it is a *software* word.** RTL must never contain a
   `plat_hc` heuristic (`soft-ladder/CONTRACT.md` §1.5). It is read from the trapdump, not decided
   in silicon.

---

## 3. The blame router — is this even fetch?

The most expensive systematic error in the history was fixing R4 in the frontend when the fault was
in the LSU (and, twice, the reverse). Route before you patch.

```python
def route_blame(pin, trace, ab):
    """Return the OWNING LAYER, before any candidate is written.

    'ab' is the A/B pair: the same ELF soaked on the smt_legacy oracle (--flavour legacy)
    and on core/fetch_B (--flavour B), through the proxy. Never mix Mdirs, never fall
    back across flavours.
    """
    # -- 0. Cheapest discriminator in the whole methodology: the A/B pair. ------------
    if ab.legacy_green and ab.B_red:
        return "core/fetch_B — exactly one VALUES row on one of the four combos"
    if ab.legacy_red and ab.B_red:
        return "generic core (issue / STQ / CSR / commit) or B2 firmware policy"
    if ab.legacy_red and ab.B_green:
        return "A's g1* gates were load-bearing; record it, do not port them into B"

    # -- 1. Instruction-supply signature. -------------------------------------------
    #    Verbal test: does the PC in the pin point at something that is not the START
    #    of an instruction? If yes, the frontend delivered bytes that do not exist.
    if pin.npc_is_the_second_half_of_a_32bit_op():        # e.g. 0x...d8 for a beqz at 0x...d6
        return "L1 align_slots — leftover/straddle (I3/I5)"
    if pin.mtval_decodes_to_an_instruction_absent_from_the_ELF():
        return "L1 align_slots — fabricate or mis-assemble (I1/I2)"
    if pin.npc_never_advances_though_no_trap_fires():
        return "L2 window_accept or L3 order — a window or slot is being dropped forever"

    # -- 2. Redirect signature. ------------------------------------------------------
    if pin.pc_is_inside_the_trap_handler_but_past_its_first_instruction():
        return "L4 arch_redirect — mtvec entry not held until decode consumed it (I9)"
    if pin.control_flow_target_was_architecturally_correct_but_never_fetched():
        return "L4 arch_redirect — priority inversion (I8), typically restore vs trap"

    # -- 3. Data signature. Here is where 'looks like fetch' is usually wrong. -------
    if trace.a_load_retired_bytes_older_than_the_youngest_store_to_that_address():
        return "LSU — STQ / write-buffer / D$ overlay. NOT fetch."
    if trace.a_callee_saved_register_holds_a_value_from_a_previous_call_frame():
        return "LSU restore path or scoreboard squash window. NOT fetch."
    if trace.a_register_was_written_by_an_instruction_that_should_have_been_squashed():
        return "scoreboard / commit — squash membership (I13/I14/I15)"

    return "UNROUTED — grow the mini until one of the above fires; do not guess"
```

Two rules extracted from the negatives, worth stating in prose because they are counter-intuitive:

- **A stuck `npc` with no trap is not necessarily fetch.** It is equally often a cancelled
  instruction that is refetched forever (I4at, I4au) or an unbounded hold (`NEGATIVE.md` §1).
  Check "was it ever issued" before touching the realigner.
- **A plausible fetch story is not evidence.** iter-014's own record is the cautionary example:
  the same pin was attributed to the write-buffer, then to load write-back, then — only after a
  `--threads=1` Verilator build made the symptom *deterministic* — to a 32-bit straddle at a
  2-byte-aligned address. Determinism first, attribution second.

---

## 4. Candidate generation — from obligation to a SystemVerilog class

```python
def propose_class(obligation, pin):
    """Synthesise ONE candidate. A candidate is a RULE, never a value.

    The single most reliable quality test, applied before anything else:
    can the candidate be stated in one sentence that mentions no register
    number, no address, no opcode, and no OpenSBI symbol?
    """
    combo = owning_combo(obligation)              # section 2 'Home' column
    rule  = generalise(pin, upto=combo.vocabulary)

    candidate = Candidate(
        sentence   = one_sentence(rule),
        combo      = combo,
        gate       = minimal_config_gate(rule),   # NrHarts>1 / SuperscalarEn / RVC / FETCH_WIDTH
        si_identity= const_folds_when(gate.is_false),   # I27 — non-negotiable
        timing     = timing_impact_note(rule),    # AGENTS-coding-philosophy: mandatory
        mini       = smallest_test_that_can_fail(rule),
    )
    assert candidate.mini is not None, "no mini => no experiment, only a hope"
    return candidate


def owning_combo(obligation):
    """The four combos are the ONLY fetch RTL. There is no fifth."""
    return {
        "bytes and alignment"     : "align_slots   (L1)  I1-I5",
        "whole-window acceptance" : "window_accept (L2)  I7",
        "program order / packet"  : "order         (L3)  I6   — may drop, never modify",
        "which PC is next"        : "arch_redirect (L4)  I8-I12",
        "squash reach"            : "kill_s1 / kill_s2   — two assigns",
    }[obligation.axis]  # else: it is not fetch; go to issue / LSU / CSR / uncore


def minimal_config_gate(rule):
    """Gate on the parameter that EXPLAINS the behaviour (I28), not on the one that
    happens to be set in the failing package.

    Historical error worth not repeating: ~1600 predicates in A were gated
    'SuperscalarEn && NrHarts>1' when the geometry that actually explains them is
    'SuperscalarEn && RVC' (RC2). The wrong gate is why enabling dual-issue on the
    T=1 stream package would have resurrected the hang-6 class.
    """
    return smallest_set_of_CVA6Cfg_fields_that_explains(rule)
```

`propose_class` deliberately returns **one** candidate. "One residual class per iteration" is not
bureaucratic politeness; it is what makes a negative result *informative*. Two simultaneous changes
produce a soak result that cannot be attributed, and the history shows those get re-tried.

---

## 5. The pruner — the highest-value function in this file

`NEGATIVE.md` exists because the *same rule* was independently rediscovered and re-failed up to
five times ("do not stall or fault on a small-non-zero address use" = `I4bv`, `I4ca`, `G0`, `G1i`,
`W1` — five reverts, one lesson). This function is that document as a predicate. Run it **before**
building anything.

```python
def survives_negative(c):
    """Twelve mechanism-indexed vetoes. Any single failure => the candidate is dead.
    Do not 'tighten the trigger condition' — every one of these classes was already
    tried at several widths, and there is no stable middle setting.
    """

    # 1. Unbounded holds — the largest failure class (~25 reverts).
    if c.suppresses_forward_progress() and not c.carries_an_explicit_cycle_bound():
        veto("N1 unbounded hold. I23 requires a bound; firmware boot is the workload "
             "most sensitive to starvation. Add hold_max or abandon.")

    # 2. Kill / flush suppression.
    if c.spares_a_kill_or_flush_based_on_a_PC_alignment_class():
        veto("N2. Suppression must name a provable in-flight object. Eight settings "
             "were tried; all failed in one direction or the other. Prefer making the "
             "state INERT under kill (SPEC 2.2) so no suppression is needed.")

    # 3. Prediction suppression.
    if c.suppresses_resolution():
        veto("N3/I11. Prediction is a hint; RESOLUTION IS NOT. Filtering resolve by "
             "value or by PMA is an ISA red line (firmware-boot-principles E).")
    if c.suppresses_prediction_broadly():
        veto("N3. Broad bp_valid suppression starves fetch; narrow suppression only "
             "ever buys performance, never correctness.")

    # 4. Fabrication / rewrite.
    if c.rewrites_or_synthesises_instruction_bytes():
        veto("N4/RC3. The premise is wrong: the frontend delivers the bytes in memory. "
             "make_cjalr16 stays in smt_legacy forever.")

    # 5. Order restoration downstream.
    if c.reorders_the_IQ_by_opcode_or_rd_or_fu():
        veto("N5/I6. Program order cannot be restored downstream by opcode priority.")

    # 6. Address override / window stealing.
    if c.forces_the_fetch_address_away_from_the_architectural_next_PC():
        veto("N6. Whatever the stolen window was for, it starves.")

    # 7. Value-based control. Cheap to state, and it catches a lot.
    if c.inspects_a_DATA_VALUE_to_make_a_CONTROL_decision():
        veto("N7/I17. Every attempt failed: stall-on-small-address, drop-x8-unless-"
             "aligned, drop-x1-if-below-4KiB, forward-by-page-zero, resolve-by-PMA. "
             "Forwarding is transparent; commit filters are an ISA red line.")

    # 8. Squash exemption lists.
    if c.adds_a_keep_by_register_or_keep_by_immediate_or_keep_by_FU_exemption():
        veto("N8/I13. An exemption list is EVIDENCE THAT THE SQUASH WINDOW IS WRONG. "
             "The A list grew to dozens of clauses and never closed the pin. "
             "Fix membership (program order, same-hart) instead.")

    # 9. Thread-switch drain / PC rewind.
    if c.preserves_inflight_frontend_state_across_a_switch() or c.rewinds_a_banked_PC():
        veto("N9. I4av/I4aw HOLD-FAIL. Bank the accepted address on switch (I10) and "
             "nothing else.")

    # 10. Combinational loops.
    if c.gates_control_flow_classification_on_queue_consumption():
        veto("N10. Classification must be independent of consume (G1br).")

    # 11. Leftover completion window.
    if c.completes_a_straddle_from_any_window_other_than_the_immediately_next_one():
        veto("N11/I3. Also: do NOT keep leftover across a valid non-next window "
             "(I4az, plat_hc=80), and do NOT complete {hi, 0} — require [1:0]==2'b11 (I5).")

    # 12. Process-level.
    if c.uses_the_cookie_as_a_SEARCH_signal():
        veto("N12. The cookie is a GATE. Searching on a 6-minute firmware soak is how "
             "380 increments happened. Search on minis.")
    if c.is_a_new_g1_style_predicate():
        veto("N12. Do not add a 381st g1* predicate. New behaviour is a VALUES row.")

    return no_vetoes_fired()
```

```python
def is_this_candidate_worth_building(c):
    """Composite admission test."""
    return (survives_negative(c)
            and c.sentence_mentions_no_address_register_or_opcode()
            and c.si_identity                       # I27: baseline netlist bit-identical
            and c.gate_explains_the_behaviour()     # I28
            and c.timing_note_exists()              # AGENTS-coding-philosophy 0.5
            and c.mini_can_actually_fail())         # not a tautological PASS
```

---

## 6. The gate — verdict semantics

```python
def soak(candidate):
    """Mini first. Firmware second. Peel last. Always through the proxy."""
    if mini(candidate.mini) is FAIL:
        return "MINI-FAIL — the class is wrong. Revert. Do NOT add a second register "
               "to the same predicate (that is how G1b..G1mf happened)."

    if hold_elf_cookie() != 0x51b1babe:
        return "HOLD-FAIL — the candidate broke a known-good path. Revert immediately; "
               "a HOLD-FAIL is never 'nearly right'."

    if natural_path_pin_is_unchanged():
        return ("HYGIENE / 'kept' — mini green, hold green, pin unmoved. The candidate is "
                "correct but was not this bug. Keep it only if it is independently "
                "defensible as correctness; otherwise revert. This is the MODAL outcome: "
                "budget for it, and do not read it as progress on the pin.")

    return "FIRED — the pin moved. Log the NEW pin and re-enter at section 3."
```

Contract details that are easy to get wrong and are load-bearing:

| Thing | Rule |
|---|---|
| SUCCESS for soft-ladder | trapdump cookie `51b1babe` **only**. Harness `tohost=0` is *not* it. |
| `51b1c001` | The success cave ran its `lui` but not its `addi` — a *partial* cave means a wrong-path or lost instruction, i.e. still red. |
| `plat_hc=0x80` | `fw_platform_init` never stored `hart_count`; the FDT walk failed early. |
| `coldboot_done=1` | Set early in `sbi_init` (`sbi_init.c:194`/`:206`), **before** `sbi_hart_init`. It does *not* mean the cookie path ran. |
| Proxy `rc=255` | SSH drop, not a failure. Classify from `runs/<tag>/run-*.log`. |
| Linux-cap hygiene | If the class touches SMT ready / IPI / fetch / STQ, re-confirm `g6lc64_server_math_v` and `g6lc64_ooo_server` still reach `tohost=0` at the 200M cap (I4dp). |

`hygiene` being the modal outcome is the single most important expectation to set. A methodology
that treats "correct but not this bug" as failure will thrash; one that treats it as success will
accumulate dead predicates. It is neither — it is a **keep-if-independently-defensible**.

---

## 7. The ladder — which stage to attempt next

```python
def pick_next_stage(log):
    """Residual CLASSES say what to repair. BOOT STAGES say what to attempt.
    Always attack the LOWEST un-green stage; a fix validated above a broken stage
    is not validated.
    """
    for stage in [O0, O1, O2, O3, O4, O5, O6, O7, O8]:
        if not green(stage, log):
            return stage
    return "O8 green — move to capability increments (section 9)"
```

The stages are **definitions of where the firmware currently is**, read off a log. They are not a
checklist to tick: at any moment exactly one of them is the lowest un-green one, and that is the
only one that matters.

- **O0 — Reset and election.** Activity: `_start` / `_start_warm`, lottery, `sp` setup.
  Observable: `hangpc`, `sp1`, `last_hartidx`. If B-red: `arch_redirect` restore.
  If not fetch: ready/IPI (I4dn).
- **O1 — Library init.** Activity: `sbi_init`, `coldboot_done`. Observable: `coldboot_done=1`.
  If B-red: —. If not fetch: ordinary load/store.
- **O2 — Feature detection.** Activity: `sbi_hart_init` expected-trap probes. Observable: `mepc`
  inside the handler rather than an illegal at a half-instruction. If B-red: `arch_redirect` mtvec
  hold + `align_slots` I+C+RVI. If not fetch: CSR bank, `stall_csr_older`.
- **O3 — FDT walk.** Activity: libfdt `namelen` / `next_tag` / `getprop`. Observable: **the cookie,
  or the pin.** If B-red: leftover, L1. If not fetch: STQ / callee-saved.
- **O4 — Platform dispatch.** Activity: platform ops `c.jalr`. Observable: execution does not land
  in FDT bytes. If B-red: `arch_redirect` I11. If not fetch: platform ops.
- **O5 — Console.** Activity: `printf` / `strlen`. Observable: BANR present. If B-red:
  `align_slots`. If not fetch: —.
- **O6 — Domain and both harts.** Activity: domain / HSM / secondary bring-up. Observable:
  `plat_hc==2`, hart1 in WFI with `sp != 0`. If B-red: restore. If not fetch: CLINT `S = N×T`.
- **O7 — Privilege handoff.** Activity: `switch_mode` → S. Observable: payload entry.
  If B-red: L4 eret. If not fetch: —.
- **O8 — Supervisor.** Activity: Linux Sv39 / `cpuinfo`. Observable: Image path;
  `/proc/cpuinfo` count `== S`. If B-red: —. If not fetch: DTS `cpu-map`.

**Live position (2026-08-30/31):** `g6lc64_smt2` is at **O3**. `g6lc64_server_math_v` (N=2 T=2 I=2,
RVV, RVH) and `g6lc64_ooo_server` (N=4 T=2 I=4, S=8) already pass O8-as-capability
(`tohost=0` at 200M through the proxy) — **and their 200M SUCCESS is not cookie green.** Two
different SUCCESS contracts, two different planes; conflating them is how a false green gets
recorded. Source: [`linux-boot-scale.md`](linux-boot-scale.md) §1/§3.

---

## 8. Retirement — shrinking the oracle

```python
def may_retire_soft(site):
    """mk_plat_skip.py is temporary EVIDENCE. It retires; it never becomes policy."""
    if not hold_is_green_WITHOUT(site):
        return "no — the peel is still load-bearing; keep it and keep it tracked"
    if inventory[site].bucket == "B1" and inventory[site].status != "rtl-fixed":
        return "no — B1 retires only against an RTL commit, never against a firmware ifdef"
    if inventory[site].bucket == "B2" and not is_genuine_product_policy(site):
        return "no — B2 must never be used to hide an open B1 hole (README P5)"
    return "yes — delete the site, update inventory.yaml, note the commit"
```

The end state is explicit and worth restating because it is the definition of done for this whole
track: **stock (or source-profiled) OpenSBI, no peels, on RTL that runs it under dual-issue SMT** —
`plat_hc==2`, `coldboot_done==1`, natural FDT/printf/domain, and `SMT_COLD_EXCL` /
`SMT_FIRST_ACT_EXCL` deleted (`smt2-bringup.md` "Known limits").

---

## 9. Capability navigation — feature sets on four combos

Once fetch is A (it is: `core/frontend` frozen, `core/fetch_B` default), new features are **B
increments through the same loop**. This is the part of the methodology that answers "how do further
improvements and feature sets get added" without re-opening the archaeology.

```python
def plan_capability(feature):
    """One capability per increment. Same P1-P4. Same peels. Same hold soak."""
    if touches_instruction_bytes_or_next_PC(feature):
        return AddValuesRow(combo=owning_combo(feature))   # NOT a fifth combo
    if is_a_width_or_count(feature):
        return AdjustGeometry(field=geo_field_of(feature)) # geo.issue / geo.harts / geo.slots
    return NotFetch(home=issue_or_LSU_or_CSR_or_uncore_or_DTS(feature))
```

| Feature to add | Where it lands | Gate to soak | Refuse if |
|---|---|---|---|
| Precise trap (R3) | L4 bounded hold (I9) | `mini_csr_expected_trap` then hold | the hold is unbounded |
| Indirect `jalr` (R5) | L4 resolve **unfiltered**; legality on predict only | lottery mini then hold | you filtered resolve |
| Leftover / present-at-npc (R4/R8) | L1 VALUES row | straddle mini then hold | you fabricate a sibling |
| Stream `I=1 → I=2` | `geo.issue=2` on the **stream** package, `en.restore=0` | stream leftover + FDT-shape minis | you soak it on smt2's pin |
| n-wide `I=2 → 4` | `geo.issue=4` on the L3 loop | barrier/keep re-soak | you call issue width a hart |
| `NrCores 1 → N` | **no fetch edit**: cluster + DTS `cpu-map` + CLINT `S=N×T` | `stream8-smoke` | `S = N×T > 8` (PLIC `NumTargets=16`) |
| `NrHarts 2 → 4` | `geo.harts` + leftover banks + `check_cfg` | G3 `sp==0` mini | `CVA6_MAX_SMT_HARTS==2` is unrewritten |
| `RVH` | inject suppressed on I$ exception; **no H ports on fetch** | H-edge on *that* package; DTS `h` iff `RVH=1` | you add a `gva`/`hgatp` port to fetch |
| RVV / Ara | **no fetch ports**; named `_v` package | `ara-vector-path` | `CvxifEn` and `EnableAccelerator` both set |
| Linux Image (R3b) | software/DTS | `smt-linux-*` | you cite it as cookie green |

Two structural mutexes that a plan must respect rather than paper over: `CvxifEn ⟂ Ara`
(`core/cva6.sv` `gen_err_xif_and_acc`) and `SuperscalarEn ⟂ EnableAccelerator` (AI-2 is the tracked
lift). And one contract: **issue width is never a Linux hart.** `NrIssuePorts` must not appear in
any DTS.

---

## 10. Priors — what 380 increments actually taught

Fitted on one ELF and one config (see the caveat at the top). Use them to **order** experiments.

```python
PRIORS = {
    # Where a pin in the FDT walk actually lives, given "it looks like fetch":
    "P(fetch | pin in libfdt walk)":            "low-moderate — LSU/STQ and squash-window "
                                                "explanations won more often than L1 did",
    # Expected outcome of a well-formed candidate:
    "P(hygiene | survives_negative)":           "high — plan for it; it is not failure",
    "P(fires | survives_negative)":             "low per increment; the loop, not the "
                                                "increment, is the mechanism",
    "P(regression | fails survives_negative)":  "very high — the vetoes are empirical",
    # Cheapest information per unit time, best first:
    "information_per_hour": ["make the symptom deterministic (--threads=1, bounded pool)",
                             "A/B flavour pair (legacy vs B, same ELF)",
                             "directed mini with distinct fail-codes per phase",
                             "TRACE window around the pin",
                             "full firmware soak"],
}
```

Three priors deserve prose because they invert the intuitive ordering:

1. **Determinism before attribution.** iter-014 only became routable when a `--threads=1` Verilator
   build turned a wandering hang into a fixed `npc0`. A `translate_off` snap module with no outputs
   changed the outcome — that is a *timing-sensitivity* finding, and it is worth more than any
   patch attempted before it.
2. **The A/B pair is the cheapest discriminator in the whole methodology** and it is almost free
   (same ELF, two flavours). Run it before writing RTL, not after.
3. **Minis that PASS are informative.** `mini_fdt_rdxrs1`, `mini_fdt_ro_probe`,
   `mini_fetch_straddle` all PASS — each one *deletes* a hypothesis. A negative bisect is a result;
   record it in `NEGATIVE.md` / `ITERATION.md` so it is not re-run.

---

## 11. Worked example — the live pin, end-to-end

Applying §1 → §8 to iter-014 (active; `ITERATION.md:1955`).

```text
1  Locus            fdt.c:18 fdt_ro_probe_ -- BE u32 header assembly from lbu at
                    header offsets 0/4/20/24/36. Reached through
                    libfdt_internal.h:14 FDT_RO_PROBE from every read-only entry
                    point; the caller in the trace is fdt_ro.c:250
                    fdt_path_offset_namelen (ra=0x80013792). The pinned PC is in
                    fdt_ro.c:469 fdt_getprop_by_offset, which is the
                    fdt_get_property_by_offset_ (fdt_ro.c:356) path.

2  Obligation       what_the_firmware_is_really_asking:
                    "a5 is stale"                       -> mentions a register, keep going
                    "the lbu has not retired"            -> mentions an op, keep going
                    "the 32-bit RVI at a 2-byte-aligned address that straddles the
                     64-bit fetch window is not delivered as one instruction"
                                                         -> CVA6Cfg + ISA vocabulary. STOP.
                    => R4 (mixed RVC/RVI at every 2-byte alignment).

3  Invariants       I2 (emit exactly the ISA instructions at a, a+ilen(a), ...),
                    I3 (a straddle completes ONLY from the immediately next window),
                    I5 (completable only if lo[1:0]==2'b11).

4  Route            route_blame:
                    pin.npc_is_the_second_half_of_a_32bit_op()  -- npc0=0x800138d8 is the
                    upper half of `beqz s4` at 0x800138d6 (addr[1:0]=10)  -> TRUE
                    => L1 align_slots, i.e. core/fetch_B/instr_realign.sv (+ instr_queue
                       leftover/drop). Prior LSU attributions (write-buffer, load write-back)
                       are RULED OUT by mini_fdt_rdxrs1 PASS and mini_fdt_ro_probe PASS.

5  Candidate        Must be a rule over {FETCH_WIDTH, ALIGN_BITS, RVC, NrHarts} about
                    leftover carry/complete when the two halves of one RVI land in
                    different windows. Pruner check:
                      N11  does it complete from a non-next window?      must be NO
                      N11  does it keep leftover across a valid non-next? must be NO
                           (I4az / VALUES 563299f6 HOLD-FAIL plat_hc=80)
                      N1   any new hold without a bound?                 must be NO
                      N2   does it spare a kill by PC alignment class?    must be NO
                      N4   does it assemble bytes not in memory?         must be NO
                    Config gate: SuperscalarEn && RVC && FETCH_WIDTH>=64  -- NOT NrHarts>1
                                 (I28 / RC2: T does not explain a straddle).

6  Mini             mini_fetch_straddle PASSES today => insufficient. The next mini must add
                    the missing trigger: the fdt_getprop_by_offset prologue, a live s4,
                    the preceding sbi_strlen, and a hart1 spin -- i.e. reproduce the
                    CONTEXT, not just the shape. (ITERATION I6 says exactly this.)

7  Gate             mini -> hold cookie 51b1babe -> nat -> PEEL_FDT_GETPROP / PEEL_FDT_NEXT_TAG,
                    all via testharness_proxy.py; then I4dp hygiene (_v and ooo_server
                    200M) because the class touches fetch.

8  Retire           Only on PEEL cookie green: drop the matching mk_plat_skip site;
                    soft getprop stays until plat_hc==2.
```

Note what the algorithm *refused* to do at step 5: special-case `0x800138d6`, add a keep for `s4`,
or hold fetch until the `lbu` retires. Each of those is a named veto (N7, N8, N1), and each was
already tried in some form.

---

## 12. Using and updating this file

| Situation | Do |
|---|---|
| Starting an increment | §7 pick the stage → §3 route → §4 propose → §5 prune → §6 gate |
| A candidate "feels right" but trips a veto | The veto wins. Vetoes are empirical, not stylistic. |
| A veto is wrong | Prove it with a mini + hold-green soak, then amend `NEGATIVE.md` **first** and this file second. Never silently. |
| A new obligation appears (new firmware, new DTB, Linux) | Add a §2 row with its OpenSBI `file:line` and its observable. No row without an observable. |
| A prior in §10 contradicts a proxy log | The log wins. Update the prior. |
| Adding a feature, not fixing a bug | §9. One capability per increment; peels last. |

**This file is subordinate to `AGENTS.md` §0.** Any RTL that comes out of it still owes the
carry-over checklist: config-gated with a `check_cfg` assert, `always_ff`/`always_comb` clean,
async-active-low reset only, a timing-impact note, RVFI/PMU observability, `test_en_i`/`testmode_i`
preserved, and a `.dts` ↔ config ↔ spec alignment note. A heuristic that produces
un-synthesizable or un-verifiable RTL has produced nothing.

**Related:** [`soft-ladder/README.md`](soft-ladder/README.md) ·
[`soft-ladder/COMPLETION.md`](soft-ladder/COMPLETION.md) ·
[`soft-ladder/ITERATION.md`](soft-ladder/ITERATION.md) ·
[`soft-ladder/b1-rtl-residuals.md`](soft-ladder/b1-rtl-residuals.md) ·
[`soft-ladder/CONTRACT.md`](soft-ladder/CONTRACT.md) ·
[`smt2-bringup.md`](smt2-bringup.md) · [`linux-boot-scale.md`](linux-boot-scale.md) ·
[`testharness-proxy.md`](testharness-proxy.md) ·
[`../firmware-boot-principles.md`](../firmware-boot-principles.md) ·
[`../core-fetch/SPEC.md`](../core-fetch/SPEC.md) ·
[`../core-fetch/VALUES.md`](../core-fetch/VALUES.md) ·
[`../core-fetch/NEGATIVE.md`](../core-fetch/NEGATIVE.md) ·
`software/smt2-linux/README.md` · `AGENTS-todo.md` (SL-A…SL-T).
