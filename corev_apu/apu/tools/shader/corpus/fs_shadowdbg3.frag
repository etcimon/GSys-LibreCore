#version 450
// DEBUG round 3: the suspects round-2 did NOT cover — the SECOND
// descriptor (binding1 cmap), gather(96), proj(91) on colour, and the
// SFU Exp/Sin fog ops.  cuv = vsh.xy varies, so cmap fetches are real.
//   R = textureGather(cmap, cuv, 0).r     (op96)
//   G = textureProj(cmap, vec4(cuv,0,w)).r (op91)
//   B = exp(-vd*2)                         (SFU Exp -> fog)
//   A = 0.5+0.5*sin(vuv.x*25.1327)         (SFU Sin -> band)
layout(set = 0, binding = 1) uniform sampler2D cmap;
layout(location=0) in vec2 vuv;
layout(location=1) in vec4 vsh;
layout(location=2) in float vd;
layout(location=0) out vec4 o;
void main() {
  vec2 cuv = vsh.xy;
  vec4 g = textureGather(cmap, cuv, 0);
  vec4 b = textureProj(cmap, vec4(cuv, 0.0, vsh.w));
  float e = exp(-vd * 2.0);
  float s = 0.5 + 0.5 * sin(vuv.x * 25.13274123);
  o = vec4(g.r, b.r, e, s);
}
