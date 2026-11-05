// Embedded Slang used by examples. Backends compile/reflect this; binding model is private.
// Entry-point `uniform` → Vulkan push constants (matches assets/shaders/triangle.slang).

UNLIT_COLOR_SLANG :: #string END
struct Vertex_t {
    float3 Pos;
    float3 Color;
    float3 Normal;
};

[shader("vertex")]
float4 vs_main(Vertex_t v, uniform float4x4 MVP, out float3 color : COLOR) : SV_Position {
    color = v.Color;
    return mul(MVP, float4(v.Pos, 1.0));
}

[shader("fragment")]
float4 fs_main(float3 color : COLOR) : SV_Target {
    return float4(color, 1.0);
}
END

LIT_SLANG :: #string END
struct Vertex_t {
    float3 Pos;
    float3 Color;
    float3 Normal;
};

[shader("vertex")]
void vs_main(
    Vertex_t v,
    uniform float4x4 MVP,
    out float4 pos : SV_Position,
    out float3 color : COLOR,
    out float3 nrm : NORMAL
) {
    pos = mul(MVP, float4(v.Pos, 1.0));
    color = v.Color;
    nrm = v.Normal;
}

[shader("fragment")]
float4 fs_main(
    float3 color : COLOR,
    float3 nrm : NORMAL,
    uniform float3 LightDir,
    uniform float Ambient
) : SV_Target {
    float ndotl = saturate(dot(normalize(nrm), normalize(-LightDir)));
    float3 lit = color * (Ambient + (1.0 - Ambient) * ndotl);
    return float4(lit, 1.0);
}
END

COMPUTE_FILL_SLANG :: #string END
RWTexture2D<float4> Output;

[shader("compute")]
[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
    float2 uv = float2(id.xy) / float2(256, 256);
    Output[id.xy] = float4(uv, 0.25, 1.0);
}
END

PARTICLE_UPDATE_SLANG :: #string END
struct Particle {
    float3 Pos;
    float3 Vel;
};

RWStructuredBuffer<Particle> Particles;

[shader("compute")]
[numthreads(64, 1, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
    Particle p = Particles[id.x];
    p.Vel.y -= 9.8 * 0.016;
    p.Pos += p.Vel * 0.016;
    Particles[id.x] = p;
}
END

TESS_SLANG :: #string END
// Placeholder — tessellation stages; real backend must reject unknown/unsupported mapping.
[shader("vertex")]
float4 vs_main(float3 pos : POSITION) : SV_Position { return float4(pos, 1); }

[shader("hull")]
void hs_main() {}

[shader("domain")]
float4 ds_main() : SV_Position { return 0; }

[shader("fragment")]
float4 fs_main() : SV_Target { return float4(1, 0, 1, 1); }
END
