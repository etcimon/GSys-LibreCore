#version 460
#extension GL_EXT_demote_to_helper_invocation : require
// G3a-i demote/store semantics: odd-x lanes demote, then every lane
// round-trips v through a Function-storage local.  dFdxFine(v) in the
// surviving lanes needs the demoted lane's private store to have
// landed — Vulkan helper rules keep Function/Private/Output storage
// live so demoted lanes still feed quad derivatives.
layout(location = 0) in vec4 vcol;
layout(location = 0) out vec4 color;
void main() {
    if ((int(gl_FragCoord.x) & 1) == 1) demote;
    float a[1];
    a[0] = gl_FragCoord.x * 0.5 + gl_FragCoord.y * 0.25 + vcol.b;
    float v = a[0];
    color = vec4(dFdxFine(v), v, vcol.g, 1.0);
}
