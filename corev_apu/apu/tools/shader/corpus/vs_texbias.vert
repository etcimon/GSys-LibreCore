#version 450
// bias-capable varying: vcol.xy=uv (sample coord), vcol.z=bias
// operand = (0.6-uv.y)*4.0 sweeping ~[+1.2,-1.2] across the tri so
// the SPIR-V Bias image operand pushes lambda across the mip0/mip1/
// mip2 select boundaries.  vcol.w unused (=1.0).
layout(location=0) in vec2 pos;
layout(location=1) in vec2 uv;
layout(location=0) out vec4 vcol;
void main() {
  gl_Position = vec4(pos, 0.5, 1.0);
  vcol = vec4(uv, (0.6 - uv.y) * 4.0, 1.0);
}
