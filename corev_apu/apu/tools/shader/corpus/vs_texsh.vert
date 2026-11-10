#version 450
// shadow-capable varying: vcol.xy=uv (depth-map texcoord), vcol.z=dref
// sweeping ~[0.24,0.81] across the triangle (drives LESS_OR_EQUAL
// pass/fail + PCF fraction), vcol.w=1.0 unused by the explicit-lod
// dref path.
layout(location=0) in vec2 pos;
layout(location=1) in vec2 uv;
layout(location=0) out vec4 vcol;
void main() {
  gl_Position = vec4(pos, 0.5, 1.0);
  vcol = vec4(uv, 0.15 + 0.60 * uv.x + 0.15 * uv.y, 1.0);
}
