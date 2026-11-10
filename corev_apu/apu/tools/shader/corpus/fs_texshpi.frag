#version 450
layout(location = 0) in vec4 vcol;
layout(location = 0) out vec4 o;
layout(set = 0, binding = 0) uniform sampler2DShadow tex;
void main()
{
    // textureProj on a shadow sampler: vec4(u, v, dref, divisor) ->
    // OpImageSampleProjDrefImplicitLod; coord.xy/divisor, ref compare.
    float r = textureProj(tex, vec4(vcol.xy, vcol.z, vcol.w));
    o = vec4(r, r * 0.5, 1.0 - r, 1.0);
}
