#version 450
layout(location=0) in vec4 vcol;
layout(location=0) out vec4 o;
layout(push_constant) uniform PushData {
  vec4 pc;
} pd;
void main() {
  o = vec4(vcol.rgb + pd.pc.rgb, 1.0);
}
