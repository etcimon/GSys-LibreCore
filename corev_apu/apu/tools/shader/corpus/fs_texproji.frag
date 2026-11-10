#version 450
// projective IMPLICIT-lod: coord=(vcol.xy,vcol.z) -> W_TXJ divides
// xy/z wave-wide -> OpImageSampleProjImplicitLod -> quad derivatives
// of the DIVIDED coord -> lambda -> mip -> trilinear.
layout(set = 0, binding = 0) uniform sampler2D tex;
layout(location=0) in vec4 vcol;
layout(location=0) out vec4 o;
void main() {
  o = textureProj(tex, vec3(vcol.xy, vcol.z));
}
