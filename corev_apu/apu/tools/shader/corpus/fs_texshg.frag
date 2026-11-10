#version 450
layout(location = 0) in vec4 vcol;
layout(location = 0) out vec4 o;
layout(set = 0, binding = 0) uniform sampler2DShadow tex;
void main()
{
    // textureGather(sampler2DShadow, vec2 coord, float dref) ->
    // OpImageDrefGather(97): gathers the 2x2 footprint, each texel ->
    // f_dcmp(ref,depth) -> 1.0/0.0 per component (no filtering).
    vec4 g = textureGather(tex, vcol.xy, vcol.z);
    o = vec4(g.x, g.y * 0.5, 1.0 - g.z, g.w);
}
