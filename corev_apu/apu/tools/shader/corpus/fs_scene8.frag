#version 460
// G3a-i vkcmp scene 8: non-inlined helper calls, checkerboard discard,
// gl_FragDepth from a function of position, and an SSBO atomic counter.
layout(location = 0) in vec4 vcol;
layout(location = 0) out vec4 color;
layout(set = 0, binding = 0) buffer Ctr { uint cnt; } ctr;

float pick_depth(float b) { return 0.3 + 0.4 * b; }
vec3  shade_rgb(vec3 c)   { return min(c * 1.0, vec3(1.0)); }
vec4  shade(vec4 c)       { return vec4(shade_rgb(c.rgb), 1.0); }

void main() {
    if (((int(gl_FragCoord.x / 8.0) + int(gl_FragCoord.y / 8.0)) & 1)
            != 0)
        discard;
    gl_FragDepth = pick_depth(vcol.b);
    color = shade(vcol);
    atomicAdd(ctr.cnt, 1u);
}
