# `texture` — filtering, mipmaps, shadow, swizzle, compressed formats, explicit LOD (27,301 cases)

Source: `specs/VK-GL-CTS` @ `f6a29701`; must-pass `vk-default/texture.txt`; tests in
`external/vulkancts/modules/vulkan/texture/vktTexture*.cpp` (the dEQP texture-filtering
references with per-format thresholds). Owner W4 sampler (5b, G2b, G3a-ii, G3d). Gate CTS-2.

## Inventory

| `dEQP-VK.texture.` | cases | what |
|---|---:|---|
| `swizzle` | 11504 | component mapping × format × view type (incl. texture gather with swizzle) |
| `filtering` | 7510 | `3d` 3222, `2d` 1698, `cube` 1648, `2d_array` 822, `unnormal` 120, `mipmap` 64, `basic`/`single_level` 32 each: nearest/linear × mip modes × wrap modes × formats |
| `shadow` | 5377 | 2D/2D-array/cube depth compare, all compare ops, nearest/linear, mipmaps |
| `compressed` + `compressed_3D` | 984 + 828 | ASTC 672, ETC2 72, EAC 48, BC1 48, BC2–7 24 each (feature-gated), 3D variants |
| `mipmap` | 513 | mip generation/selection, LOD bias, min/max LOD, base/max level |
| `explicit_lod` | 380 | textureLod/Grad on sized formats, derivatives |
| `filtering_anisotropy` | 128 | anisotropic filtering (optional feature) |
| `conversion`, `texel_buffer`, `multisample`, `subgroup_lod`, `texel_offset` | 40, 23, 10, 3, 1 | |
| **total** | 27301 | |

## Architectural logic

```text
LOGIC TEX-L1 · Filtering per the texel-footprint rules on every sampled format and view type
  CLAIM       Nearest and linear mag/min filtering with nearest/linear mipmapping (λ
              from implicit/explicit derivatives, bias, clamps), wrap modes (repeat,
              mirrored repeat, clamp to edge, clamp to border, mirror clamp to edge), for
              2D, 2D array, 3D (trilinear = 8 texels, quadrilinear = 16 across two
              levels), cube (seamless, with the face-selection and coordinate rules;
              cube arrays), for UNORM/SNORM/SRGB/SFLOAT/UINT/SINT (no filtering on ints)
              formats, with the result within the format's precision bound used by the
              CTS (which allows implementations' filtering precision via
              `TexLookupPrecision`).
  SOURCE      texture.filtering.{2d,2d_array,3d,cube,unnormal,mipmap,basic,
              single_level}.*, texture.mipmap.*, texture.explicit_lod.*,
              texture.swizzle.* (same filtering, swizzled), texture.conversion.*;
              vktTextureFilteringTests.cpp, vktTextureMipmapTests.cpp,
              vktTextureSwizzleTests.cpp.
  MECHANISM   5b: 2D/2D-array nearest/linear/trilinear with 8-bit fractional weights,
              16-line texel cache; G2b implicit LOD (linear-mantissa log2, max error
              0.086 — the CTS's LOD precision allows ±(2⁻⁵…) per lodBits; verify against
              `mipmap.*` with its `lodBits` — the mantissa approximation may need a
              degree-2 correction); G3d: 3D (third coordinate, slice interpolation),
              cube face select + seamless edge sampling (neighbouring face texels across
              edges), cube arrays, mirror clamp, SNORM/SFLOAT16 decode (f16 converter from
              G3a-i), unnormalized coordinates (no wrap except clamp, no mips).
  REQUIRES    Device image layouts for 3D (depth slices) and cube (6 layers) in the
              layout formula; the swizzle applied after the border colour selection per
              spec; format table completeness.
  FORBIDS     Per-face clamping for cubes; applying swizzle before the border/compare
              step; mip selection by a lookup that violates the λ monotonicity the
              `mipmap` tests check.
  CHECK       filtering.2d.formats.* and sizes.* (CTS-2 start), mipmap.2d.*, then
              2d_array, cube, 3d; swizzle.* once views carry swizzles (they do).
  COST        the texel path (quad-parallel sampler, cache size — W4.5); cube/3D add
              address math only.
  FEEDS       PIPE-L1, GLSL-L3; CTS-2.
  STATUS      not-run

LOGIC TEX-L2 · Shadow (depth compare) sampling
  CLAIM       Sampling a depth format with a compare-enabled sampler returns the
              filtered result of per-texel comparisons (ref OP texel) — PCF for linear
              — on 2D, 2D array and cube depth images, all eight compare ops, with mips.
  SOURCE      texture.shadow.{2d,2d_array,cube}.{nearest,linear,…}.* (5377);
              vktTextureShadowTests.cpp.
  MECHANISM   G3a-ii Dref path (compare before weights) over D16/D32 texels; cube shadow
              needs TEX-L1's cube select; D24 (of D24S8) decode.
  REQUIRES    D16/D32/D24S8 advertised SAMPLED (+ FILTER_LINEAR where PCF is supported —
              required for D16? The format table requires D16_UNORM: SAMPLED_IMAGE and
              with depth-compare; linear filtering of depth is optional per format but
              usually advertised).
  FORBIDS     Comparing after filtering (wrong PCF); comparing with the reference
              unclamped for UNORM depth (clamp ref to [0,1] for fixed-point formats).
  CHECK       shadow.2d.nearest.*, shadow.2d.linear.* (CTS-2), then cube/array.
  COST        a comparator per tap.
  FEEDS       GLSL-L3; CTS-2.
  STATUS      not-run

LOGIC TEX-L3 · Compressed formats (BC/ETC2/EAC/ASTC) and the decode-in-sampler path
  CLAIM       With textureCompressionBC: BC1–BC7 (incl. BC6H float) blocks decode
              exactly per the spec's decompression algorithms for sampled images and
              copies; with textureCompressionETC2/ASTC_LDR: the ETC2/EAC and ASTC LDR
              block formats (and 3D ASTC with the EXT); compressed images are
              block-addressed in copies and have per-format block extents.
  SOURCE      texture.compressed.*, compressed_3D.*, api.copy_and_blit (compressed
              copies), image/astc-decode-mode.*.
  MECHANISM   A block decoder in the texel fetch path (decode a 4×4 block to the texel
              cache line on miss — the cache then serves the 16 texels), per family
              (BC1/2/3 colour endpoints + indices; BC4/5 single/dual channel; BC6H
              half-float partitions; BC7 modes 0–7; ETC2/EAC; ASTC is large — LDR only if
              adopted); Xfer copies move blocks opaquely (block extents in the layout).
  REQUIRES    Decision per family (Pareto): BC1–7 for desktop content (UE/CS2) — plan
              W4.4 says desktop BC is required; ETC2/ASTC are mobile-class and optional
              on desktop (textureCompressionETC2/ASTC_LDR = false is legal).
  FORBIDS     Decompressing to an uncompressed shadow image at upload (not a stock-
              visible behaviour and doubles memory — unless chosen deliberately as the
              implementation with exact results; the CTS cannot tell, but the memory
              requirements it queries must then match what we report).
  CHECK       compressed.bc1_rgb_unorm_block_* … bc7 (G3d/CTS-3).
  COST        BC7 decoder is the largest (~mode tables); BC1–5 are small. The decode-on-
              miss design keeps the sampler loop unchanged.
  FEEDS       PIPE-L1 formats, IMAGE-L*; CTS-3; UE/CS2 content.
  STATUS      not-run (textureCompressionBC false)

LOGIC TEX-L4 · Anisotropic filtering (optional) and texel buffers / multisample textures
  CLAIM       samplerAnisotropy: up to maxSamplerAnisotropy taps along the major axis
              with the spec's loose definition (any anisotropic algorithm that is at
              least as good as isotropic); texel buffers (API-L3); multisample textures
              fetched by sample (PIPE-L4).
  SOURCE      texture.filtering_anisotropy.* (128), texture.texel_buffer.* (23),
              texture.multisample.* (10).
  MECHANISM   Anisotropy: N taps along the gradient-major axis averaged — a Pareto
              decision (UE/CS2 use 4–16×; Zink GL 4.6 requires samplerAnisotropy).
  REQUIRES    the feature decision in W1.
  FORBIDS     Advertising samplerAnisotropy with an isotropic implementation (the tests
              check the anisotropic result is at least as sharp as isotropic… — they
              verify against a reference with tolerance; isotropic may pass, but it is
              a false advertisement — forbidden by CTS-P1's spirit).
  CHECK       the families when advertised.
  COST        up to 16× texel traffic per fragment.
  FEEDS       Zink GL 4.6; W4.5 Pareto.
  STATUS      not-run (NotSupported)
```

## Exceptions

```text
EXCEPTION TEX-X1 · NotSupported by truthful absence
  CONDITION   compressed.* families whose textureCompression* feature is false,
              filtering_anisotropy.* (samplerAnisotropy false), cube/3D/array cases
              until G3d (imageCubeArray feature for cube arrays), formats not in the
              table, subgroup_lod (subgroup ops), unnormal (unnormalizedCoordinates is
              core — those are required once the sampler supports it; they are not an
              exception).
  RESULT      NotSupported.
  TRUTH       profile lines.
  MECHANISM   Profile ROM.
  CHECK       ledger.
  FORBIDS     Leaving 3D/cube unsupported (imageDimension3D/Cube are required limits —
              3D and cube sampling are core).

EXCEPTION TEX-X2 · Filtering precision latitude
  CONDITION   Linear filtering weights, LOD computation, sRGB decode.
  RESULT      Pass within the CTS's `TexLookupPrecision`/`LodPrecision` thresholds
              (derived from the format bits and the implementation's advertised
              subTexelPrecisionBits / mipmapPrecisionBits — 8 and 8 minimum; we must
              advertise what the 8-bit fractional weights and the λ path deliver: the
              0.086 log2 error is ~2⁻³·⁵ — *below* 8 mipmapPrecisionBits; fix the λ
              approximation (degree-2/3 polynomial or the SFU log2 of G3a-ii) before
              advertising ≥ 8 bits).
  TRUTH       The advertised precision bits bound the tolerance the tests use; claiming
              8 bits with a 3.5-bit λ is a CTS-P1 violation that shows up as mipmap.*
              failures.
  MECHANISM   sampler λ path; profile `mipmapPrecisionBits`, `subTexelPrecisionBits`.
  CHECK       texture.mipmap.* and texture.filtering.2d.* at CTS-2.
  FORBIDS     Lowering the advertised bits below the 1.0 minimum (4 and 4 are the
              minimums; 8 is typical) to pass.
```

## Implementation-order heuristics

| Heuristic | Trigger | Priority | Smallest useful action | Reject / defer when |
|---|---|---:|---|---|
| TEX-H1 λ precision | before CTS-2 | high | **done G3a-ii (2026-10-15):** implicit-LOD λ = ½·log2(ρ²) through the §7d log2 core (`W_TXL8` xcall), `mipmapPrecisionBits = 8`; first CTS-2 evidence `g3aii-2026-10-15-tex-*` (run against `glsl.texture_functions`, the λ oracle): `sampler2d_*_fragment` **Pass**; `sampler2d_bias_*` failed pre-fix on the unimplemented Bias image operand (λ += bias(operand) + mipLodBias before clamp — landed, `fs_tex_bias`); `*_vertex` run aborted by Mesa patience (per-prim FS flush on a 16,928-prim draw — merge landed, residual cost is vertex-stage texturing) | — |
| TEX-H2 2D matrix | CTS-2 | high | filtering.2d + mipmap.2d + shadow.2d | — |
| TEX-H3 Cube/3D/array | G3d | high | layouts + seamless cube | — |
| TEX-H4 BC family | G3d/UE | medium | decode-on-miss BC1–7 | mobile formats (skip) |
| TEX-H5 Anisotropy | W1 Pareto | later | N-tap major-axis | — |

## Performance / area / scalability

Texel rate is the second roofline after shader issue. The 16-line cache and lane-serial
fetch (one texel per cycle at best) must become a quad-parallel sampler with a 4-texel
bilinear unit per lane group and a larger set-associative texel cache (W4.5); BC decode
on miss multiplies the cache's value. Knobs: `TexCacheLines`, associativity, sampler
units per core, BC decoder presence. Correctness-preserving: seamless cube, λ
monotonicity, per-tap compare, swizzle/border order — the spec's pipeline order is the
datapath order.
