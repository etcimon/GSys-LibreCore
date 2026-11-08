# Block Backend Address and Descriptor Validation

This ST-036 review concerns the non-hyp8 `g6lc_storamic_virtio_blk` component.
It does not promote a physical drive, enlarge native capacity or enable
checkpoint admission.

## Findings

The public capacity and sector fields are 64-bit values in 512-byte units.
The storage command address is a 64-bit **byte** address. Checking
`sector + count <= capacity` alone is insufficient: the original backend
formed the address from `sector[54:0]`, silently discarding higher bits.
For example, an OUT to sector `2^55` with a sufficiently large capacity
reached address zero. A two-sector transfer starting at `2^55 - 1` crossed
the end of the byte-address space.

The existing integrated flash models expose small capacities, so those
profiles reject such requests at their capacity check. They did not
demonstrate the reusable backend's no-alias contract for its full input
width. This is a backend contract defect; no native small-model corruption
is inferred from the oversized-capacity reproducer.

The standalone request seam also did not reject a zero-byte status segment
or an oversized descriptor count before indexing the table. The ring already
rejects zero-length descriptors and bounds its segment count, but other
callers of the backend must not be able to cause a status DMA write outside
the supplied descriptors.

## Correction

- Reject counts below two or above `MaxSegs` before using the last index.
- Require a nonempty writable status segment before the first header DMA.
  Malformed tables produce the existing fault response without DMA, store
  or flush side effects.
- For IN/OUT, require a representable starting sector and an exclusive end
  no greater than `2^55`, as well as the existing capacity check. Invalid
  ranges complete with IOERR through the valid status descriptor and never
  issue storage commands.
- Keep the final legal sector usable. An exclusive end at `2^64` bytes
  is valid; the final issued beat starts at `2^64 - 8` and does not wrap.

No state, interface, feature bit, clock/reset, SRAM macro or latency stage
is added. These are corrections inside the existing optional block engine.
The constant-limit and descriptor checks feed the existing admission/check
states, rather than the data transfer path. Valid service timing is unchanged;
no measured throughput or technology STA improvement is claimed.

## Regression contract

The existing `vblk` stage now includes thirteen boundary cases: high-sector
IN/OUT aliases, IN/OUT crossing the byte-address limit, a sector-sum overflow,
successful last-sector OUT/IN with independent byte checks, zero-length
status, and counts 0/1/5/6/7 for the four-entry fixture. The sparse store
accepts full-width addresses, and its monitor checks sector bounds without
overflowing an `addr + 8` expression. `+boundary_only=N` permits an unchanged
case to be replayed against the frozen original RTL.

Existing random-grant/response, status, GET_ID, FLUSH, IOERR and device-reset
tests remain. The formal wrapper independently checks storage addresses and
the complete requested extent in 73-bit byte arithmetic, and asserts no
effects for structurally invalid tables. It observes the decoded header;
the simulation oracle separately builds and checks actual guest-memory bytes.
Bounded proofs do not establish physical media or arbitrary-length liveness.

The RAM/store response models now give each response and latency counter one
posedge owner; grants remain randomized at negedge. Responses remain stable
through the consuming edge, without the former mixed-edge drivers.

## Short formal proof with complete obligation accounting

Each mode prepares one RTLIL/JSON model. The runner inventories all twelve
original assertions, twenty supporting invariants and four original environment
assumptions, and checks the prepared-model SHA-256 before and after every query.
Source markers identify the reviewed property groups; missing, duplicated or
unrecognized obligations stop the gate.

The expensive DMA-window assertion is established by three dependent proofs:

1. All twenty metadata/ownership invariants hold at the initial reset frame.
2. They preserve themselves over one transition from arbitrary state, under
   the original environment assumptions. This induction query has **no**
   initial-state or reset restriction and assumes none of the twelve original
   safety assertions.
3. Only after both proofs pass, the window consequence may assume those
   invariants. Register outputs become arbitrary values; the original window
   predicate must hold in this larger, combinational state space.

Thus the window property is unbounded in the existing `MaxSegs=4` formal model,
including unrestricted 64-bit DMA base/size inputs under the original stability assumption.
This is stronger than its previous depth-14 check. The other eleven assertions
retain concrete depth 14. Status, response and enabled-FLUSH reachability use the
unmodified concrete model at depths 14/16/16; they do not assume the lemmas or
use cut points. These are reachability checks, not arbitrary-length liveness.

Preparation is capped at 60 seconds, each proof/cover at 30 seconds and the
whole formal stage at 180 seconds including preparation. Coverage is written
after each query. A timeout or unproved dependency stays incomplete; a known
counterexample remains failed even if another query times out. No failed
induction can authorize its dependent assumptions.

## Collected evidence

Frozen `storamic-all-920564dbf1c0` passes all **six selected stages** in about
130 seconds wall time:

| Stage | Result |
| --- | --- |
| `vblk` | 1,609 checks; corruption oracle rejects |
| `vblk-formal` | Complete proof/cover graph, 66.83 seconds |
| `vblk-flush-formal` | Complete proof/cover graph, 47.09 seconds |
| `vblk-synth` | 701 generic cells, zero latches/SCCs |
| `vdev` | 163 checks/543 DMA beats; corruption oracle rejects |
| `vdev-synth` | 1,432 generic cells, zero latches/SCCs |

All 119 packaged source/runner hashes match the current inputs and source-post
map. Both prepared models and both simulator PGO/profile-use builds have
verified identities. This invocation omits 62 other registered stages; the
collector lists them explicitly. Earlier checkpoint/writer results remain
their own historical receipts, not a fresh aggregate sweep.

Exact-final-fixture replay `storamic-boundary-original-bbf6f81d` rejects original
RTL at the named assertions for cases 1/2/3/4/8/13. Its reset base passes,
induction and concrete safety fail, and the dependent window consequence is
correctly not executed. Both concrete covers still pass. This is a rejecting
diagnostic, not a positive qualification of the original.

The earlier budgeted profile `storamic-all-dd0f95ae6aa0` remains incomplete:
25 queries passed and both range queries timed out. Its initial local GNU Make
preflight failure and superseded/interrupted experiments remain archived.
The completed profile uses the documented WSL remote proxy; no speculative
host-preflight or production datapath optimization was needed.

Receipts, manifests, logs and source inventories are under
`build-platform/workspace/build/storamic-review-30/`; see `FINAL-SV-30.md`.

## Readiness boundary

The existing asynchronous active-low reset, storage/DMA response ownership,
fault response and status observability remain the contract. No new
CPU ISA/CSR/RVFI/PMU event, DTS/PMA/PMP mapping or Linux feature advertisement
is introduced. RTL remains tier R and fixtures remain tier T under the
existing contributor/SPDX notices. Scan/ATPG, physical timing/power/ECC,
full aggregate/compliance and native/Linux qualification remain independent
completion gates.
