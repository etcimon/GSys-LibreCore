#version 450
// G3a-iv-q: MRT x3 — three colour attachments.  FS-out location l -> ca[l]:
//   location 0 -> attachment 0 : o0 = the proven fs_color gradient
//     (vcol*0.5 + FragCoord.x*0.001) so att0 reuses the is_fcolor oracle.
//   location 1 -> attachment 1 : o1 = R/B channel swap of o0 (pure
//     per-channel permutation -> att1 word is a byte-permute of att0).
//   location 2 -> attachment 2 : o2 = RGB left-rotation (c.g,c.b,c.r,c.a)
//     -> bytes [G,B,R,A] = [b1,b2,b0,b3], a DIFFERENT permutation so all
//     three attachments are independently observable.
layout(location=0) in vec4 vcol;
layout(location=0) out vec4 o0;
layout(location=1) out vec4 o1;
layout(location=2) out vec4 o2;
void main() {
  vec4 c = vcol * 0.5 + gl_FragCoord.x * 0.001;
  o0 = c;
  o1 = vec4(c.b, c.g, c.r, c.a);
  o2 = vec4(c.g, c.b, c.r, c.a);
}
