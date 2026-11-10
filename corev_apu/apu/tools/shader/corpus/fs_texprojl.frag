#version 450
// projective explicit-lod: coord=(vcol.xy, vcol.z) -> divide xy/z then
// OpImageSampleProjExplicitLod lod=0 -> mip0 bilinear, NO derivatives.
layout(set = 0, binding = 0) uniform sampler2D tex;
layout(location=0) in vec4 vcol;
layout(location=0) out vec4 o;
void main() {
  o = textureProjLod(tex, vec3(vcol.xy, vcol.z), 0.0);
}
