#version 450
// explicit-lod depth-reference sample: textureLod on sampler2DShadow
// -> OpImageSampleDrefExplicitLod.  coord=vec3(vcol.xy,vcol.z): uv is
// the depth-map texcoord, vcol.z the compare reference; lod=0 -> mip0
// LINEAR PCF.  Returns the compare fraction; derived channels give
// colour diversity for the oracle.
layout(set = 0, binding = 0) uniform sampler2DShadow tex;
layout(location=0) in vec4 vcol;
layout(location=0) out vec4 o;
void main() {
  float r = textureLod(tex, vec3(vcol.xy, vcol.z), 0.0);
  o = vec4(r, r * 0.5, 1.0 - r, 1.0);
}
