#version 450
layout(location = 0) in vec4 vcol;
layout(location = 0) out vec4 o;
layout(set = 0, binding = 0) uniform usampler2D tex;
void main()
{
    // texelFetch on a usampler2D -> OpImageFetch(95): integer texel
    // coord (gl_FragCoord.xy & 3 tiles the 4x4 R8G8B8A8_UINT map),
    // lod=0, NO filtering — returns the raw uvec4 of uint8 channels.
    uvec4 t = texelFetch(tex, ivec2(gl_FragCoord.xy) & 3, 0);
    o = vec4(t) / 255.0;
}
