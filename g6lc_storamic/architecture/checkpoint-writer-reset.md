# Checkpoint Writer Reset And Recovery

## Contract

This extends the default-off non-hyp8 writer model's C4/C5 component evidence,
not native admission. A reset during an accepted job must not become a
successful checkpoint or fabricated used/status completion. The real writer
error must reach the coordinator. The prior durable checkpoint must remain
selected, and an explicit restore must wait for externally established resume
safety before releasing RAM.

Implementation is the `ResetDuringSave` profile in
`verif/tb/storamic/tb_g6lc_storamic_checkpoint_writer.sv`; registration is
`checkpoint-writer-reset` in the leaf/remote runners. No new product parameter,
native configuration, ISA/discovery, PMA/PMP, DTS or Linux capability is added.
The existing `storamic_cfg_t`/ProfileModel guard and structural type seams
remain unchanged.

## Real Reset Scenario

1. Initialize guest RAM over upstream AXI, configure modern VirtIO-MMIO, complete
   a real 512-byte OUT and save generation 1 through actual flush/publication.
2. Start a second real OUT with different guest payload, wait for writer/store
   activity, and submit save cookie 12 while the job owns work.
3. Write Status=0 through actual device MMIO while checkpoint producer pause is
   asserted. The fixture does not drive the producer-error input.
4. Require `CP_PRODUCER_ERROR`, exactly one coordinator error and no added done
   event. Device reset and accepted DMA/store work retire through their engines.
   The fixture acknowledges upstream only with no request or DMA bridge debt.
5. Verify generation 1 and valid metadata remain, used index stays 1, and the
   canceled job's status byte stays the initial sentinel.
6. Request explicit restore cookie 13. Wait for the actual CSync phase, then
   hold external resume permission low for 500 cycles. RAM stays sealed and
   the operation stays owned. Observe device Status=0, real writer pause,
   no device/DMA ownership and no upstream request before granting resume.
7. Verify all 64 guest payload words come from the prior image. Since device
   reset erased internal queue indices, rebuild both guest rings and configure
   the driver again before issuing IN. Require successful status and used index
   restarting at 1.

Reset cancels the accepted job; it does not promise completion of that canceled
job or atomic rollback of its partial ordinary block writes. The test does not
pretend otherwise. It protects checkpoint publication and explicitly
resynchronizes the device instead of silently treating a reset queue as an
unchanged live queue.

## Verification Status

The first directed snapshot `storamic-all-ffa49212e5f1` passes all response
delay 0/4/16 cases. The strengthened snapshot `storamic-all-208113170860`
passes all eleven selected stages, including the six unchanged baseline
profiles and three reset profiles (3816/4693/7325 checks). Every simulation
retains its rejecting plusarg oracle. The reset profiles now hold at CSync
after real copy completion and verify every guest payload word.

The independent follow-up `storamic-all-3eb75e609eb6` repeats all three reset
profiles and the original coordinator safety (depth 16), save/restore/error
covers (20/32/12) and rejecting oracle (16). Assumptions and depths are
unchanged. Both snapshots have matching source-post hashes and all 108
packaged repository/runner files match the current source closure.
The 112 local Python tests, seven platform checks, typechecking, four configured
lint steps and 99-file scoped licensing/source audit also pass.

Two isolated hardware mutants use exactly the positive fixture/runner:
dropping the actual writer error and tying resume safety high. They fail
`real-writer-reset-error-reaches-checkpoint` and
`reset-resume-provider-still-external`, respectively. Failed mutant stages are
negative-oracle evidence, never positive stage passes.
The mutant tags are `storamic-reset-mutant-error-61b79088` and
`storamic-reset-mutant-resume-632ba9b3`; source-post identities match and
neither fixture nor runner is modified in these negative snapshots.

Repository `tools/verilator` compiler PGO/unroll and `tools/yosys` remain
frozen. All twelve collected simulator builds (nine main, three follow-up)
train successfully, rebuild with profile-use and verify runtime identity.
Training is never final qualification. Compact receipts are
`reset-final-25.json` and `FINAL-SV-25.md` under the contained
`storamic-policy-19` build workspace.

The baseline six writer profiles remain unchanged and independently selected.
A host test executes actual runner setup for baseline-only, reset-only and
combined selections, requiring 6/3/9 unique cases and preserving rejecting
oracles. Early host-test attempts selected the unrelated ordinary-model AST
block; those failures remain archived and the selector is explicitly scoped
to the reset-capable checkpoint block.

## Readiness Review

No production RTL correction follows from the passing reset trace. This pass
adds verification, registration and observation of existing done/error events,
not a speculative new latch, state machine or timing workaround. There is no
new hardware combinational path, clock/reset, memory, gating or power domain.
Existing SRAM/testmode boundaries, generic synthesis counts and cold ownership
reductions are rechecked in the selected matrix; no technology PPA/8-FO4/5-GHz
or scan/ATPG qualification is inferred.
Generic active synthesis remains 3044 cells/four SRAM-model memories;
off/invalid layout remain 93 cells/no memories, all zero latches/SCCs.

This is same-clock uncached-model behavior with fixture-owned upstream idle
and resume acknowledgements. It is not a CPU/cache/reservation synchronization
provider, complete native writer inventory, power-cut recovery, physical flash
durability, automatic device-state checkpoint, Linux/VirtIO conformance or
aggregate/compliance/default-netlist qualification. Those completion-plan gates
remain open regardless of these directed successes.
