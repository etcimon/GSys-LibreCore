#version 450
// §7d query-lod smoke — OpImageQueryLod (105): out.x = the clamped
// lambda, out.y = the unclamped lambda (both scaled into [0,1] for
// the unorm out-record).  vcol.xy = uv; per-quad derivatives drive
// the implicit-lod lambda.
layout(set = 0, binding = 0) uniform sampler2D tex;
layout(location=0) in vec4 vcol;
layout(location=0) out vec4 o;
void main() {
  vec2 l = textureQueryLod(tex, vcol.xy);
  o = vec4(l.x * 0.25, l.y * 0.125 + 0.5, 0.0, 1.0);
}
