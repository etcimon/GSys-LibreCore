#version 450
// G3a-ii: vertex-stage texture fetch — glslang lowers texture() in a
// VS to OpImageSampleExplicitLod with Lod=0 (implicit LOD is
// fragment-only).  Reproduces dEQP-VK.glsl.texture_functions.texture.
// sampler2d_fixed_vertex: position passthrough, sampled colour out.
layout(location=0) in vec2 pos;
layout(location=1) in vec2 uv;
layout(location=0) out vec4 vcol;
layout(set=0, binding=0) uniform sampler2D u_samp;
void main() {
  gl_Position = vec4(pos, 0.5, 1.0);
  vcol = textureLod(u_samp, uv, 0.0);
}
