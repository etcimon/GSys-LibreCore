#version 460
// G3a-i discard/demote: a checkerboard discard keyed on FragCoord —
// killed lanes write no colour and set the slot-8 flag word.
layout(location = 0) in vec4 vcol;
layout(location = 0) out vec4 color;
void main() {
    if (((int(gl_FragCoord.x) >> 3) + (int(gl_FragCoord.y) >> 3) & 1)
        != 0)
        discard;
    color = vcol;
}
