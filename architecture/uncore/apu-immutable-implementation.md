# Immutable Sampler Implementation Work Record

The bounded layout/descriptor state path is implemented. No full qualification
or CTS closure is claimed.

## Representation

- Profile keeps `pBindings.pImmutableSamplers`. Only for this kept handle array
  the decoder generator emits ARRAY(count KEEP), HANDLE(KEEP), ENDARR.
  A staged layout binding is five words (binding/type/count/stage/immutable
  count), then two words per immutable sampler handle.
- A layout with immutable arrays allocates one ObjPay extent containing the
  existing two-word canonical rows, one relative pointer per row, and packed
  64-bit sampler snapshots. Header bit31 marks the trailer, header low16 is
  binding count. Row bit10 marks immutable state. Normal layout sizes stay
  unchanged. Retirement frees the single original extent via aux.
- `vnfront` resolves each sampler at layout creation and snapshots its aux.
  The existing content hash includes snapshot words and immutable row bits.
  Header-based binding-count reads replace extent-size-derived counts.
- Set allocation zeros records then initializes immutable sampler payloads;
  standalone SAMPLER records are valid immediately, combined descriptors
  remain invalid until image state is written.
- Immutable SAMPLER writes are ignored. Combined descriptor writes preserve
  bytes20..27 while updating image/view/memory state. Copies preserve these
  destination bytes too; standalone immutable destination samplers are kept.

## Focused Evidence

The matching golden model and canonical row helper are updated. Decoder
selftest passes 596 checks; 23 Python tests pass, including immutable-array
boundary checks. Generator reports 149 commands, zero unfit. Full cheap
`regen_vectors.sh` generation completes; this is not regression execution.

Repository-built Verilator 5.008 build passes with assertions and warnings
fatal (existing targeted waivers retained), debug printing disabled:

| Selected vgtop fixture | Checks | Cycles |
|---|---:|---:|
| `ue_cpos_imm_texlod_1` | 1,459 | 457,494 |
| `ue_cpos_imm_copy_1` | 1,399 | 459,343 |
| `ue_cpos_imm_array_1` | 1,715 | 458,947 |
| `ue_cpos_dslcompat_1` | 878 | 441,329 |
| `ue_cneg_layoutmix_1` (expected DEVICE_LOST) | 686 | 438,894 |
| `ue_gpos_fsubocopy_1` | 17,088 | 591,595 |

The three immutable fixtures also pass with `mp_lat_min=1`, `mp_lat_max=20`,
`mp_ready_pct=60`: respectively 1,839,934 / 1,845,126 / 1,843,385 cycles,
with the same check counts. Reproduce the small cohort with
`bash verif/tb/apu/run-apu-dev.sh --immutable [--jitter]` (omit the brackets
and optional flag for fixed latency). The three fixtures are also registered
in the full vgtop runner; that full runner was not executed in this pass.

`immutable` fixtures use NULL sampler writes for combined descriptors and add
an unused standalone two-element sampler array at binding 65535 with no writes.
Explicit aperture checks verify both sampler words and standalone validity.
`immutable_copy` allocates a mutable source layout, writes a different sampler
there, copies to the immutable destination, and checks destination sampler words
against the original shader-vector parameters before shader consumption.

The first development attempt counted all kept handle arrays and disturbed
unrelated payload formats. This was corrected at the generator boundary, not
worked around in consumers. The final build uses the restricted capture rule.
Debug build support also exposed obsolete done-queue trace signal names; only
their simulation-only trace references were corrected.

Logs, compiler identity and final input hashes:
`$HOME/.cache/librecore/apu/vgtop/`. The configured aggregate dry run plans
25 steps, executes none, and reports missing managed-simulator patches.
No shared cleanup, remote execution or aggregate PASS is claimed.

## Remaining Review And Validation

- Exercise negative allocation, invalid sampler cleanup, metadata-read faults,
  payload exhaustion, and extended reset/reuse/lifetime sequences. Initialization
  read failures now retire the unpublished set, return UNKNOWN and null its
  result; a failed free-list reservation is reclaimed with the pool rather
  than transactionally restored. That exceptional path is not yet validated.
- Full compatibility hashing still has pre-existing limitations (stage flags
  and complete creation identity); snapshot equality is not a full Vulkan
  identical-definition proof. No new extension or capability is advertised.
- T2 and aggregate/formal/synthesis/physical qualification remain open.

## SoC And Licensing Notes

This corrects existing behavior under `ApuCfg.VenusEn` / frontend `Enable`;
it adds no device feature toggle, ISA/CSR, DTS property, clock or reset.
Control stays serial on existing ObjTab, ObjPay and aperture handshakes.
New scalar control state uses the existing asynchronous-active-low reset.
Snapshots consume existing ObjPay SRAM through its macro boundary: a layout
with N rows and S immutable elements uses `1 + 3*N + 2*S` words; without
immutable elements it retains `1 + 2*N`. No new raw memory array or port.
Creation adds bounded sampler lookups and two writes/element; set allocation
adds two reads and three masked aperture writes/element. Added switching and
latency require synthesis/physical measurement; no area/Fmax claim is made.

Existing scan/clock-gating boundaries are unchanged; new state needs downstream
scan insertion/ATPG. Existing transaction traces, busy and fault/reply paths
provide observability; no new PMU event is claimed. New assertions bound
snapshot writes and descriptor initialization addresses. No proof run is
claimed. RISC-V ISA/spec/profile statuses and device discovery stay unchanged.

Scoped source-header/tier checks follow `.licensing-tiers`, preserve existing
R dual licenses and T MIT headers, and retain contributor attribution. Tier-R
authorization is recorded in `AGENTS-todo.md:8714`; no signed CLA is inferred.
The documented `diag run licensing` command reports Unknown on this checkout;
the scoped header audit is not a substitute claim for that unavailable command.
