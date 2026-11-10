#version 450
// projective/array/shadow-capable varying: vcol.xy=uv, vcol.z=proj
// divisor ~[0.55,1.65] (nonzero, ~3x), vcol.w=layer/dref selector
// ~[0.4,1.2] (rounds {0,1} on a 2-layer array).
layout(location=0) in vec2 pos;
layout(location=1) in vec2 uv;
layout(location=0) out vec4 vcol;
void main() {
  gl_Position = vec4(pos, 0.5, 1.0);
  vcol = vec4(uv, 0.4 + 1.4 * uv.x, 0.3 + 1.0 * uv.y);
}
