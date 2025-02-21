#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float2 position [[attribute(0)]];
};

struct VertexOut {
    float4 position [[position]];
    float4 color;
};

struct Transform {
    float scale;
    float2 offset;
    float2 viewport;
    float rotation;   // New rotation in radians
};

vertex VertexOut vertexShader(uint vertexID [[vertex_id]],
                            device const VertexIn* vertices [[buffer(0)]],
                            constant Transform& transform [[buffer(1)]]) {
    VertexOut out;
    float2 pos = vertices[vertexID].position;
    // Apply rotation:
    float cosR = cos(transform.rotation);
    float sinR = sin(transform.rotation);
    float2 rotated = float2(pos.x * cosR - pos.y * sinR,
                            pos.x * sinR + pos.y * cosR);
    
    // Then apply scaling and offset:
    float aspect = transform.viewport.x / transform.viewport.y;
    float2 scaled = rotated * transform.scale;
    float2 offs = transform.offset / transform.viewport * 2.0;
    float2 final = scaled + offs;
    final.x *= aspect;
    
    out.position = float4(final, 0.0, 1.0);
    // Gradient remains unchanged:
    float3 baseColor = float3(0.0, 0.47, 1.0);
    float3 highlightColor = float3(0.3, 0.6, 1.0);
    float gradientFactor = smoothstep(-0.04, 0.08, pos.y);
    float3 color = mix(baseColor, highlightColor, gradientFactor);
    out.color = float4(color, 0.9);
    return out;
}

vertex VertexOut pathVertexShader(uint vertexID [[vertex_id]],
                                device const float2* positions [[buffer(0)]],
                                constant Transform& transform [[buffer(1)]]) {
    VertexOut out;
    float2 pos = positions[vertexID];
    // Apply rotation similar to above:
    float cosR = cos(transform.rotation);
    float sinR = sin(transform.rotation);
    float2 rotated = float2(pos.x * cosR - pos.y * sinR,
                            pos.x * sinR + pos.y * cosR);
    
    float aspect = transform.viewport.x / transform.viewport.y;
    float2 scaled = rotated * transform.scale;
    float2 offs = transform.offset / transform.viewport * 2.0;
    float2 final = scaled + offs;
    final.x *= aspect;
    
    out.position = float4(final, 0.0, 1.0);
    out.color = float4(0.8, 0.8, 0.8, 0.3);
    return out;
}

kernel void updatePathTexture(texture2d<float, access::write> output [[texture(0)]],
                            constant float2& position [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
    float2 texPos = float2(gid) / float2(output.get_width(), output.get_height());
    float2 pos = position * 0.5 + 0.5; // convert from [-1,1] to [0,1]
    float dist = distance(texPos, pos);
    
    if (dist < 0.01) {
        output.write(float4(0.0, 0.3, 1.0, 0.8), gid);
    }
}

fragment float4 fragmentShader(VertexOut in [[stage_in]]) {
    return in.color;
}
