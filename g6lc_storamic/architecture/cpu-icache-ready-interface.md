# CPU I-cache `ready` interface split (C0 next step)

Status: **specified, not implemented.** This is the concrete next C0 code
update identified by the CPU46 `split_var` diagnostic
(`storamic-cpu46core-f62bf710`). It requires the remote strict-Verilator
diagnostic loop to confirm; do not promote on local evidence alone.

## Why this change

Strict full-core UNOPTFLAT diagnostics sit at **4 field / 21 FP** identities
(both `OriginEnabled` modes), down from 6/23 after CPU45/46. The CPU46
`split_var` sweep proved packed-var splitting cannot remove them:

- `icache` variant: byte-identical warning output (inert).
- `dcache` variant: strictly worse (4→9 fields, 21→24 FP).

The four remaining field identities route through one frontend
`kill_s2`/`bp_fire` cone:

- `flush_ctrl_id`
- `update_access_exception`
- `g6lc_icache.dreq_o[366]` — the `ready` bit of `icache_drsp_t`
- `load_store_unit`/`ex_stage` `req_port_o` — the D-cache port-array cone
  (a separate, still-open item; this change does not address it)

Gate-level analysis (`storamic-cpu40`/`cpu41`) found **0 real combinational
SCCs**, so these are Verilator *representation* artifacts: `ready` shares the
packed `icache_drsp_t` vector with the fetch-response payload
(`valid`/`data`/`user`/`token`/`vaddr`/`ex`). The branch predictor consumes
the payload while `ready` depends on `kill_s2 = kill_s1 | bp_fire`; packing
them into one struct makes Verilator merge the cones and report a false
loop that does not exist at gate level.

## The change (behaviour-preserving repackaging)

Move `ready` out of `icache_drsp_t` onto a dedicated scalar path. The signal
value, driver and consumer are unchanged — only its transport leaves the
packed response word. Equivalence is therefore trivial *if* every producer
and consumer is updated; the risk is an missed site (elaboration catches it).

### 1. `core/cva6.sv` — struct + wiring

- Remove `logic ready;` from `localparam type icache_drsp_t` (≈ line 87).
  The struct keeps `{valid, data, user, token, vaddr, ex}`.
- Add a scalar net beside `icache_dreq_cache_if`, e.g.
  `logic icache_ready_if_cache;` (icache → frontend direction, same as the
  drsp payload).
- On `i_frontend`: add `.icache_ready_i (icache_ready_if_cache)`.
- On each instantiated cache subsystem (`std`/`wt`/`hpdcache`, ≈ lines
  3526/3599/3677): add `.icache_ready_o (icache_ready_if_cache)`.

### 2. Producer chain — `ready` becomes a port at each level

The value originates only in `g6lc_icache`; every layer is a passthrough.

- `core/cache_subsystem/g6lc_icache.sv`
  - Add `output logic dreq_ready_o` (name TBD to match port style).
  - The existing comb block assigns `dreq_o.ready`; retarget those writes to
    a local `ready` net (or directly to `dreq_ready_o`). All *internal* uses
    of `dreq_o.ready` — `vaddr_d` (≈195), `cl_offset_d` (≈233/242),
    `token_q` capture (≈267), the hit-gate at ≈560 — must read the same
    local `ready`, not the removed struct member.
- `core/cache_subsystem/cva6_icache_axi_wrapper.sv`
  - Add `output logic dreq_ready_o`; connect `i_g6lc_icache.dreq_ready_o`.
- `core/cache_subsystem/std_cache_subsystem.sv`,
  `wt_cache_subsystem.sv`, `cva6_hpdcache_subsystem.sv`
  - Add `output logic icache_ready_o`; connect the wrapper's
  `dreq_ready_o`. These already pass `dreq_o`/`icache_dreq_o` straight
  through, so `ready` follows the same wire.

### 3. Consumer side — frontends read the scalar input

Each frontend that reads `icache_dreq_i.ready` gains
`input logic icache_ready_i` and substitutes it. Sites found:

- `core/fetch/frontend.sv` — `if_ready` (≈523), `demand_fire` (≈561),
  `.icache_ready_i` into the fetch/FTQ leaf (≈608).
- `core/fetch_A/frontend/frontend.sv` — `if_ready` (≈526), `demand_fire`
  (≈564), `.icache_ready_i` (≈611).
- `core/fetch_B/frontend.sv` — `if_ready` (≈809), `demand_fire` (≈861),
  `.icache_ready_i` (≈908), `icache_accept` (≈999).
- `core/fetch_A/smt_legacy/frontend.sv` — audit `.ready` use (mostly
  `.valid`/`kill_s2` seen; confirm before editing).

### 4. Formal / leaf copies

- `core/fetch_B/formal/*/src/frontend.sv` are self-contained frontend
  copies for the formal leaves; if they instantiate or mirror the port
  list, add `icache_ready_i` (tied to the leaf's ready source) so the
  formal models still elaborate. `g6lc_fetch_*_props.sv` reference
  frontend internals — check for `.ready`/`icache_dreq_i` assumptions.

## Why this should remove the identities

`ready` no longer shares a packed vector with `valid`/`data`/`ex`. Verilator
orders `ready`'s cone (`kill_s2 → dreq_ready_o → icache_ready_i →
if_ready/demand_fire`) separately from the response cone
(`valid/data → bp_fire`). Because `ready` only gates request *acceptance*
and never feeds the response payload, there is no real path
`ready → bp_fire → ready`; the reported loop collapses to the two
independent, register-broken cones the gate-level netlist already proves
acyclic.

## Verification plan (remote, owned tools)

1. **Elaboration:** slang/`read_slang` on the CPU wrapper for each active
   config (OriginEnabled 0/1) — must elaborate with no missing-port or
   width errors. This is the completeness gate for the repackaging.
2. **Equivalence:** behaviour-preserving by construction (same driver,
   same consumer, only transport changed). A cone-scoped or full-module
   `sat -prove-asserts` on the ready path is cheap insurance; the CPU45
   icache full-module equivalence harness is the template.
3. **Strict diagnostics:** re-run the CPU45/46 recipe (`verify*core.py`,
   fields + FP control sets, both origins). Expect the three I-cache
   `ready`-cone identities (`flush_ctrl_id`, `update_access_exception`,
   `dreq_o[366]`) to drop; the D-cache `req_port_o` identity is a
   *separate* open item and is expected to remain.
4. **Regression:** `cpu-origin`, `fetch-queue`, `sbcommit`, `fp-lifetime`
   remote stages must stay green (the CPU45/46 set).
5. Record as a new `storamic-cpuNN` receipt; do **not** claim C0 closure —
   the D-cache port-array identity and the V0 aggregate gate remain open.

## Open risks

- **Missed consumer/producer** — the only functional risk; slang
  elaboration is the completeness check.
- **`ready` semantics per frontend variant** — `fetch_A`/`fetch_B`/
  `smt_legacy` may qualify acceptance differently; audit each `.ready`
  site rather than assuming identical substitution.
- **The D-cache `req_port_o` identity is out of scope** — splitting the
  D-cache port arrays was already shown to expose *more* identities
  (CPU46 dcache variant 4→9). It needs its own interface-level decision,
  not this change.
