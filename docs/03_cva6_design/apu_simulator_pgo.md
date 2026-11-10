# APU Verification Model Provisioning

GSys LibreCore's selected APU testharness stages require both repository
Verilator compiler PGO and generated-simulator PGO. The offline workflow
automatically generates, instruments, trains and rebuilds a native simulator
with profile-use; missing prerequisites or receipts block instead of falling
back. Setup budgets are independent of short validation budgets.

Tests run on frozen source/tooling snapshots and immutable executable images,
concurrently with implementation in the mutable tree. Dev launches detach
and report INCOMPLETE until their tag is collected and validated. Training is
calibration, not test coverage; reduced CTS breadth does not reduce Vulkan's
baseline API contract.

The T2 verification model also provides resource-owned DMA leases: scoped
permissions, transactional mapping, stale capability rejection and context
teardown. It remains separate from legacy vector fixtures and is not a
complete native device backend or hardware protection implementation.

No functional RTL, timing cone, clock/reset/DFT/PMU path, ISA/DTS/config or
advertised Vulkan capability changes. Full aggregate, CTS, compliance/formal,
synthesis and physical qualification remain open. Current contracts, actual
infrastructure evidence and prepared test command:
`architecture/uncore/apu-simulator-pgo-implementation.md`.

The next host-state layer shares device-global DMA backing between contexts
while independently revoking their access. Context teardown does not free
backing; explicit resource unref invalidates all attachments. It does not yet
dispatch guest control messages or manage asynchronous work/aperture pins.
Focused frozen-source evidence and integration limits:
`architecture/uncore/apu-resource-lifetime-increment.md`.

Native control packets now reach that state through a bounded lifecycle
dispatcher and an explicitly authorized synchronous DMA queue adapter.
Reply capacity and all actual DMA accesses are validated before mutation.
Raw vring/MMIO, blob allocation and socket/IRQ execution remain separate.
Evidence: `architecture/uncore/apu-native-control-increment.md`.

The native control backend is now executable on local G6LC bridge IPC, with
blob-owned guest/private maps, raw direct split queues, MMIO/IRQ and resets.
It advertises zero Vulkan capsets until Venus execution and memory-backed
resources are integrated. Command, evidence and known RTL differences:
`architecture/uncore/apu-native-bridge-implementation.md`.

Native linear Venus and borrowed memory are now integrated and tested through
the real local bridge client. Short frozen runner:
`python3 -B verif/tb/apu/apu_native_verify.py --timeout 60`; --check is presence
only.73 host checks and11 byte-identical artifacts do not promote RTL/CTS or
simulator performance qualification.
`architecture/uncore/apu-native-linear-implementation.md`.

The same frozen runner now includes bounded native Venus rings:93 checks
pass4.745s with55 unchanged input hashes, including actual bridge polling,
parked-wait cancellation and reset. This is host-model lifecycle evidence,
not RTL/CTS or simulator performance qualification. PGO policy is unchanged.
`architecture/uncore/apu-native-ring-implementation.md`.

The native runner also covers continuation-backed linear/nested waits and
deferred control/used publication, with generation-pinned sources and reset/
cancellation. It remains a short frozen host-model lane, separate from
compiler/simulator PGO installation, training and RTL qualification.
`architecture/uncore/apu-native-continuation-implementation.md`.

Continuation receipt:109 checks pass6.868s,58 frozen hashes unchanged;
negative timeout is4/INCOMPLETE. Presence preflight performs no build/training.
This is host-model evidence, not a generated-simulator speed measurement.

The native dependency increment passes119 frozen checks in8.762s with60
unchanged hashes. Dependency ordering and parked-sibling progress are verified
in the host lane; compiler/simulator PGO requirements for RTL stay unchanged.
`architecture/uncore/apu-native-dependency-implementation.md`.

The internal transfer executor uses the same frozen host lane:133 checks
pass7.101s including14 ownership/budget cases. This does not enable wire GPU
submission or establish simulator throughput; RTL compiler/simulator PGO,
unrolling and isolated snapshot requirements remain unchanged.
`architecture/uncore/apu-native-transfer-implementation.md`.

Transfer command-buffer replay adds13 directed checks in the frozen host lane:
146 pass10.797s with64 unchanged hashes. Presence checks perform no tool
installation/build/training; compiler and simulator PGO/unroll policy for RTL
remains unchanged. These are not simulator throughput or wire-GPU evidence.
`architecture/uncore/apu-native-replay-implementation.md`.

Opt-in transfer submission runs159 frozen host checks in8.150s with66 unchanged
hashes. The real IPC diagnostic does not imply RTL execution, stock Vulkan
admission or simulator throughput. Default-PGO presence checks do not build,
install or train; compiler/simulator PGO and unroll policy remains unchanged.
`architecture/uncore/apu-native-submit-implementation.md`.

Binary semaphore scheduling uses170 frozen host checks in14.423s;68 hashes
remain unchanged. Native/PGO presence performs no installation/build/training.
These timings are not simulator throughput; RTL compiler/simulator PGO and
unroll requirements remain unchanged.
`architecture/uncore/apu-native-binary-semaphore-implementation.md`.

Timeline host APIs use182 frozen host checks in12.467s with70 unchanged hashes.
Native-only decoder expansion does not change the pinned RTL command/profile
files. Presence does not install/build/train; compiler/simulator PGO and unroll
policy is unchanged. No queue-timeline or simulator-throughput claim.
`architecture/uncore/apu-native-timeline-host-implementation.md`.

Queued timeline diagnostics run197 frozen host checks in14.198s with74 unchanged
hashes. The runner freezes itself and refuses warning/unraisable false passes;
timeout remains INCOMPLETE/4. Presence does not install/build/train. Pinned RTL
decoder and compiler/simulator PGO/unroll policy remain unchanged.
`architecture/uncore/apu-native-timeline-queue-implementation.md`.

Image region replay uses210 frozen host checks in12.023s with76 unchanged
hashes. Presence checks perform no installation/build/training. Host row-copy
durations are not simulator throughput; pinned RTL decoder and compiler/
simulator PGO/unroll policy remain unchanged.
`architecture/uncore/apu-native-image-copy-implementation.md`.

Native coherent barriers run220 frozen host checks in13.371s with78 unchanged
hashes. Typed zero-byte work retains backing; no physical cache conversion is
claimed. Presence does not install/build/train; hardware decoder and compiler/
simulator PGO/unroll policy remain unchanged.
`architecture/uncore/apu-native-image-barrier-implementation.md`.

Native color clears run230 frozen host checks in30.925s with79 unchanged hashes.
Small texel patterns and record-local payload bounds do not change RTL packed
records or establish simulator throughput. Presence does not install/build/train;
compiler/simulator PGO and unroll policy remain unchanged.
`architecture/uncore/apu-native-image-clear-implementation.md`.

Internal compute runs241 frozen host checks in13.845s with81 unchanged hashes.
Live-memory reference instruction turns do not establish wire shader or RTL
throughput. Presence does not install/build/train; PGO/unroll policy stays.
`architecture/uncore/apu-native-compute-foundation.md`.

Native descriptor provenance runs254 frozen host checks in16.214s with83 hashes
unchanged. Host-only metadata preserves32-byte hardware records; no wire shader
or simulator-throughput evidence. Native/default-PGO presence is no-build.
`architecture/uncore/apu-native-buffer-descriptor-implementation.md`.

Native layout snapshots run267 frozen host checks in13.820s with85 hashes
unchanged. By-value metadata preserves hardware record/hash ABI; no wire shader/
RTL throughput evidence. Presence remains no-build and PGO policy unchanged.
`architecture/uncore/apu-native-layout-lifetime-implementation.md`.

Native pipeline snapshots:274 frozen checks18.256s,87 hashes unchanged.
Bounded decoder trace validation does not change ROM or establish RTL/PGO
throughput. Presence remains no-build.
`architecture/uncore/apu-native-pipeline-implementation.md`.

Internal compute replay:299 frozen checks16.776s,89 hashes unchanged. Tests
snapshot recording/lease/runtime inputs; host-model progress is not RTL/PGO
throughput or stock admission. Presence remains no-build.
`architecture/uncore/apu-native-compute-replay-implementation.md`.

Diagnostic compute wire:310 frozen host checks18.933s,90 hashes unchanged.
Real local-IPC client/native-process validation is not an RTL/PGO throughput
receipt. Presence no-build and independent qualification policies remain.
`architecture/uncore/apu-native-compute-submit-implementation.md`.

Scalar specialization:325 frozen host checks16.343s,92 hashes unchanged.
Bounded immutable snapshots and scanner regressions are not RTL/PGO throughput
or qualification evidence. Presence remains no-build.
`architecture/uncore/apu-native-specialization-implementation.md`.

Native compute barriers:338 frozen host checks16.120s,93 hashes unchanged.
Private decoder keeps and executor ordering do not establish hardware/PGO
throughput or qualification. Presence remains no-build.
`architecture/uncore/apu-native-compute-barrier-implementation.md`.

Native idle scope:348 frozen host checks15.110s,94 hashes unchanged. Owned-lane
scans retain the128-job bound; no new poll thread or RTL/PGO performance claim.
`architecture/uncore/apu-native-idle-scope-implementation.md`.

Native indirect compute:364 frozen host checks14.006s,95 hashes unchanged.
Deferred12-byte parameter reads charge the bounded poll budget; no hardware/
PGO throughput or qualification promotion. Presence remains no-build.
`architecture/uncore/apu-native-indirect-dispatch-implementation.md`.

Native fixed buffer arrays:374 frozen host checks17.179s,96 hashes unchanged.
Existing16-row/65536-byte bounds remain; reference LSU permission checks do not
establish RTL or PGO throughput. Presence remains no-build.
`architecture/uncore/apu-native-buffer-array-implementation.md`.

Native specialization operations:382 frozen host checks17.971s,96 hashes
unchanged. Default hardware scanner refusal remains; no RTL or PGO throughput
promotion. Presence remains no-build.
`architecture/uncore/apu-native-specialization-op-implementation.md`.

Native image operands:398 frozen host checks19.826s,98 hashes unchanged.
Typed provenance and owned-subview validation do not establish shader-image
execution or RTL/PGO throughput. Presence remains no-build.
`architecture/uncore/apu-native-image-operand-implementation.md`.

Native compute images:408 frozen host checks18.899s,99 hashes unchanged.
Live image I/O retains existing executor bounds; reference sampler-kind repair
does not establish RTL/PGO throughput or qualification. Presence stays no-build.
`architecture/uncore/apu-native-compute-image-implementation.md`.

Native shader-image barriers:417 frozen host checks15.207s,100 hashes unchanged.
Coherent zero-byte barriers retain leases without layout/cache conversion.
No RTL/PGO throughput or qualification promotion; presence stays no-build.
`architecture/uncore/apu-native-shader-image-barrier-implementation.md`.

Native rendering identity:432 frozen host checks14.597s,102 hashes unchanged.
By-value metadata and owned-span resolution neither pin nor draw. No RTL/PGO
throughput or qualification promotion; presence stays no-build.
`architecture/uncore/apu-native-rendering-identity-implementation.md`.

Native graphics identity:442 frozen host checks37.769s,104 hashes unchanged.
Stage/state provenance does not establish draw or RTL/PGO throughput. Presence
stays no-build and compiler/simulator PGO evidence remains separate.
`architecture/uncore/apu-native-graphics-identity-implementation.md`.

Native graphics fixed state:450 frozen host checks21.578s,106 hashes unchanged.
Original-wire validation is not draw execution or RTL/PGO throughput evidence;
presence stays no-build.
`architecture/uncore/apu-native-graphics-fixed-state-implementation.md`.

Native graphics interfaces:462 frozen host checks36.223s,108 hashes unchanged.
Existing specialized scans supply bounded declarations without draw or RTL/PGO
throughput evidence; presence stays no-build.
`architecture/uncore/apu-native-graphics-interface-implementation.md`.

Native vertex/index operands:474 frozen host checks33.942s,110 hashes unchanged.
Metadata/owned-span resolution is not vertex execution or RTL/PGO throughput;
presence stays no-build.
`architecture/uncore/apu-native-vertex-operand-implementation.md`.

Native dynamic viewport/scissor:483 frozen host checks21.050s,112 hashes unchanged.
Immutable bounded metadata is not raster execution or RTL/PGO throughput;
presence stays no-build.
`architecture/uncore/apu-native-graphics-dynamic-implementation.md`.

Native render-pass commands:499 frozen host checks29.179s,114 hashes unchanged.
Metadata and owned operands execute no clears/draws and provide no RTL/PGO
throughput evidence; presence stays no-build.
`architecture/uncore/apu-native-render-pass-command-implementation.md`.

Native graphics resource requirements:516 frozen host checks27.683s,116 hashes
unchanged. Declaration/layout metadata is not shader/draw execution or RTL/PGO
throughput evidence; presence stays no-build.
`architecture/uncore/apu-native-graphics-resource-implementation.md`.

Native graphics binding state:536 frozen host checks31.259s,118 hashes unchanged.
Descriptor-header validation and owned operands are not shader/draw execution
or RTL/PGO throughput evidence; presence stays no-build.
`architecture/uncore/apu-native-graphics-binding-implementation.md`.

Native graphics draw plans:553 frozen host checks17.947s,120 hashes unchanged.
Nonexecuting plan composition is not fetch/raster execution or RTL/PGO
throughput evidence; presence stays no-build.
`architecture/uncore/apu-native-graphics-draw-implementation.md`.

Native render-pass clears:569 frozen host checks22.433s, all hashes unchanged.
Bounded attachment-clear writes are not draw/shader execution or RTL/PGO
throughput evidence; presence stays no-build.
`architecture/uncore/apu-native-render-pass-clear-implementation.md`.
