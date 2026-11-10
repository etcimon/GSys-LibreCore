#version 450
// implicit-lod depth-reference sample: texture() on sampler2DShadow
// -> OpImageSampleDrefImplicitLod(89).  coord=vec3(vcol.xy,vcol.z): uv
// is the depth-map texcoord, vcol.z the compare reference; implicit
// lod -> quad derivatives -> lambda -> mip (single-mip clamps to 0)
// -> LINEAR PCF.  Returns the compare fraction; derived channels give
// colour diversity for the oracle.
layout(set = 0, binding = 0) uniform sampler2DShadow tex;
layout(location=0) in vec4 vcol;
layout(location=0) out vec4 o;
void main() {
  float r = texture(tex, vec3(vcol.xy, vcol.z));
  o = vec4(r, r * 0.5, 1.0 - r, 1.0);
}
