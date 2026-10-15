#version 450
// §7d projected-coordinate smoke — vcol.xy = uv numerator,
// vcol.z = projection divisor.  r/g use the implicit/explicit
// projected forms (91/92); b samples unprojected for contrast.
layout(set = 0, binding = 0) uniform sampler2D tex;
layout(location=0) in vec4 vcol;
layout(location=0) out vec4 o;
void main() {
  vec4 a = textureProj(tex, vec3(vcol.xy, vcol.z));
  vec4 b = textureProjLod(tex, vec3(vcol.xy, vcol.z), 0.0);
  vec4 c = texture(tex, vcol.xy);
  o = vec4(a.r, b.g, c.b, 1.0);
}
