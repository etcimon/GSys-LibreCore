#version 460
// G3a-i: GLSL.std.450 geometry ops — FaceForward/Reflect/Refract/
// Determinant/MatrixInverse/NMin/NMax via min/max chains.
layout(location = 0) in vec4 vcol;
layout(location = 0) out vec4 color;
void main() {
    vec3 n = normalize(vec3(0.25, -0.5, 1.0));
    vec3 p = vcol.xyz;
    vec3 q = vec3(0.3, -0.2, 0.5);
    vec3 ff = faceforward(p, q, n);
    vec3 rf = reflect(p, n);
    vec3 rr = refract(p, n, 0.75);
    mat4 m = mat4(vcol, vec4(1.0, 0.0, 0.0, 1.0),
                  vec4(0.0, 1.0, 0.0, 1.0), vec4(0.0, 0.0, 1.0, 1.0));
    float d = determinant(m);
    mat4 mi = inverse(m);
    float mn = min(min(p.x, q.x), n.x);
    float mx = max(max(p.y, q.y), n.y);
    color = vec4(ff.x + rf.x + rr.x + d + mi[0][0] + mn + mx,
                 ff.y + rf.y + rr.y + mi[1][1],
                 ff.z + rf.z + rr.z + mi[2][2],
                 1.0);
}
