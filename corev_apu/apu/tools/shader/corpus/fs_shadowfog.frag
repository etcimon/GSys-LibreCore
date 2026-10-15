#version 450
// vkcmp scene 10 (f10_shadow_fog): a shadow-mapped lit quad.
//   lit  = OpImageSampleProjDrefImplicitLod (93)  — LINEAR PCF on D16
//   lit0 = OpImageSampleDrefExplicitLod    (90)
//   g0   = OpImageGather                   (96)  — colour map, comp 0
//   base = OpImageSampleProjImplicitLod    (91)  — colour map, proj
//   fog  = OpExtInst Exp (27);  band = OpExtInst Sin (13)
layout(set = 0, binding = 0) uniform sampler2DShadow shmap;
layout(set = 0, binding = 1) uniform sampler2D cmap;
layout(location=0) in vec2 vuv;
layout(location=1) in vec4 vsh;
layout(location=2) in float vd;
layout(location=0) out vec4 o;
void main() {
  float lit  = textureProj(shmap, vsh);
  float lit0 = textureLod(shmap, vec3(vsh.xy / vsh.w, vsh.z / vsh.w), 0.0);
  float g0   = textureGather(cmap, vuv, 0).x;
  vec4  base = textureProj(cmap, vec4(vuv, 0.0, vsh.w));
  float fog  = exp(-vd * 2.0);
  float band = 0.5 + 0.5 * sin(vuv.x * 25.13274123);
  vec3 col = mix(base.rgb * vec3(0.22, 0.24, 0.30), base.rgb, lit);
  col = mix(col, col * vec3(1.0, 1.0, 0.85) + vec3(g0) * 0.10,
                0.35 * lit0);
  col *= fog * (0.55 + 0.45 * band);
  o = vec4(col, base.a);
}
