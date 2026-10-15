#version 450
// §7d gather smoke — OpImageGather (96) component 0 and
// component 1 + ConstOffset (1,0): the four footprint texels in
// the (i0,j1),(i1,j1),(i1,j0),(i0,j0) order, unfiltered.
// vcol.xy = uv.
layout(set = 0, binding = 0) uniform sampler2D tex;
layout(location=0) in vec4 vcol;
layout(location=0) out vec4 o;
void main() {
  vec4 g0 = textureGather(tex, vcol.xy, 0);
  vec4 g1 = textureGatherOffset(tex, vcol.xy, ivec2(1, 0), 1);
  o = vec4(g0.x, g0.w, g1.x, g1.z);
}
