#version 450
layout(location = 0) in vec4 vcol;
layout(location = 0) out vec4 o;
layout(set = 0, binding = 0) uniform sampler2DShadow tex;
void main()
{
    // textureProjLod on a shadow sampler -> OpImageSampleProjDref
    // ExplicitLod(94): coord.xy/vcol.w divide + explicit lod ->
    // mip0 LINEAR PCF at the divided texcoord.  vs_texshw supplies
    // vcol=(u,v,dref,divisor).
    float r = textureProjLod(tex, vec4(vcol.xy, vcol.z, vcol.w), 0.0);
    o = vec4(r, r * 0.5, 1.0 - r, 1.0);
}
