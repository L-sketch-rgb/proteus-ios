#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Port of export/wave-dither/wave-dither.glsl.
// One cell is 3 points; y runs down, matching SwiftUI's position space.

float field(float2 p, float t) {
    float2 q = p + 0.28 * float2(sin(p.y * 2.7 + t * 0.19),
                                 cos(p.x * 2.1 - t * 0.15));
    q += 0.08 * float2(sin(q.y * 6.3 - t * 0.31),
                       cos(q.x * 5.7 + t * 0.27));

    float w = sin(q.x * 3.6 + q.y * 1.4 + t * 0.33)
            + 0.7 * sin(q.x * -2.0 + q.y * 3.4 - t * 0.25)
            + 0.45 * sin(length(q - float2(0.8, 0.3)) * 6.5 - t * 0.45);

    float ridge = 1.0 - abs(sin(dot(q, float2(1.3, -2.1)) * 2.4 + t * 0.22));
    float v = 0.5 + 0.5 * w / 2.15;
    v = v * 0.78 + ridge * ridge * 0.30;
    return clamp(smoothstep(0.12, 0.92, v), 0.0, 1.0);
}

float bayer2(float2 a) {
    a = floor(a);
    return fract(a.x * 0.5 + a.y * a.y * 0.75);
}

float bayer4(float2 a) {
    return bayer2(a * 0.5) * 0.25 + bayer2(a);
}

float bayer8(float2 a) {
    return bayer4(a * 0.5) * 0.25 + bayer2(a);
}

[[ stitchable ]] half4 waveDither(float2 position,
                                  half4 color,
                                  float2 size,
                                  float time,
                                  float intensity,
                                  float3 c0,
                                  float3 c1,
                                  float3 c2,
                                  float3 c3) {
    float2 cellPos = floor(position / 3.0);
    float cellsH = max(ceil(size.y / 3.0), 1.0);
    float2 p = (cellPos + 0.5) / cellsH;

    float v = mix(0.5, field(p, time), clamp(intensity, 0.0, 1.0));
    float b = bayer8(cellPos);
    float tone = clamp(floor(v * 3.0 + (b - 0.5) * 0.95), 0.0, 3.0);

    float3 rgb = c0;
    if (tone > 2.5) {
        rgb = c3;
    } else if (tone > 1.5) {
        rgb = c2;
    } else if (tone > 0.5) {
        rgb = c1;
    }

    return half4(half(rgb.r), half(rgb.g), half(rgb.b), 1.0h);
}
