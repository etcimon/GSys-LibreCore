# `memory-model` — Vulkan memory model: message passing, write-after-read, transitivity, shared (17,300 cases)

Source: `specs/VK-GL-CTS` @ `f6a29701`; must-pass `vk-default/memory-model.txt`; tests in
`external/vulkancts/modules/vulkan/memory_model/vktMemoryModelTests.cpp`. Owner W3/W5
(ShaderCore ordering, caches). Gate CTS-3. The `core11` variants (318) are core at 1.1
(ordering through OpControlBarrier/OpMemoryBarrier and atomics); the `ext` variants
(16,192) need `vulkanMemoryModel` (1.2 core feature, must be supported at 1.2).

## Inventory

| prefix (`dEQP-VK.memory_model.`…) | cases |
|---|---:|
| `message_passing` (`core11` 159, `ext` 8096) | 8258 |
| `write_after_read` (`core11` 159, `ext` 8096) | 8255 |
| `transitive` (`coherent` 288, `noncoherent` 288) | 576 |
| `shared` (`8bit` 70, `16bit` 70) | 210 |
| **total** | 17300 |

## Architectural logic

```text
LOGIC MM-L1 · Release/acquire message passing across invocations, subgroups, workgroups, queue families
  CLAIM       A payload write followed by a flag write with release semantics (atomic
              store/RMW, or a barrier with the right scope/semantics) is observed by a
              reader that acquires the flag — for each scope (invocation, subgroup,
              workgroup, device/queue family), each storage class (StorageBuffer,
              Workgroup, Image), coherent and non-coherent decorations
              (MakeAvailable/MakeVisible), and both `core11` (barrier-based) and `ext`
              (OpMemoryModel Vulkan, scoped semantics) spellings.
  SOURCE      memory_model.message_passing.{core11,ext}.*, write_after_read.*,
              transitive.{coherent,noncoherent}.*.
  MECHANISM   Today: one shader core, one LSU, lane-serial accesses in program order,
              write-through to a flat memory → every access is globally ordered, so every
              release/acquire pair is trivially satisfied (the strongest legal model).
              The architecture must keep a stated ordering point per scope as it scales:
              W3.3 multiple LSUs/coalescing (per-lane program order preserved; cross-lane
              ordering only through atomics/barriers), W5.6 caches (MakeAvailable =
              write-back/flush at the scope, MakeVisible = invalidate; non-coherent
              accesses may be cached, coherent ones bypass or snoop), multiple cores
              (device-scope atomics serialized at L2).
  REQUIRES    The ordering-point map (RT-P2 identity precedes correlation): which
              structure orders which scope, written before the first parallel structure
              lands; `vulkanMemoryModel` advertised only with that map proven by this
              family at the new geometry.
  FORBIDS     Treating these tests as "passing by luck" after a parallel LSU — the
              family must be in the fails-if-removed set of every W3.3/W5 change
              (CTS-P3).
  CHECK       message_passing.core11.* now (CTS-1 sanity — they should pass trivially),
              the ext families at 1.2 (CTS-3), repeated at every scaling step.
  COST        the W5 coherence protocol; nothing today.
  FEEDS       SUBGROUPS-L*, SYNCHRONIZATION-L*, W5; CTS-3.
  STATUS      not-run

LOGIC MM-L2 · Shared-memory 8/16-bit accesses
  CLAIM       Workgroup memory accessed as 8-bit / 16-bit types (storageBuffer8/16BitAccess
              family + workgroupMemoryExplicitLayout) keeps byte-exact semantics under the
              memory model.
  SOURCE      memory_model.shared.{8bit,16bit}.*.
  MECHANISM   The slab port writes 32-bit words with byte enables (4a) — sub-word types
              need byte/halfword stores and sign/zero-extended loads (also GLSL-X1).
  REQUIRES    the 8/16-bit storage features (NotSupported until then).
  FORBIDS     read-modify-write emulation of byte stores that is not atomic w.r.t. other
              lanes' adjacent bytes (the slab is lane-serial today, so it is atomic; a
              parallel slab port must keep byte enables).
  CHECK       the family when the features land.
  COST        byte enables already exist.
  FEEDS       GLSL-X1; CTS-3.
  STATUS      not-run (NotSupported)
```

## Exceptions

```text
EXCEPTION MM-X1 · Features not advertised
  CONDITION   vulkanMemoryModel / vulkanMemoryModelDeviceScope (1.2), 8/16-bit storage.
  RESULT      NotSupported for ext.* and shared.*.
  TRUTH       profile lines; required at 1.2 (ladder).
  MECHANISM   Profile ROM.
  CHECK       ledger.
  FORBIDS     Advertising vulkanMemoryModel before the ordering-point map exists.
```

## Implementation-order heuristics

| Heuristic | Trigger | Priority | Smallest useful action | Reject / defer when |
|---|---|---:|---|---|
| MM-H1 Baseline the trivial case | CTS-1 | low cost, high value | run core11.* once on the serial engine — the frozen baseline for every scaling step (RT-P8: retain a baseline) | — |
| MM-H2 Ordering-point map | first parallel LSU design | precondition | the written map + this family as the control | — |

## Performance / area / scalability

This group is the correctness fence around every throughput feature: multiple LSUs,
caches, multiple cores. Knobs do not change the claim; the map does. The W5 Pareto
study must include the cost of the ordering points (flush/invalidate traffic, L2
serialization of device-scope atomics) measured with this family green.
