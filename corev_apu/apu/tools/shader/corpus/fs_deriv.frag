#version 450
#extension GL_ARB_derivative_control : enable
layout(location=0) in vec4 vcol;
layout(location=0) out vec4 o;
void main() {
  o = vec4(dFdx(vcol.r), dFdy(vcol.g), fwidth(vcol.b),
           dFdxFine(vcol.a) + dFdyCoarse(vcol.a) + fwidthFine(vcol.a));
}
