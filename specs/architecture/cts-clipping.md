# `clipping` — clip volume, user clip/cull distances (308 cases)

Source: `specs/VK-GL-CTS` @ `f6a29701`; must-pass `vk-default/clipping.txt`; tests in
`external/vulkancts/modules/vulkan/clipping/vktClippingTests.cpp`. Owner W4 (rast clipper,
G2b) + W3 (VS outputs). Gate CTS-2.

## Inventory (`cts_ledger.py tree --group clipping --depth 3`)

| prefix (`dEQP-VK.`…) | cases |
|---|---:|
| `clipping` | 308 |
| &nbsp;&nbsp;`clipping.clip_volume` | 43 |
| &nbsp;&nbsp;`clipping.user_defined` | 256 |
| &nbsp;&nbsp;&nbsp;&nbsp;`…clip_distance / clip_distance_dynamic_index` | 64 / 64 |
| &nbsp;&nbsp;&nbsp;&nbsp;`…clip_cull_distance / clip_cull_distance_dynamic_index` | 64 / 64 |
| **total** | 308 |

## Architectural logic

```text
LOGIC CLIP-L1 · The clip volume is exact at its boundaries
  CLAIM       Primitives are clipped against −w ≤ x,y ≤ w and 0 ≤ z ≤ w (Vulkan clip
              volume; depth clamp disabled), for points, lines and triangles, including
              primitives entirely inside/outside, straddling each plane and the
              degenerate cases (vertices exactly on a plane; large and small w); with
              depthClamp the z planes are not clipped and depth is clamped instead.
  SOURCE      dEQP-VK.clipping.clip_volume.{inside,outside,clipped,depth_clamp,
              depth_clip,...}.* (43); vktClippingTests.cpp.
  MECHANISM   G2b Sutherland–Hodgman clipper in g6lc_apu_rast (near/far/w/guard band),
              fan triangulation; points and lines need their own clip rules (point
              center test; line clipping produces a line); depthClamp needs the
              viewport-range clamp in the fragment path instead of the z planes.
  REQUIRES    Points/lines topologies (RAST-L1 in cts-rasterization.md); the clipper's
              epsilon rule documented (a vertex exactly on a plane is inside).
  FORBIDS     Guard-band culling that drops a primitive whose clipped part is visible;
              clipping in window space after the perspective divide.
  CHECK       clipping.clip_volume.* (CTS-2); engine: the G2b clip vectors + a point/line
              set.
  COST        19 fpnew ops per clipped vertex today (serial); the clipper is a
              throughput item for W4.5 (clip only when outcodes demand it — already).
  FEEDS       RAST-L1, DEPTH-L*; CTS-2.
  STATUS      not-run

LOGIC CLIP-L2 · User clip and cull distances
  CLAIM       gl_ClipDistance[]/gl_CullDistance[] written by the last vertex-processing
              stage clip (interpolated distance < 0 discards fragments / clips the
              primitive) and cull (any vertex-negative culls the primitive), with up to
              maxClipDistances/maxCullDistances (≥ 8 each, 8 combined) and dynamic
              indexing of the arrays.
  SOURCE      dEQP-VK.clipping.user_defined.{clip_distance,clip_cull_distance}
              {,_dynamic_index}.* (256); features shaderClipDistance/shaderCullDistance.
  MECHANISM   Today ClipDistance/CullDistance are *dropped* builtins (stores ignored,
              §7a). Required: VS-out record slots for the distances (the 144-byte record
              has 8 varying slots + position; distances need up to 8 floats = 2 slots or
              a record stride increase), the clipper adds one half-space per clip
              distance (vertex-interpolated), cull is a per-primitive test before setup,
              and the FS can read gl_ClipDistance as an input.
  REQUIRES    shaderClipDistance/shaderCullDistance advertised only with this
              mechanism; Zink's GL 2.1 floor needs shaderClipDistance (so this is on the
              G0/A5 path too).
  FORBIDS     Treating clip distances as a fragment discard only (the spec clips the
              primitive — derivatives and coverage differ).
  CHECK       clipping.user_defined.* (CTS-2); engine vector with a distance crossing
              inside a triangle vs a double-precision reference.
  COST        Up to 8 more interpolants per vertex; record stride parameter.
  FEEDS       cts-geometry/tessellation (the last stage owns the distances); CTS-2.
  STATUS      not-run
```

## Exceptions

```text
EXCEPTION CLIP-X1 · Features not advertised
  CONDITION   shaderClipDistance / shaderCullDistance / depthClamp false in the profile.
  RESULT      NotSupported for user_defined.* and clip_volume.depth_clamp*.
  TRUTH       Profile lines (all false today) — but Zink and UE need shaderClipDistance;
              this exception is temporary by plan, not a release state.
  MECHANISM   Profile ROM.
  CHECK       ledger.
  FORBIDS     Advertising shaderClipDistance with the current dropped-builtin path.
```

## Implementation-order heuristics

| Heuristic | Trigger | Priority | Smallest useful action | Reject / defer when |
|---|---|---:|---|---|
| CLIP-H1 Boundaries first | CTS-2 | high | clip_volume.* on triangles with the existing clipper | points/lines missing (do RAST-L1 first) |
| CLIP-H2 Distances | Zink/UE path | high | clip distances as extra interpolants + extra clip planes; cull as a setup test | the record stride cannot grow without the W4.1 state refactor |

## Performance / area / scalability

Clipping is rare per frame; keep it serial but off the common path (outcode trivial
accept). The per-primitive cull test is cheap. Scalability knob: `ClipPlanes` (6 + user)
sizes the clip ring.
