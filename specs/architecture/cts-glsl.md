# `glsl` — shader language semantics: operators, precision, textures, derivatives, control flow (26,763 cases) + `graphicsfuzz` (757)

Source: `specs/VK-GL-CTS` @ `f6a29701`; must-pass `vk-default/glsl.txt` (`vk-default/
graphicsfuzz.txt`); tests in `external/vulkancts/modules/vulkan/shaderexecutor/` (builtin
functions/precision, opaque-type indexing, atomics) and `shaderrender/` (operator, texture_
functions, texture_gather, derivate, matrix, indexing, loops, …); graphicsfuzz cases are
Amber scripts under `external/vulkancts/data/vulkan/amber/graphicsfuzz/`. Owner W3
(ShaderCore, G3a). Gates CTS-1 (`operator`, `builtin.function`, `matrix`, `indexing`,
`loops`, `switch`, `conversions`, `swizzles`, `struct`, `functions`, `return`, `scoping`),
CTS-2 (`builtin.precision`, `derivate`, `texture_functions`, `texture_gather`,
`builtin_var`, `linkage`, `demote`, `atomic_operations`), CTS-3 (`precision_fp16_*`,
`precision_double`, `shader_expect_assume`, `graphicsfuzz`).

## Inventory (`cts_ledger.py tree --group glsl --depth 3 --min-cases 30`, condensed)

| prefix (`dEQP-VK.glsl.`…) | cases | what it exercises |
|---|---:|---|
| `texture_functions` | 7907 | `texture/textureproj/texturelod/texturegrad/texelfetch` × `offset`/`clamp`/`pcoffset` × sampler kinds (2D, 2D array, 3D, cube, shadow), `query` 435 (textureSize/Levels/Lod/Samples) |
| `operator` | 3630 | binary/unary operators on all scalar/vector/matrix types, compares, selection, sequence, common functions |
| `texture_gather` | 3174 | `textureGather{,Offset,Offsets}` (compute 1114, graphics 2060) incl. shadow and per-component |
| `builtin` | 2682 | `function` 882 (common/geometric/integer/pack/…), `precision` 664 (the spec precision table as interval checks), `precision_fp16_storage{16,32}b` 659, `precision_double` 229, `precision_fconvert` 248 |
| `matrix` | 1764 | mat ops incl. `mul` 648, `add/sub/div` 216 each, inverse/determinant/transpose/outerProduct |
| `derivate` | 1674 | dFdx/dFdy/fwidth × fine/coarse × const/linear/texture inputs, `*subgroup` 72 |
| `conversions` | 1060 | scalar/vector/matrix constructors and implicit conversions |
| `atomic_operations` | 1040 | SSBO/shared atomics per type incl. 64-bit (feature-gated) |
| `indexing` | 760 | dynamic indexing of vectors/matrices/arrays (tmp/uniform/varying) |
| `swizzles` | 648 | vector swizzles incl. write masks |
| `loops` | 624 | for/while/do-while, special forms (break/continue, nested, dynamic bounds) |
| `opaque_type_indexing` | 372 | dynamic indexing of sampler/UBO/SSBO/image arrays (uniform / non-uniform where supported) |
| `functions`, `return`, `scoping`, `struct`, `constants`, `constant_expressions`, `arrays`, `switch`, `invariance`, `linkage`, `440.linkage` | 198 / 38 / 34 / 80 / 98 / 42 / 106 / 122 / 72 / 69 / 68 | language structure, interface matching between stages |
| `builtin_var` | 111 | gl_FragCoord/FragDepth 45/FrontFacing/PointCoord/VertexIndex/InstanceIndex/… |
| `precise` | 117 | NoContraction behaviour incl. extended instructions |
| `shader_expect_assume` | 141 | VK_KHR_shader_expect_assume (1.4) |
| `demote` | 30 | demote-to-helper semantics |
| **total** | 26763 | |

## Architectural logic

```text
LOGIC GLSL-L1 · Every SPIR-V instruction glslang emits for GLSL 4.60 (Shader capability)
  CLAIM       The arithmetic, logical, conversion, composite, matrix, control-flow and
              memory instructions of the Shader capability execute with the spec's
              semantics and types (int/uint/float/bool scalars, vec2-4, mat2-4 all
              shapes), including dynamic indexing, swizzles, structs/arrays of them,
              functions with in/out/inout params, early return, nested loops/switch.
  SOURCE      glsl.{operator,conversions,swizzles,indexing,matrix,loops,switch,
              functions,return,scoping,struct,constants,constant_expressions,arrays,
              invariance,linkage,440}.*; shaderrender/vktShaderRender*.cpp and
              shaderexecutor/vktShaderExecutor.cpp drive the same shader in vertex,
              fragment and compute variants.
  MECHANISM   shmod accept set + shwave micro-sequences (4a/4b/G3a-i). Known gaps:
              non-square matrices (mat2x3 … — the RF row-per-column layout handles them;
              the scanner/model must accept them), 8/16/64-bit ints and doubles
              (feature-gated, GLSL-X1), OpSelect on vectors with vector condition, the
              remaining GLSL.std.450 ops (transcendentals → GLSL-L2; Asin/Acos/Atan/
              Sinh…), integer division semantics (x/0 and INT_MIN/−1 are undefined — any
              value is legal, no trap), float ↔ int conversion saturation rules
              (ConvertFToU/S of out-of-range is undefined; CTS avoids them).
  REQUIRES    Vertex-variant tests draw a quad and read varyings — DRAW/RAST path; the
              fragment variants need the interpolation modes (DRAW-L3).
  FORBIDS     Pattern-matching glslang's emission (the CTS also ships hand-written
              SPIR-V in spirv_assembly); value-dependent shortcuts.
  CHECK       the families above in compute variants first (CTS-1); the local corpus
              remains the engine-level gate for fault paths.
  COST        instruction coverage, not datapath (the units exist).
  FEEDS       SPIRV-ASSEMBLY-L*, COMPUTE-L1; CTS-1.
  STATUS      not-run

LOGIC GLSL-L2 · Built-in functions at the spec's precision
  CLAIM       GLSL.std.450 functions meet the "Precision and Operation of SPIR-V
              Instructions" table: fma/fadd/fmul correctly rounded; exp/exp2 3+2|x| ULP;
              log/log2 3 ULP outside [0.5,2] and < 2⁻²¹ absolute inside; pow inherited;
              sin/cos ≤ 2⁻¹¹ absolute on [−π,π]; atan 4096 ULP; asin/acos/sinh/… by
              their defining formulas; inversesqrt 2 ULP; sqrt inherited; ldexp/frexp/
              modf/pack/unpack exact; mix/step/smoothstep/clamp/… by their formulas;
              mediump variants at the relaxed bounds (we execute mediump as fp32 — legal).
  SOURCE      glsl.builtin.precision.<fn>.{highp,mediump}.{scalar,vec2..vec5}* (664),
              glsl.builtin.function.* (882: common, geometric, integer, pack/unpack,
              common_functions in operator); shaderexecutor/vktShaderBuiltinPrecisionTests.cpp
              (interval arithmetic reference).
  MECHANISM   §7d of apu-vulkan-engine.md: generated coefficient tables
              (gen_sfu_tables.py → g6lc_apu_sfu_pkg.sv + sfu_tables.py, one source),
              per-op micro-sequences on the fpnew FMA/DIV-SQRT/CAST units, model
              mirroring op-for-op (Gate 1 bit-exact), Gate 2 against the table bound,
              and this CTS family as the acceptance.
  REQUIRES    G3a-ii; `precision_fp16_*` need shaderFloat16/storage16 (GLSL-X1);
              `precision_double` needs shaderFloat64 (not planned for the SKU unless
              measured cheap — a Pareto item, not a correctness gate at 1.x since the
              feature is optional).
  FORBIDS     Lookup tables with interpolation that miss the ULP bound at range ends;
              treating mediump as permission for fp16 math without the feature.
  CHECK       glsl.builtin.precision.{exp,exp2,log,log2,pow,sin,cos,tan,asin,acos,
              atan,atan2,sinh,cosh,tanh,asinh,acosh,atanh,sqrt,inversesqrt,fma,…}.
              highp.* (CTS-2); engine: the generator's bound check + Gate 1/2.
  COST        ~6–12 FMA-unit steps per transcendental per vec component (serial today);
              a shared SFU pipeline is the W3.3 throughput item.
  FEEDS       cts-spirv-assembly.md; UE/CS2 shaders; CTS-2.
  STATUS      not-run

LOGIC GLSL-L3 · Texture functions, gathers and queries over every sampler kind
  CLAIM       texture/textureProj/textureLod/textureGrad/texelFetch with and without
              offsets (constant and, with pcoffset, push-constant-provided), clamp
              variants (VK_EXT/1.4 minLod clamp), on sampler1D/2D/3D/Cube/2DArray/
              CubeArray/shadow variants, integer and float formats, with mipmapping,
              anisotropy off; textureGather{,Offset,Offsets} returning the four texels of
              component c or the compare results; textureSize/textureQueryLevels/
              textureQueryLod/textureSamples exact.
  SOURCE      glsl.texture_functions.* (7907), glsl.texture_gather.* (3174);
              shaderrender/vktShaderRenderTextureFunctionTests.cpp,
              vktShaderRenderTextureGatherTests.cpp.
  MECHANISM   5b sampler (2D/2D-array, nearest/linear, mip nearest/linear, address
              modes, border, implicit LOD since G2b) extended by G3a-ii (Dref/proj/gather/
              query-LOD) and G3d (cube, 3D, 1D, cube arrays, explicit gradient LOD
              selection — textureGrad computes λ from dPdx/dPdy per the spec formula,
              offsets applied to the integer texel coordinates before wrapping,
              `textureOffsets` with four independent offsets, minLod clamp).
  REQUIRES    Required sampled-image formats per the format table; 3D/cube image layouts
              in Xfer/sampler; maxImageDimension{1D,3D,Cube}, maxImageArrayLayers.
  FORBIDS     Computing LOD once per quad for textureGrad (per-fragment gradients are
              explicit); applying offsets after wrap.
  CHECK       texture_functions.{texture,texturelod,texelfetch}.sampler2d_* first
              (CTS-2), then proj/grad/offset families and gathers as G3a-ii/G3d land;
              cts-texture.md owns the format × filter matrix.
  COST        texel rate: the 16-line texel cache and the lane-serial sampler are the
              roofline today (W1.5: texels/clk); a quad-parallel sampler with a larger
              cache is the W4.5 item.
  FEEDS       TEXTURE-L*, IMAGE-L*; CTS-2.
  STATUS      not-run

LOGIC GLSL-L4 · Derivatives, FragDepth, built-in variables, demote
  CLAIM       dFdx/dFdy/fwidth fine and coarse on constant/linear/texture-sampled inputs
              match the finite differences of the 2×2 quad (coarse may use either pair
              consistently); gl_FragDepth replaces depth; gl_FragCoord (incl. .w = 1/w),
              gl_FrontFacing, gl_PointCoord, gl_VertexIndex/InstanceIndex,
              gl_HelperInvocation are exact; demote keeps the lane executing without
              side effects (G3a-i rule).
  SOURCE      glsl.derivate.* (1674), glsl.builtin_var.* (111, fragdepth 45),
              glsl.demote (30); shaderrender/vktShaderRenderDerivateTests.cpp,
              vktShaderRenderBuiltinVarTests.cpp.
  MECHANISM   G2b quads + derivatives, G3a-i FragDepth/late-Z/demote; gl_PointCoord needs
              points (RAST-L1); `dfdxsubgroup` needs subgroup quad ops (SUBGROUPS-L*).
  REQUIRES    Derivatives of texture-sampled values at the sample positions the test
              expects (implicit LOD inside non-uniform control flow is undefined — the
              tests stay uniform).
  FORBIDS     Deriving derivatives from the interpolation plane equations instead of the
              quad values (fine vs coarse differ observably for texture inputs).
  CHECK       glsl.derivate.dfdx.* etc. (CTS-2); builtin_var.fragdepth.*.
  COST        none new.
  FEEDS       CTS-2.
  STATUS      not-run

LOGIC GLSL-L5 · Atomics, opaque-type indexing, precise, linkage
  CLAIM       SSBO and shared atomics for 32-bit int (64-bit with shaderBufferInt64
              Atomics; float atomics with the EXT) — add/min/max/and/or/xor/exchange/
              compswap in vertex/fragment/compute; dynamic indexing of opaque arrays
              (uniform indices core; non-uniform with descriptorIndexing); `precise`
              forbids contraction (fma not fused) — results equal the unfused reference;
              interface matching between stages (linkage: location/component layout,
              blocks, arrays, flat for integers).
  SOURCE      glsl.atomic_operations.* (1040), glsl.opaque_type_indexing.* (372),
              glsl.precise.* (117), glsl.linkage.*, glsl.440.linkage.
  MECHANISM   G3a-i atomics (32-bit); 64-bit atomics need a 64-bit RMW path and
              shaderBufferInt64Atomics (CS2 is reported to need 64-bit atomics — plan
              E); opaque indexing = per-lane descriptor fetch (DI-L1); precise =
              NoContraction already honoured (4b); linkage = the VS-out/FS-in record
              mapping by Location+Component (component packing of scalars into one slot
              is not implemented — slot = one vec4 per Location today; Component
              decoration must pack).
  REQUIRES    Component decoration support in the record layout (W4.1).
  FORBIDS     Fusing a*b+c when either operand is NoContraction.
  CHECK       atomic_operations.* (32-bit, CTS-2), linkage.varying.* (CTS-2).
  COST        64-bit RMW datapath (later).
  FEEDS       SSBO-L*, SUBGROUPS; CTS-2.
  STATUS      not-run
```

## Exceptions

```text
EXCEPTION GLSL-X1 · Feature-gated numeric types
  CONDITION   shaderFloat64 (precision_double, operator.*double*), shaderInt64,
              shaderInt16/storage16/shaderFloat16 (precision_fp16_*), 8-bit storage,
              shaderBufferInt64Atomics / float atomics, shader_expect_assume (1.4).
  RESULT      NotSupported while the features are false.
  TRUTH       Profile lines; Int64 and 16-bit storage are expected needs of CS2/UE
              (plan E pin) and become LOGIC cards then; Float64 is a Pareto decision.
  MECHANISM   Profile ROM; shmod faults OpTypeFloat 64 / OpTypeInt 64|16|8 today.
  CHECK       ledger; a Fail in these families = advertisement bug.
  FORBIDS     Emulating fp64 in fp32 while advertising shaderFloat64.

EXCEPTION GLSL-X2 · Undefined behaviour the tests avoid
  CONDITION   Integer division by zero, INT_MIN/−1, shifts ≥ 32, out-of-range float→int
              conversions, NaN inputs to min/max (non-N variants), derivatives in
              non-uniform control flow, implicit LOD in vertex stages.
  RESULT      Any value, no fault (the spec leaves them undefined; a fault would break
              the "no device loss" expectation of surrounding tests).
  TRUTH       Spec: these are undefined results, not errors.
  MECHANISM   shwave integer divider returns the RISC-V-style results (q=−1, r=x for /0);
              casts saturate via fpnew; no trap paths exist.
  CHECK       the corpus negative arms; no CTS case may observe a fault here.
  FORBIDS     Adding a fault path "for safety" that turns UB into DEVICE_LOST.

EXCEPTION GLSL-X3 · Graphicsfuzz
  CONDITION   dEQP-VK.graphicsfuzz.* — 757 Amber scripts of compiler-stressing shaders
              (deep control flow, dead code, odd constructs) with reference images.
  RESULT      Pass required (they are core-feature shaders); a failure is a ShaderCore
              defect, never "pathological input".
  TRUTH       Same accept set as GLSL-L1; these are the held-out cases RT-P8 asks for
              (not used to design the ISA).
  MECHANISM   —
  CHECK       graphicsfuzz.* (CTS-3, after GLSL-L1/L2 are green on the designed sets).
  FORBIDS     Tuning the engine on these cases before the designed families are green
              (RT-H8: separate development cases from transfer evaluation).
```

## Implementation-order heuristics

| Heuristic | Trigger | Priority | Smallest useful action | Reject / defer when |
|---|---|---:|---|---|
| GLSL-H1 Operators in compute | CTS-1 | high | run operator/conversions/matrix/indexing/loops/switch compute variants; fix the accept set per failure | — |
| GLSL-H2 Precision table | G3a-ii | high | the §7d SFU with the CTS family as acceptance | — |
| GLSL-H3 Texture functions by kind | G3a-ii/G3d | high | sampler2D/2DArray first, then shadow/proj/grad, then 3D/cube | the format matrix (cts-texture.md) blocks a kind |
| GLSL-H4 Linkage/Component | W4.1 | medium | Component packing in the records | — |
| GLSL-H5 64-bit/16-bit types | plan E pin | later | int64 + atomics first (CS2), fp16 storage next | before the workload pin says so |

## Performance / area / scalability

Shader throughput is the whole product: the W3.3 refactor (scheduler, banked RF,
pipelined ALU, shared SFU, coalescing LSU, quad-parallel texture unit) is measured with
the compute/glsl families as the checked-work baseline (RT-T5). Knobs: lanes per wave,
`MaxWaves`, issue width, SFU count, texel-cache lines, `ShaderCores`. Correctness-
preserving: identical results per instruction at any geometry (Gate 1 across variants),
NoContraction honoured, atomics serialized at one point.
