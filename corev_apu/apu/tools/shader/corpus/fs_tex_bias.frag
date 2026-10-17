#version 450
// G3a-ii: OpImageSampleImplicitLod + Bias image operand (mask 0x1).
// Reproduces the dEQP texture().bias shape: vcol.z is a per-lane fp
// bias added to lambda before the sampler mipLodBias/min-max clamp.
layout(set = 0, binding = 0) uniform sampler2D tex;
layout(location=0) in vec4 vcol;
layout(location=0) out vec4 o;
void main() {
  o = texture(tex, vcol.xy, vcol.z);
}
