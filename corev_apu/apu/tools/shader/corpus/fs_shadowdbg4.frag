#version 450
// DEBUG round 4: run the EXACT 4-op texture sequence of fs_shadowfog in
// order, outputting each RAW result — detects sequence/state carryover
// between projective/gather/dref ops that isolated probes can't see.
//   R = op93 textureProj(shmap, vsh)              (lit)
//   G = op90 textureLod(shmap, dref, 0)           (lit0)
//   B = op96 textureGather(cmap, cuv, 0).r        (g0, varying cuv)
//   A = op91 textureProj(cmap, vec4(cuv,0,w)).r   (base, varying cuv)
layout(set = 0, binding = 0) uniform sampler2DShadow shmap;
layout(set = 0, binding = 1) uniform sampler2D cmap;
layout(location=0) in vec2 vuv;
layout(location=1) in vec4 vsh;
layout(location=2) in float vd;
layout(location=0) out vec4 o;
void main() {
  vec2 cuv = vsh.xy;
  float lit  = textureProj(shmap, vsh);
  float lit0 = textureLod(shmap, vec3(vsh.xy / vsh.w, vsh.z / vsh.w), 0.0);
  float g0   = textureGather(cmap, cuv, 0).x;
  vec4  base = textureProj(cmap, vec4(cuv, 0.0, vsh.w));
  o = vec4(lit, lit0, g0, base.r);
}
