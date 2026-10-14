# `spirv-assembly` — hand-written SPIR-V: instruction semantics and type coverage (68,563 cases)

Source: `specs/VK-GL-CTS` @ `f6a29701`; must-pass `vk-default/spirv-assembly.txt`; tests in
`external/vulkancts/modules/vulkan/spirv_assembly/vktSpvAsm*.cpp`. Owner W3 (shmod accept set
+ shwave). Gates CTS-1 (`instruction.compute.*` core subset), CTS-3 (`instruction.graphics`,
`type.*`), the rest feature-gated.

## Inventory

| `dEQP-VK.spirv_assembly.` | cases | what |
|---|---:|---|
| `instruction.graphics` | 20003 | the instruction suite run through vertex/tessellation/geometry/fragment pipelines |
| `instruction.compute` | 19765 | OpNop/OpUndef/OpLine/OpNoLine/OpConstantNull/OpUnreachable, decorations, selection/switch/loop merges, OpPhi, OpCopyMemory/OpCopyObject, OpFunctionCall, OpSpecConstant*, OpVariable initializers, OpQuantizeToF16, conversions, float16/int8/int64 (gated), opsrem/opsmod/opumod, indexing with OpAccessChain variants, float controls (denorm/RTE/RTZ, gated), 8/16-bit storage (gated), physical storage buffer (gated), workgroup memory, non-semantic info, signed zero/inf/nan preserve, ray tracing ops (gated), int dot product (1.3)… |
| `type` | 25392 | arithmetic over every scalar/vector width (i8/i16/i32/i64, f16/f32/f64 — gated per width) |
| `instruction.maint9_vectorization` | 3152 | KHR_maintenance9 |
| `instruction.amd_trinary_minmax` | 132 | AMD |
| `instruction.spirv1p4` | 102 | SPIR-V 1.4 (1.2 core) features: OpCopyLogical, OpPtrEqual, uniform id, entry-point interface lists, OpSelect on composites, … |
| `instruction.terminate_invocation`, `function_params`, `image_query` | 15, 1, 1 | |
| **total** | 68563 | |

## Architectural logic

```text
LOGIC SPV-L1 · The accept set is the SPIR-V-for-Vulkan environment, not glslang's habits
  CLAIM       Every instruction, decoration and execution mode legal in the Vulkan SPIR-V
              environment at the advertised version (SPIR-V 1.3 at Vulkan 1.1, 1.5 at
              1.2, 1.6 at 1.3) executes as specified: OpNop/OpUndef/OpConstantNull/
              OpUnreachable (any behaviour after), OpLine/OpNoLine/OpSource*/OpName
              (ignored), OpCopyMemory(Sized), OpCopyObject/OpCopyLogical, OpPhi with many
              parents and backedges, OpSwitch with 64-bit selectors, OpSelectionMerge
              flags, OpLoopMerge with unroll hints, structured control flow in every
              legal shape (not only glslang's), OpSpecConstantOp arithmetic, OpQuantizeToF16,
              OpFConvert/OpSConvert/OpUConvert (gated widths), OpSRem/OpSMod/OpUMod
              semantics with negative operands, OpIsNan/OpIsInf, OpBitcast across
              vector shapes (e.g. vec2 ↔ i64 when Int64), OpVectorShuffle with 0xFFFFFFFF
              (undefined component), composite ops on nested structs/arrays, OpAccessChain
              with mixed constant/dynamic indices, OpPtrAccessChain (variable pointers,
              gated), Workgroup variables with initializers (1.3 zero-init), function
              params of pointer and composite types, multiple entry points in one
              module (OpEntryPoint × N with different interfaces), OpExecutionModeId.
  SOURCE      spirv_assembly.instruction.compute.* (19,765) and graphics.* (20,003 —
              same semantics through the draw path), spirv1p4.*, function_params,
              image_query, terminate_invocation.
  MECHANISM   shmod/shwave: today a glslang-shaped subset (4a/4b/G3a-i); the systematic
              gaps: multiple entry points (shmod records one `entry_off`; the pipeline
              names the entry by string — `pName` → the decoder KEEPs it, vnfront must
              select the matching OpEntryPoint and its interface list), OpCopyMemory,
              OpCopyLogical, OpSpecConstantOp evaluation at commit (an expression tree
              over spec constants → fold in shmod), OpVectorShuffle undefined index,
              OpSwitch with non-32-bit selectors, OpBitcast reshaping, OpPhi with
              backedge parents from loop continue (4b covers glslang's), function
              pointer parameters to Workgroup/StorageBuffer (G3a-i copies the pointer
              word — storage class travels with it: ok), initializers on Private
              variables (W_IW init walk handles constants), Workgroup initializers (zero
              only, 1.3).
  REQUIRES    Multiple entry points + `pName` selection; spec-constant folding
              (COMPUTE-L1's table + SpecConstantOp evaluation); the W1 ledger of
              SPIR-V version per Vulkan version.
  FORBIDS     Faulting on legal-but-unusual encodings (an `APU_SH_FAULT_*` on a legal
              module is a Fail with device loss — the worst outcome in the CTS: it
              takes the device down for subsequent tests).
  CHECK       instruction.compute.{opnop,opundef,opconstantnull,opcopymemory,
              opcopyobject,opphi,opselect,opswitch,opquantize,…}.* (CTS-1 core subset
              = everything not gated on a feature), instruction.graphics.* at CTS-2.
  COST        shmod table rows; a spec-constant folder (small ALU at commit).
  FEEDS       GLSL-L1, COMPUTE-L1; CTS-1.
  STATUS      not-run

LOGIC SPV-L2 · Type widths and float controls (feature-gated families)
  CLAIM       With shaderInt8/16/64, shaderFloat16/64: arithmetic/conversion/comparison
              on those widths (`type.*` 25,392); with shaderFloatControls (1.2):
              denorm preserve/flush, signed-zero-inf-nan preserve, rounding modes per
              width as advertised in VkPhysicalDeviceFloatControlsProperties; with
              VariablePointers: OpPtrAccessChain/pointer select/phi; int dot product
              (1.3 core shaderIntegerDotProduct: OpSDot/OpUDot/OpSUDot with and without
              accumulation and saturation); physical storage buffer pointers (1.2).
  SOURCE      spirv_assembly.type.*, instruction.compute.{float16,float_controls,
              8bit_storage,16bit_storage,variable_pointers,physical_pointers,
              integer_dot_product,…}.*.
  MECHANISM   fpnew supports FP16/FP64 configurations (Features) — a Pareto decision per
              width; int8/16/64 need ALU widths; float controls must report what fpnew
              does (denormals: fpnew supports both — pick and advertise; RNE default;
              RTZ via per-op rounding); integer dot product (1.3 required!) = the 4a
              `OpDot` sequence's integer sibling with saturation — also the natural AI
              dot-PE reuse point (§8).
  REQUIRES    the W1 decisions per width; shaderIntegerDotProduct at 1.3.
  FORBIDS     Advertising a float-controls property the datapath does not implement.
  CHECK       the families as advertised (CTS-3).
  COST        ALU/FPU widths — Pareto.
  FEEDS       GLSL-X1, W6 (int dot → AI PEs); CTS-3.
  STATUS      not-run (NotSupported)
```

## Exceptions

```text
EXCEPTION SPV-X1 · NotSupported by truthful absence
  CONDITION   width/feature-gated families, ray tracing ops, maint9_vectorization,
              amd_trinary_minmax, spirv1p4 before 1.2, non-semantic debug info (EXT —
              but the *instructions* must be ignored if the extension is enabled by the
              test only when supported), graphics variants of stages we lack
              (tessellation/geometry).
  RESULT      NotSupported.
  TRUTH       profile lines; SPIR-V version follows the Vulkan version (INFO-L2).
  MECHANISM   Profile ROM.
  CHECK       ledger.
  FORBIDS     Faulting a module that uses a *legal* capability we advertise.

EXCEPTION SPV-X2 · Undefined behaviour latitude
  CONDITION   OpUnreachable reached, OpVectorShuffle 0xFFFFFFFF, undefined values from
              OpUndef, division by zero, out-of-range conversions.
  RESULT      Any value; no fault, no device loss.
  TRUTH       spec.
  MECHANISM   as GLSL-X2.
  CHECK       the opundef/opunreachable cases.
  FORBIDS     a fault path.
```

## Implementation-order heuristics

| Heuristic | Trigger | Priority | Smallest useful action | Reject / defer when |
|---|---|---:|---|---|
| SPV-H1 Core compute subset | CTS-1 | high | run instruction.compute.* (non-gated) and fix accept-set faults first — each fault is device loss | — |
| SPV-H2 Entry points + spec-constant folding | CTS-1 | high | pName selection; SpecConstantOp folder | — |
| SPV-H3 Int dot product | 1.3 ladder | medium | integer OpDot family (AI PE candidate) | — |
| SPV-H4 Widths | W1 Pareto | later | fp16 first (content), int64 (CS2), fp64 if cheap | — |

## Performance / area / scalability

Coverage work; the only throughput items are the optional widths (fp16 packed math is
a real win for content — a Pareto candidate with the SFU and texture work in W3.3).
