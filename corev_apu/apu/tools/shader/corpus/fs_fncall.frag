#version 460
// G3a-i: the same helper family in a fragment shader — value params,
// an inout pointer param, a depth-3 chain, and an early return.
layout(location = 0) in vec4 vcol;
layout(location = 0) out vec4 color;

vec4 shade(vec4 c) { return c * vec4(0.5, 1.0, 1.5, 1.0); }
void dark(inout vec4 c, float k) { c.rgb *= k; }
vec4 l3(vec4 c) { return shade(c) * 1.5; }
vec4 l2(vec4 c) { return l3(c) + vec4(0.01); }
vec4 early(vec4 c) {
    if (c.r > 0.5) return c * 2.0;
    return c;
}

void main() {
    vec4 c = l2(vcol);
    dark(c, 0.5);
    color = early(c);
}
