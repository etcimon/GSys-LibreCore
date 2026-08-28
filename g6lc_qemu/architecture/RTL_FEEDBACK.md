# RTL_FEEDBACK — findings that flow back into the design

Index: [`README.md`](README.md). Invariants: [`../AGENTS.md`](../AGENTS.md).
Contracts are named by **pin id** from [`../pins.toml`](../pins.toml), never by external path.

---

## 1. Why this ledger exists

This package reads the design and refuses to guess. Every refusal is information: if the emulator
cannot answer a question from the design's own files, then **no consumer of those files can** — not a
driver author, not a firmware engineer, not a second emulator. The refusal is a finding about the
design's published surface, not a limitation to be worked around locally.

Without somewhere to put them, those findings get "fixed" the wrong way — a literal in an emitter, a
default that looks derived — and the divergence surfaces months later as a phantom RTL bug.

So the rule is:

> A constant the design does not publish is recorded here as an **ask on the design**, and left
> visibly unresolved in the code. It is never quietly defaulted.

Each ask states what unblocks when it lands, so the design side can judge priority against the
emulator work it gates rather than against an abstract tidiness argument.

## 2. Open asks on the design

| # | Finding | Design-side ask | Pin | Blocks |
|---|---|---|---|---|
| **F1** | The island's MMIO **placement** is decided in the address decode (RTL), while the capability *offsets* are published in a package. The emulator ingests offsets and cannot resolve bases. | Publish the island register-map placement as localparams beside the existing capability offsets: capability window base, descriptor latch base, and the control/status/doorbell/completion/queue-region/counter offsets. | `contracts.ai_island_cap` | A guest cannot address the island. The pushed path (`AI_BRIDGE.md` §2) is end-to-end exercisable only against a model that states the bases. |
| **F2** | The accepted **descriptor version** is validated in RTL but never published as a named constant, so nothing can be compared against. | Publish the accepted descriptor version in the descriptor package. | `contracts.ai_island_mmio` | `FALLBACK_DESC_VERSION` in the device model, and any honest "bad version" reporting. |
| **F3** | Two capability words are **packed encodings** (tile dimensions; data-type grant bits) whose bit layout lives only in RTL comments. | Publish the shift/width of each packed subfield as localparams. | `contracts.ai_island_cap` | Two capability words stay absent from the guest-visible window; `cap_unsourced()` reports them. |
| **F4** | The descriptor is latched through a **word-indexed window**, so a host image and the device agree only if both use the same base *and* the same word ordering. Nothing states the ordering independently of the packing function. | Confirm that descriptor field offsets are byte offsets into the latch window, or publish the word map. | `contracts.ai_island_mmio` | Byte-for-byte agreement between the native device, the generated device model, and a host-packed image. |
| **F5** | The **data-type selector is a packed subfield of the descriptor flag word**, and its position is published nowhere — it exists only as a shift and mask agreed by convention. | Publish the shift and width of the data-type selector (and any other flag subfields) as localparams. | `contracts.ai_island_mmio` | The constant currently lives once in `g6q_core::model` so the D2 derivation and the generated plugin cannot drift; it becomes ingested when published. |

**Status discipline:** an ask stays here until the design publishes the constant *or* the ask is
withdrawn with a reason. Removing a row because the emulator worked around it locally is the failure
this file prevents.

## 3. What the asks unblock, in dependency order

```text
F1 placement ────► guest-addressable island ────► pushed path end-to-end
   │                                                   │
   │                                                   ▼
   └──► generated device model agrees with B3    remote route carries submissions
F2 version ──────► honest bad-version reporting
F3 packing ──────► complete capability window ──► one guest binary across parts
F4 word map ─────► host image == device == emitted model
F5 flag packing ─► ingested dtype instead of a shared Rust constant
```

F1 is load-bearing: until it lands, every other accelerator result is against a model that states
its own bases rather than against the design's. Note that the B2 plugin now *gates itself* on F1:
with the placement unresolved it emits an access stream rather than a submission stream, because
decoding against a guessed base would produce plausible-looking wrong tensor events.

## 4. Using the emulator to debug cluster bring-up

This is the other direction of the same loop, and it is the reason the speed difference matters.

| Instrument | What it answers | Where it is defined |
|---|---|---|
| B3 native run | does the queue/descriptor sequence behave as the ISA says? | [`EMIT.md`](EMIT.md), [`DESIGN.md`](DESIGN.md) §3 |
| B1+B2 full system | does a real driver and firmware drive it correctly? | [`EMIT.md`](EMIT.md) |
| D1 tandem + checkpoint | *which instruction* first diverges from a reference or a captured trace | [`DIAG.md`](DIAG.md) |
| D2 tensor counters | how much work was submitted, and did it complete | [`DIAG.md`](DIAG.md) §4.1 |
| tensor artifact | the descriptor/MMIO event stream, comparable across routes | [`AI_BRIDGE.md`](AI_BRIDGE.md) §5 |

The workflow that pays for itself:

1. Reproduce the failure on the **fastest instrument that can still exhibit it** — usually B3, then
   B1 if firmware or a driver is implicated.
2. If a reference exists, run **D1 tandem** and take the *first* divergence, not the symptom.
3. Export a **checkpoint** near the divergence so a cycle-exact simulator resumes there instead of
   re-running the boot.
4. Compare the **tensor artifact** between a known-good and a failing run with
   `ai_tensor_bridge.py compare`, which reports first divergence rather than a wall of differences.

Two honesty constraints on anything this produces:

- results are a **hypothesis and a checkpoint**, never verification evidence
  ([`../AGENTS.md`](../AGENTS.md) directive 8);
- only the faithful machine profile may be cited; a deviated or virt run is stamped and quarantined
  ([`DESIGN.md`](DESIGN.md) §4).

### 4.1 A live case the emulator is the right instrument for

The design's own two-thread firmware bring-up does not currently complete its platform
initialisation: the reported hart count never reaches the expected total, so the topology is not
trustable. Under RTL simulation that failure costs a long run per attempt; on B1 it is orders of
magnitude cheaper, and D1 gives the first divergent instruction rather than a hang.

Two invariants this package therefore enforces on anything it emits, so the emulator cannot mask the
defect it is being used to find:

- the number of processor nodes in the emitted tree equals the total logical hart count, and
- the firmware's reported hart count equals that same total before any topology claim is trusted.

An emulator that happily booted a tree those two rules reject would be actively harmful here.

## 5. Aggregation policy

Findings batch into change sets rather than landing one commit at a time, because a single finding
usually touches the reader, the IR, the schema, a device or emitter, and a document — and a partial
landing leaves the IR and the schema disagreeing.

A change set is ready when:

- [ ] the reader resolves the new field, and reports it **unresolved** when absent;
- [ ] the IR and `schemas/*.json` both carry it (the schema is `additionalProperties: false`, so
      omitting it makes previously-valid models invalid);
- [ ] no consumer defaults it silently; degradation is visible at the CLI or in the report;
- [ ] a test asserts the *absent* case as well as the present one;
- [ ] a test pins the design's published name set, so a newly added name surfaces as a tracked gap
      instead of silently disappearing;
- [ ] the architecture document and [`../AGENTS-todo.md`](../AGENTS-todo.md) are updated in the same
      pass;
- [ ] `python tools/g6q.py check` is green.

The name-set test is the one most often skipped and the most valuable: a capability or field the
design adds and this package ignores becomes a guest-visible zero, and zero is usually a legal value,
so nothing looks wrong anywhere.
