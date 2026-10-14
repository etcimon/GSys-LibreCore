#version 460
// G3a-i: divergent call into a discarding callee — odd-x lanes enter
// killer() and die while even-x lanes are parked at the caller merge
// inside other()'s path; the parked lanes must resume at the merge
// and write colour after the all-dead callee frame pops.
layout(location = 0) in vec4 vcol;
layout(location = 0) out vec4 color;
vec4 killer() { discard; return vec4(0.0); }
vec4 other()  { return vcol * 2.0; }
void main() {
    vec4 c;
    if ((int(gl_FragCoord.x) & 1) == 1) c = killer();
    else                                c = other();
    color = c + vec4(0.0, 0.0, 0.25, 0.0);
}
