#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Lecteur animé (portage du shader WebGL de visual.js) : Aurore, Halo, Soie, Lumières.
static float h1(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
static float n1(float2 p) {
    float2 i = floor(p), f = fract(p); f = f * f * (3. - 2. * f);
    return mix(mix(h1(i), h1(i + float2(1, 0)), f.x), mix(h1(i + float2(0, 1)), h1(i + float2(1, 1)), f.x), f.y);
}
static float fbm(float2 p) { float v = 0., a = .5; for (int i = 0; i < 5; i++) { v += a * n1(p); p = p * 2.02 + 3.1; a *= .5; } return v; }
static float3 pal(float t, float3 C0, float3 C1, float3 C2, float3 C3) {
    t = fract(t);
    return t < .25 ? mix(C0, C1, t * 4.) : t < .5 ? mix(C1, C2, (t - .25) * 4.) : t < .75 ? mix(C2, C3, (t - .5) * 4.) : mix(C3, C0, (t - .75) * 4.);
}

[[ stitchable ]] half4 visual(float2 pos, half4 color, float2 R, float T, float M, half4 c0, half4 c1, half4 c2, half4 c3, float BASS, float MID, float HIGH, float HIT) {
    float3 C0 = float3(c0.rgb), C1 = float3(c1.rgb), C2 = float3(c2.rgb), C3 = float3(c3.rgb);
    float2 fc = float2(pos.x, R.y - pos.y);
    float2 uv = fc / R; float2 p = (fc - .5 * R) / min(R.x, R.y);
    float t = T * .06; float3 col;
    int mode = int(M);
    if (mode == 0) {
        float2 q = float2(n1(p * .7 + t), n1(p * .7 - t + 4.));
        float2 r = float2(n1(p * .8 + q * (1.4 + BASS * .6) + t * 1.3), n1(p * .8 + q * 1.4 - t + 9.));
        col = pal(n1(p * .6 + r * 1.2) * 1.4 + t * .3, C0, C1, C2, C3);
        col *= .8 + .35 * BASS;
    } else if (mode == 1) {
        col = C0 * .25;
        for (int i = 0; i < 4; i++) {
            float fi = float(i);
            float2 c = .45 * float2(sin(t * 2.1 + fi * 1.7), cos(t * 1.7 + fi * 2.3));
            float r = .32 + .1 * sin(t * 3. + fi) + .18 * BASS * (i == 0 ? 1. : .5) + .12 * HIT;
            float3 k = i == 0 ? C1 : i == 1 ? C2 : i == 2 ? C3 : C0 * 1.4;
            col += k * smoothstep(r, 0., length(p - c)) * .9;
        }
    } else if (mode == 2) {
        col = mix(C0 * .35, C2 * .5, uv.y);
        for (int i = 0; i < 5; i++) {
            float fi = float(i);
            float y = .25 * sin(p.x * (1.3 + fi * .25) + t * (4. + fi) + fi * 1.3) + .12 * fbm(float2(p.x * 2. + t * 3., fi)) - .4 + fi * .2;
            float w = .045 + .05 * MID + .03 * fi * HIGH;
            float d = abs(p.y - y);
            col += pal(fi * .22 + t * .2, C0, C1, C2, C3) * (smoothstep(w * 3., 0., d) * .55 + smoothstep(w * .35, 0., d) * .5);
        }
    } else {
        col = mix(C0 * .3, C1 * .35, uv.y);
        for (int i = 0; i < 28; i++) {
            float fi = float(i);
            float2 c = float2(h1(float2(fi, 1.)) * 2. - 1., fract(h1(float2(fi, 2.)) + t * (.15 + .25 * h1(float2(fi, 3.)))) * 2.4 - 1.2);
            c.x += .08 * sin(t * 5. + fi);
            float r = .03 + .09 * h1(float2(fi, 4.)) + .05 * HIT * h1(float2(fi, 5.));
            float d = length(p - c);
            col += pal(h1(float2(fi, 6.)) + t * .1, C0, C1, C2, C3) * (smoothstep(r, r * .7, d) * .45 + smoothstep(r * 3., 0., d) * .12) * (.6 + .8 * HIGH);
        }
    }
    col += HIT * .06;
    col *= 1. - .35 * length(uv - .5);
    return half4(half3(col), 1.);
}
