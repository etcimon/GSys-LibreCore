#version 450
// G3a-iii: OpImageFetch(95) on R32_UINT (single-channel uint32).
// texelFetch(usampler2D, ivec2(gl_FragCoord.xy)&3, 0) -> uvec4
// (u32,0,0,1); the u32's 4 bytes are spread into RGBA /255 so every
// fetched bit is observable in the UNORM8 output.
layout(set = 0, binding = 0) uniform usampler2D tex;
layout(location=0) out vec4 o;
void main() {
    uvec4 t = texelFetch(tex, ivec2(gl_FragCoord.xy) & 3, 0);
    o = vec4(float(t.x & 0xFFu) / 255.0,
             float((t.x >> 8) & 0xFFu) / 255.0,
             float((t.x >> 16) & 0xFFu) / 255.0,
             float((t.x >> 24) & 0xFFu) / 255.0);
}
