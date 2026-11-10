#version 450
// G3a-iv: OpImageFetch(95) on R32G32B32A32_UINT (4x uint32 channels).
// texelFetch(usampler2D, ivec2(gl_FragCoord.xy)&3, 0) -> uvec4 of four
// uint32 texels; each normalized /2^32 -> RGBA so the 4-channel u32
// decode (channel separation + little-endian u32 assembly) is
// observable in the UNORM8 output.
layout(set = 0, binding = 0) uniform usampler2D tex;
layout(location=0) out vec4 o;
void main() {
    uvec4 t = texelFetch(tex, ivec2(gl_FragCoord.xy) & 3, 0);
    o = vec4(float(t.x) / 4294967296.0,
             float(t.y) / 4294967296.0,
             float(t.z) / 4294967296.0,
             float(t.w) / 4294967296.0);
}
