# r96 — Window contracts and deferred cache audits

These requirements accompany the module cards. They specify what a proposed
cut must establish, rather than claiming a new stage or capacity is implemented.
Let D be dependency latency, F forwarding/feedback latency, O ordering or
permission latency, and P publication/service latency.

| Strategy family | D / F / O / P requirement | Capacity and collision obligation |
|---|---|---|
| FLU, PMP, LSQ and MSHR exact restructuring | All four deltas are zero; preserve same-edge decisions | Existing credits and reservations remain authoritative. FLU retains `1 + ooo_flu_cycles`; MSHR allocation and returned index remain one event. |
| FMA preparation in existing exp/middle windows | All four deltas zero only if every result/control alternative retains its current edge distance | Determine actual latency from expanded valid/register paths, not NumPipeRegs alone. Retain every occupied stage under stall and propagate backpressure before acceptance. |
| Floating-dot group rebalance | All four deltas zero; initiation interval stays one | Existing latency is `ceil(log2(Lanes))+5`: 14 edges at 512 lanes. A full-rate stream therefore needs 14 in-flight token positions, plus any downstream retained records. Changing group size must not change that lifetime. |
| Descriptor span preparation | Descriptor publication waits for all three owned span completions | Keep each product/tail/overflow record until its result is consumed; do not advance a done bit before its corresponding span. Account for queued descriptors separately from the currently evaluated owner. |
| GEMM terminal-fact simplification | No early ordering or completion; any additional terminal bubble must be stated | Compute, C-memory update and AXI store-response lifetimes are separate. Last compute output alone cannot release a job with outstanding memory responses. |
| Optional extra normalization/arithmetic stage | D and P increase by the actual added edges; F increases unless a valid bypass exists | For peak accepted rate lambda and bounded lifetime T, provision at least `ceil(lambda*T)` token slots. Include downstream hold/merge state and completion-port reservations; interleaved accumulator owners must cover any longer recurrence. |
| Cache collector/state-only summary | No added response or admission cycle | Summary must track the same owner across simultaneous pop, fill completion and allocation. Registered SRAM row availability and launch-cycle forwarding remain unchanged. |
| Optional APB/cache/coherence publication stage | P changes; O changes if completion grants permission or visibility | Reserve an entire request/response owner before ACK. AXI payload remains stable under stall. Invalidation enqueue is distinct from applied acknowledgement. |

`ceil(lambda*T)` is a lower bound for a bounded stream, not a solution for
unbounded downstream stalls. A finite elastic window must refuse further
acceptance when full. Include already accepted work in every credit query.
An unbackpressured result requires a guaranteed sink reservation at its return
cycle; a late result-ready signal cannot repair an earlier over-accept.

For every new boundary, the tuple includes valid, operation, identity and
generation, data representation, exception/status, hart/context, cancellation
and all reconverging alternatives. Reset clears ownership consistently with
the existing asynchronous-active-low strategy. Accepted memory writes drain
according to protocol; speculative flush must not silently erase them.

SRAM ports are resources, not abstract stages. Preserve tag read launch,
registered row-valid, forwarding age and read/write conflict rules. Before a
GEMM accumulator cut, account for C-read return and C-write availability and
for simultaneous load/compute/store completion. Changing D without these
reservations can reduce a local FO4 row while reducing throughput or losing work.

## Deferred H95-hpdcache_ctrl_pe audit

The raw core-all maximum is 75.85 FO4; `hpdcache_ctrl.sv` is the direct caller.
The scalar Hyp configuration selects the WT cache subsystem, so this is not
an active scalar execution-path target.

- [ ] Identify a supported Hyp configuration whose subsystem selects HPDCACHE.
- [ ] Bind its HPDcacheCfg/requester/cache geometry and enumerate the connected
  request-admission, replay and response paths with observable sinks.
- [ ] Compare parallel request eligibility and retained response publication
  against the cache-separation strategy, preserving the selected cache's own
  replay/AMO/maintenance priority. Do not import L2's protocol or add a register
  to a same-edge grant without a retained request and resource reservation.

No RTL reduction is proposed before those activation and ownership conditions
are established. Preserve the upstream file's licensing and attribution.

## Deferred H95-hpdcache_mshr audit

The raw core-all maximum is 56.55 FO4; `hpdcache_miss_handler.sv` is the caller.
It has the same scalar-profile exclusion as ctrl_pe.

- [ ] Bind the active configuration's sets, ways, entries and miss-handler ports.
- [ ] Trace the chosen allocation/lookup/retirement result through its caller,
  including same-cycle collision and backpressure behavior.
- [ ] Evaluate independent match/free eligibility and row-local updates only
  after resolving banked storage and memory-port availability. A135 and the
  L2 MSHR task provide hypotheses, not equivalence between the two designs.

Both audit tasks remain in the 223-entry H95 queue; they complement the 31
detailed H96 module cards rather than inflating the active timing ranking.
