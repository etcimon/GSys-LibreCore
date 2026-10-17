#version 450
// G3a-ii: sampler2DArray implicit LOD — coord.z selects the array
// layer (W_TXC1 F2I); reproduces dEQP-VK.glsl.texture_functions.
// texture.sampler2darray_fixed_fragment.
layout(set = 0, binding = 0) uniform sampler2DArray tex;
layout(location=0) in vec4 vcol;
layout(location=0) out vec4 o;
void main() {
  o = texture(tex, vec3(vcol.xy, vcol.z));
}
