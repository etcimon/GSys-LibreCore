#version 460
// G3a-i: a fragment shader holding an SSBO atomic — this is the
// fragmentStoresAndAtomics feature actually exercised.  Helper lanes
// (partial 2x2 quads) must NOT execute the atomic: they read back
// old==0 deterministically, so alpha=0 marks a correctly suppressed
// helper while a live lane would only hit 0 once (order-invariant
// discriminator — concurrent wave engines make `old` order unknown).
layout(set = 0, binding = 0) buffer Ctr { uint cnt[]; };
layout(location = 0) in vec4 vcol;
layout(location = 0) out vec4 color;
void main() {
    uint old = atomicAdd(cnt[0], 1u);
    atomicMax(cnt[1], uint(vcol.r * 255.0));
    color = vec4(vcol.rgb + vec3(0.25, 0.0, -0.25), vcol.a);
    if (gl_HelperInvocation)
        color.a = (old == 0u) ? 0.0 : 1.0;
}
