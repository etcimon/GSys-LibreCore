#version 450
// §7d shadow smoke — D16_UNORM depth map, LINEAR compare sampler.
// vcol.xy = uv, vcol.z = dref, vcol.w = projection divisor.
//   r: OpImageSampleDrefImplicitLod  (89)
//   g: OpImageSampleDrefProjImplicitLod (93)
//   b: OpImageSampleDrefExplicitLod  (90)
//   a: OpImageDrefGather.x           (97)
layout(set = 0, binding = 0) uniform sampler2DShadow tex;
layout(location=0) in vec4 vcol;
layout(location=0) out vec4 o;
void main() {
  float r = texture(tex, vec3(vcol.xy, vcol.z));
  float g = textureProj(tex, vec4(vcol.xy, vcol.z, vcol.w));
  float b = textureLod(tex, vec3(vcol.xy, vcol.z), 0.0);
  float a = textureGather(tex, vcol.xy, vcol.z).x;
  o = vec4(r, g, b, a);
}
