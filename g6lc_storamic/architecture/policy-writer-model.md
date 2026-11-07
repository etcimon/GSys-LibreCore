# Policy And Real Writer Composition

## Implementation Boundary

`corev_apu/storamic/g6lc_storamic_policy_writer_model.sv` composes the existing
policy manager with the default-off checkpoint/VirtIO/DMA writer model. It
does not instantiate native authority, rewrite native attach refusal or
manufacture CPU/cache/fabric/provider/resume acknowledgements.

The type-injected policy payload is opaque platform-owned state, not an
unlock key or a qualified immutable native descriptor. Authorization and
module identity/mapping/reset-generation facts remain external. This is a
C3/C4 orchestration step, not closure of either native gate.

The policy manager binds:
- actual writer job/DMA quiescence AND the separate MMIO control seal;
- actual endpoint/producer/DMA ownership, including dirty staging and results;
- external upstream presence, queue hold and pause acknowledgement;
- external route/maintenance ownership and five provider readiness facts.

Policy quiesce stops new writer work and seals device MMIO independently.
The old policy/epoch remain active while accepted jobs, checkpoint flush/save,
held results, late AW/W partners and B/R responses retire. Command admission
stops separately: an already admitted checkpoint remains authorized under its
old epoch while a pending replacement waits for ownership to clear.

No automatic flush is invented. A dirty store can retain policy ownership
indefinitely unless a real checkpoint/flush was admitted first or platform
maintenance can drain it. A pending policy is not permission to discard data.

## Inactive Configuration

Model geometry, layout, timeout and injected shapes must match the existing
writer contract before the policy manager is active. An invalid writer must
not expose policy update admission. The native/default-off configuration is
unchanged; no new ISA/CSR/discovery/DTS/PMA/PMP/Linux ABI is introduced.

Disabled policy pending/revoked/exhausted outputs are now structural zeros,
matching the existing inactive policy/epoch output guards. The first new off
proof exposed pending lowered to X from reset-only inactive state. The explicit
static guard removes that representation dependency without changing enabled
policy state transitions; it is not a general compiler-lowering qualification.

## Regression Method And Diagnostic History

The first simulation paused during ring descriptor fetching, before storage
handoff (`sr=0`, backend idle). Used/status remained unchanged. The corrected
admission point observes the real writer storage request, as the earlier
writer composition fixture does; completion assertions are unchanged.

The second simulation reaches the accepted OUT completion and checkpoint
result/epoch checks, then stalls after provider loss with the guest device
still active. Provider ABA is not permission to erase that device/AXI owner.
The new cases separate a genuinely reset/drained guest device from an active
one requiring explicit common-domain reset/rediscovery. The failed run remains
failed; automatic active-device recovery is not inferred.

Five profiles are registered: response delays0/4/16, disabled refusal and
active-provider-loss/common-reset recovery. They retain rejecting oracles.
New formal checks cover disabled/illegal refusal, denied held/read responses
and a negative oracle; enabled policy state safety remains a separate existing
proof. Final `storamic-all-518de1685e41` passes all ten selected stages with
matching source-post hashes: all five profiles/oracles, five new formal
queries, active manager checks, legacy writer save/restore/reset, endpoint
formal and DMA ownership regressions.

Two exact-final-fixture wiring mutants reject at the intended assertions:
`drop-endpoint-hold-9114267f` publishes over the held checkpoint result;
`forge-upstream-ack-32484c62` publishes before external upstream ACK. Both
negative source-post identities match. All 113 packaged code/runner files
match current sources; the separate host-unit hash makes 114 head files.
Twenty-two generated-simulator builds train rc0, rebuild profile-use and
verify frozen repository compiler-PGO/unroll runtime identities. Repository
`tools/yosys` is used. Training and failed diagnostics are not qualification.

The delay16 fixture initially checked total drain immediately after MMIO R
retired; a real accepted DMA poll was still outstanding. It now waits both
actual owners before the unchanged assertion. Disabled compilation also
exposed diagnostic-only gen_model references; debug prints now use public
signals. Neither correction changes assertions, budgets or production RTL.
Local 114 Python, seven platform, typecheck, lint4 and source/license108 pass.
Full compact receipts: `policy-final-27.json`/`FINAL-SV-27.md` in the
contained storamic-policy-19 build workspace.

## SoC Readiness Review

The new wrapper adds no independent state, array, clock, reset or pipeline stage:
the composition includes the existing manager's policy/epoch/flag registers
and writer under their common clock/asynchronous active-
low reset. Type injection and testmode/SRAM seams are preserved. Policy
commit/revoke/reject/exhaust and existing checkpoint events remain observable;
no CPU PMU/RVFI feature is introduced.

Policy readiness/admission and registered-state quiesce feed existing control
gates. All-drained affects registered publication, not combinational quiesce,
so there is no ready/valid feedback. Generic synthesis is 3156 active cells
(writer3085 +71), four existing model memories; off/invalid93/no memories.
All have zero latches/SCCs. Technology timing/power, scan/ATPG, default native
netlist and aggregate/compliance remain separate open gates.

See [native-provider-inventory.md](native-provider-inventory.md) for actual
topology/owner/provider gaps. Neither this composition nor common model reset
qualifies physical power failure, native hot replacement or Linux recovery.
