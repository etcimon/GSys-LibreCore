#version 450
#extension GL_EXT_samplerless_texture_functions : require
// descriptor_copy.graphics shape: FS reads a UNIFORM_TEXEL_BUFFER
// (kind4, Dim=Buffer) via texelFetch -> OpImageFetch.  Each of the 16
// fragments reads a distinct seeded texel (fragcoord.xy -> linear
// index 0..15 over ntex=16) so a wrong resolve/base returns another
// element's or zero data.
layout(set = 0, binding = 0) uniform textureBuffer tex;
layout(location = 0) out vec4 o;
void main() {
    int idx = int(gl_FragCoord.x) + int(gl_FragCoord.y) * 4;
    o = texelFetch(tex, idx);
}
