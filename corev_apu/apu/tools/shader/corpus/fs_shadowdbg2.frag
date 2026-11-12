#version 450
// DEBUG round 2: exercise the REAL shadow descriptor + ops and dump the
// remaining varyings, one suspect per channel.
//   R = op90 textureLod(shmap, dref-compare) result   (lit0 in real FS)
//   G = op93 textureProj(shmap, vsh) result           (lit  in real FS)
//   B = vsh.w  (projective divisor)
//   A = vsh.z  (ref depth)
layout(set = 0, binding = 0) uniform sampler2DShadow shmap;
layout(location=0) in vec2 vuv;
layout(location=1) in vec4 vsh;
layout(location=2) in float vd;
layout(location=0) out vec4 o;
void main() {
  float s0 = textureLod(shmap, vec3(vsh.xy / vsh.w, vsh.z / vsh.w), 0.0);
  float s1 = textureProj(shmap, vsh);
  o = vec4(s0, s1, vsh.w, vsh.z);
}
