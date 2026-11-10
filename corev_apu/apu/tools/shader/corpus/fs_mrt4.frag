#version 450
// G3a-iv-r: MRT x4 — four colour attachments (the full ca[3:0] / at_q
// cursor range).  FS-out location l -> ca[l]:
//   location 0 -> attachment 0 : o0 = the proven fs_color gradient.
//   location 1 -> attachment 1 : o1 = R/B swap -> bytes [B,G,R,A].
//   location 2 -> attachment 2 : o2 = RGB left-rotation -> [G,B,R,A].
//   location 3 -> attachment 3 : o3 = FULL channel reversal ->
//     vec4(c.a,c.b,c.g,c.r) = [A,B,G,R] = bytes [b3,b2,b1,b0], the most
//     distinct permutation so all four attachments are observable.
layout(location=0) in vec4 vcol;
layout(location=0) out vec4 o0;
layout(location=1) out vec4 o1;
layout(location=2) out vec4 o2;
layout(location=3) out vec4 o3;
void main() {
  vec4 c = vcol * 0.5 + gl_FragCoord.x * 0.001;
  o0 = c;
  o1 = vec4(c.b, c.g, c.r, c.a);
  o2 = vec4(c.g, c.b, c.r, c.a);
  o3 = vec4(c.a, c.b, c.g, c.r);
}
