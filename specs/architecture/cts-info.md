# `info` — platform/device self-validation (21 cases)

Source: `specs/VK-GL-CTS` @ `f6a29701` (`vulkan-cts-1.4.6.2`); must-pass
`external/vulkancts/mustpass/main/vk-default/info.txt`; tests in
`external/vulkancts/modules/vulkan/vktInfoTests.cpp` (and `api/vktApiFeatureInfo.cpp`
for the device/instance dumps they reuse). Owner W0 (profile truthfulness). Gate CTS-0.

## Inventory (rendered by `cts_ledger.py tree --group info`)

| prefix (`dEQP-VK.`…) | cases |
|---|---:|
| `info` | 21 |
| &nbsp;&nbsp;`info.build` | 1 |
| &nbsp;&nbsp;`info.device` | 1 |
| &nbsp;&nbsp;`info.device_extension_dependencies` | 1 |
| &nbsp;&nbsp;`info.device_extensions` | 1 |
| &nbsp;&nbsp;`info.device_features` | 1 |
| &nbsp;&nbsp;`info.device_group_peer_memory_features` | 1 |
| &nbsp;&nbsp;`info.device_layers` | 1 |
| &nbsp;&nbsp;`info.device_mandatory_features` | 1 |
| &nbsp;&nbsp;`info.device_memory_budget` | 1 |
| &nbsp;&nbsp;`info.device_memory_properties` | 1 |
| &nbsp;&nbsp;`info.device_no_khx_extensions` | 1 |
| &nbsp;&nbsp;`info.device_properties` | 1 |
| &nbsp;&nbsp;`info.device_queue_family_properties` | 1 |
| &nbsp;&nbsp;`info.instance_extension_dependencies` | 1 |
| &nbsp;&nbsp;`info.instance_extension_device_functions` | 1 |
| &nbsp;&nbsp;`info.instance_extensions` | 1 |
| &nbsp;&nbsp;`info.instance_layers` | 1 |
| &nbsp;&nbsp;`info.memory_limits` | 1 |
| &nbsp;&nbsp;`info.physical_device_groups` | 1 |
| &nbsp;&nbsp;`info.physical_devices` | 1 |
| &nbsp;&nbsp;`info.platform` | 1 |
| **total** | 21 |

## Architectural logic

```text
LOGIC INFO-L1 · The enumerated device is a consistent, spec-legal object
  CLAIM       Properties, features, limits, memory heaps/types, queue families and the
              extension list returned for the physical device are mutually consistent and
              satisfy every normative minimum of the advertised apiVersion (Vulkan spec
              "Limit Requirements", "Feature Requirements", "Required Format Support").
  SOURCE      dEQP-VK.info.device_{properties,features,memory_properties,
              queue_family_properties,extensions,extension_dependencies,
              mandatory_features,no_khx_extensions}, info.memory_limits,
              info.instance_*; vktInfoTests.cpp / api/vktApiFeatureInfo.cpp.
  MECHANISM   The guest sees Mesa Venus's view of our renderer: vn_device_profile.toml →
              gen_vn_tables.py → the profile ROM words that g6lc_apu_vnrep returns for
              vkGetPhysicalDevice{Properties,Features,MemoryProperties,
              QueueFamilyProperties,FormatProperties,ImageFormatProperties}(2) and
              vkEnumerateDeviceExtensionProperties. Venus adds/strips nothing except
              what vn_physical_device.c allow-lists, so the hardware profile IS the
              enumerated device.
  REQUIRES    The W1 requirement ledger: every advertised feature/extension has a
              mechanism; every limit ≥ the version's minimum; extension dependencies
              satisfied (an advertised KHR extension pulls its dependencies in).
  FORBIDS     Raising a limit or feature bit to satisfy an admission check without the
              mechanism (CTS-P1); an extension string without its entry points.
  CHECK       dEQP-VK.info.* (21 cases, caselist cts0-info-smoke.txt); the read-only
              audit `gen_vn_tables.py --audit-profile` (7 intentional findings remain at
              G2 — each must be either fixed or shown to be outside the 1.1 minima).
  COST        None in hardware (ROM words); the cost is honesty about the version.
  FEEDS       Every other file (their NotSupported exceptions quote this profile); CTS-0.
  STATUS      not-run (CTS-0 pending)

LOGIC INFO-L2 · Mandatory features follow the advertised version
  CLAIM       For the advertised apiVersion and each enabled extension, the features the
              spec marks "must be supported" are reported true (CTS generates the table
              from the registry: vkMandatoryFeatures.inl).
  SOURCE      dEQP-VK.info.device_mandatory_features.
  MECHANISM   Profile `[features]` + the Vulkan11/12/13/14Features structures the
              renderer answers through vkGetPhysicalDeviceFeatures2 (ROM).
  REQUIRES    HYPOTHESIS to be settled by CTS-0: at apiVersion 1.1 the registry marks at
              least `multiview` (VkPhysicalDeviceMultiviewFeatures) mandatory; we do not
              implement multiview. Either outcome is architecture: implement multiview
              (W8 card MULTIVIEW-L1) or advertise 1.0 until it exists. Advertising a
              version whose mandatory feature is missing is not an option.
  FORBIDS     Setting a mandatory feature bit without its mechanism to pass this test.
  CHECK       dEQP-VK.info.device_mandatory_features; then dEQP-VK.multiview.* when the
              bit is true.
  COST        Decides the version ladder: 1.1 → 1.2 → 1.3 → 1.4 each add mandatory
              features (1.2: timelineSemaphore, hostQueryReset, imagelessFramebuffer,
              uniformBufferStandardLayout, separateDepthStencilLayouts, …; 1.3:
              dynamicRendering, synchronization2, maintenance4, shaderDemote/Terminate,
              subgroupSizeControl, inlineUniformBlock, privateData, …; 1.4 adds the
              maintenance5/6, pushDescriptor, hostImageCopy, lineRasterization,
              shaderFloatControls2, dynamicRenderingLocalRead families). The W1 ledger
              carries the exact per-version list from the pinned registry.
  FEEDS       W1 version ladder; MULTIVIEW-L1; CTS-0.
  STATUS      not-run

LOGIC INFO-L3 · Platform/build/instance information is reportable
  CLAIM       The test binary can describe build, platform, instance layers/extensions
              and physical-device groups through the loader; device groups contain the
              device once.
  SOURCE      dEQP-VK.info.{build,platform,instance_layers,instance_extensions,
              physical_devices,physical_device_groups,
              device_group_peer_memory_features,device_layers,
              instance_extension_device_functions,device_memory_budget}.
  MECHANISM   Guest-side (loader + Venus); the renderer contributes only the single
              physical device and, for memory budget, VK_EXT_memory_budget if advertised
              (it is not — NotSupported by absence).
  REQUIRES    One device, one group; stock loader on the guest.
  FORBIDS     Nothing hardware-side.
  CHECK       the cases above (all SelfValidate; they pass by producing the dumps).
  COST        none.
  FEEDS       CTS-0.
  STATUS      not-run
```

## Exceptions

```text
EXCEPTION INFO-X1 · Unadvertised optional extensions report NotSupported
  CONDITION   A test queries an extension/feature we do not advertise (memory budget,
              device groups beyond one device, KHX-era extensions).
  RESULT      NotSupported (the test itself reports it) or an empty-list pass.
  TRUTH       vn_device_profile.toml `[extensions]` lists only what is implemented; the
              audit refuses an extension string without its requirement rows.
  MECHANISM   Profile ROM + Venus allow-list.
  CHECK       info.device_memory_budget, info.device_group_peer_memory_features.
  FORBIDS     Adding an extension string to make a dump "richer".
```

## Implementation-order heuristics

| Heuristic | Trigger | Priority | Smallest useful action | Reject / defer when |
|---|---|---:|---|---|
| INFO-H1 Run it first | CTS-0 | precondition | the 21 cases on Venus→RTL; read every dump | — |
| INFO-H2 Version follows mechanisms | `device_mandatory_features` fails | high | decide multiview-now vs 1.0-now from the failure text, record in W1 | the failure is a Venus/guest artefact (RT-H1: validate the instrument on llvmpipe first) |
| INFO-H3 Close audit findings | the 7 intentional audit findings | medium | fix each finding that is inside the 1.1 minima; document the rest as version-ladder items | a finding needs an engine (becomes a card elsewhere) |

## Segment card (current)

```text
SEGMENT CTS-0/info
  QUESTION        Does the enumerated LibreCore device pass the CTS's own consistency
                  checks at apiVersion 1.1 as advertised today?
  OBJECTIVE       First submission-shaped TestResults.qpa; every non-Pass classified.
  ENVELOPE        Stock Ubuntu 24.04.5 riscv64 guest, Mesa 25.2.8 Venus, RTL ab296cfda on
                  the Verilator 5.020 bridge; deqp-vk cross-built at f6a29701.
  INPUTS          caselist cts0-info-smoke.txt (308 names, sha256 0393d069…); profile
                  vn_device_profile.toml at ab296cfda.
  CONTRACT        info.* self-validate; device_mandatory_features is the only case whose
                  outcome depends on an unimplemented mechanism (hypothesis INFO-L2).
  OBSERVATIONS    Run `cts0-2026-10-14` (deqp-vk `c1078a2d`, `vulkan_headless` target, guest
                  2 GiB, profile `98968f8b`): info 21 run — 17 Pass, 2 NotSupported
                  (`device_memory_budget`: EXT absent; `device_group_peer_memory_features`:
                  one device — both identical on host llvmpipe), 2 Fail:
                  `device_mandatory_features` = "Mandatory feature multiview not
                  supported"; `device_properties` = 39 limit validations below the 1.0/1.1
                  minima (maxImageDimension1D/3D/Cube = 0, maxTexelBufferElements = 0,
                  maxStorageBufferRange 16 MiB < 128 MiB, maxMemoryAllocationCount 64 <
                  4096, maxSamplerAllocationCount 64 < 4000, maxPerStageResources 16 <
                  128, maxDescriptorSet* 16 < 72…96, maxVertexInputAttributes 8 /
                  Bindings 4 < 16, maxComputeWorkGroupCount 0, *SampleCounts without 4,
                  discreteQueuePriorities 0 < 2, texel-offset/alignment fields 0).
                  An earlier run at 16:28 that showed 297/308 was the guest's **llvmpipe**:
                  the Venus PD was absent (DMA window did not cover the 2 GiB second bank)
                  and the device-id fell back to 1 — discarded; the harness now fails
                  closed when no Venus PD is found (RT-P1: validate the instrument).
  HYPOTHESES      H1 confirmed by the source: Mesa Venus (`vn_physical_device.c`)
                  advertises `KHR_multiview`, `KHR_shader_draw_parameters`,
                  `KHR_variable_pointers`, `KHR_device_group`, … unconditionally for any
                  renderer ≥ VN_MIN_RENDERER_VERSION (1.1), so the CTS requires
                  `multiview = true` from us; H2 confirmed (39 limits).
  DISCRIMINATOR   done — the .qpa names each feature/limit.
  RESULT          INFO-L2 → multiview is an obligation now (MV-L1 promoted to G3c:
                  view loop + layered attachments + ViewIndex); INFO-L1 → each of the 39
                  limits maps to a card: G3b residency (allocation/sampler/descriptor
                  counts, per-stage resources), G3d (1D/3D/cube dims, texel buffers),
                  G3c (sample counts 1|4, vertex attributes/bindings 16), pure-profile
                  truth fixes where the mechanism already exists (discreteQueuePriorities,
                  texel offsets, alignments, maxComputeWorkGroupCount from the dispatch
                  field width, maxStorageBufferRange from the LSU address width) — each
                  raised only with its mechanism verified.
  LIMITS          One guest configuration; 1.1 obligations only (the 1.2+ families are
                  not yet in the list).
  NEXT ARTIFACT   ledger row `info` (2 fail); the W1 limits table with mechanism per
                  limit; MV-L1 in the G3c brief.
```

## Performance / area / scalability

Not applicable (ROM words). The scalability content is the version ladder: each
mandatory-feature family is a card in another file; none may be bought with a bit.
