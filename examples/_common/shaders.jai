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

// Single Frame push-constant block so VS+FS uniforms don't both claim offset 0
// (separate entry-point uniforms previously clobbered MVP with LightDir/Ambient).
LIT_SLANG :: #string END
struct Vertex_t {
    float3 Pos;
    float3 Color;
    float3 Normal;
};

struct Frame {
    float4x4 MVP;
    float3 LightDir;
    float Ambient;
};

[shader("vertex")]
void vs_main(
    Vertex_t v,
    uniform Frame frame,
    out float4 pos : SV_Position,
    out float3 color : COLOR,
    out float3 nrm : NORMAL
) {
    pos = mul(frame.MVP, float4(v.Pos, 1.0));
    color = v.Color;
    nrm = v.Normal;
}

[shader("fragment")]
float4 fs_main(
    float3 color : COLOR,
    float3 nrm : NORMAL,
    uniform Frame frame
) : SV_Target {
    float ndotl = saturate(dot(normalize(nrm), normalize(-frame.LightDir)));
    float3 lit = color * (frame.Ambient + (1.0 - frame.Ambient) * ndotl);
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

// CORNELL_COMPUTE — marker used by Android/WebGPU host bakes to select this source.
// CameraPos / CameraFwd are entry-point uniforms (Vulkan push constants / WebGPU UBO).
CORNELL_COMPUTE_SLANG :: #string END
// CORNELL_COMPUTE
[[format("rgba8")]]
RWTexture2D<float4> Output;

bool hit_aabb(float3 ro, float3 rd, float3 bmin, float3 bmax, out float tHit, out float3 nrm) {
    float3 inv = 1.0 / rd;
    float3 t0 = (bmin - ro) * inv;
    float3 t1 = (bmax - ro) * inv;
    float3 tminv = min(t0, t1);
    float3 tmaxv = max(t0, t1);
    float tmin = max(max(tminv.x, tminv.y), tminv.z);
    float tmax = min(min(tmaxv.x, tmaxv.y), tmaxv.z);
    if (tmax < max(tmin, 0.0)) {
        tHit = 0.0;
        nrm = float3(0, 1, 0);
        return false;
    }
    tHit = tmin > 0.0 ? tmin : tmax;
    if (tHit <= 0.0) {
        nrm = float3(0, 1, 0);
        return false;
    }
    float3 p = ro + rd * tHit;
    float3 c = (bmin + bmax) * 0.5;
    float3 d = (p - c) / max(bmax - bmin, float3(1e-4, 1e-4, 1e-4));
    float3 a = abs(d);
    if (a.x > a.y && a.x > a.z) nrm = float3(sign(d.x), 0, 0);
    else if (a.y > a.z) nrm = float3(0, sign(d.y), 0);
    else nrm = float3(0, 0, sign(d.z));
    return true;
}

[shader("compute")]
[numthreads(8, 8, 1)]
void cs_main(
    uint3 id : SV_DispatchThreadID,
    uniform float3 CameraPos,
    uniform float3 CameraFwd
) {
    const uint W = 800;
    const uint H = 600;
    if (id.x >= W || id.y >= H) return;

    float2 uv = (float2(id.xy) + 0.5) / float2(W, H);
    uv = uv * 2.0 - 1.0;
    uv.y = -uv.y;
    float aspect = float(W) / float(H);

    float3 ro = CameraPos;
    float3 forward = normalize(CameraFwd);
    float3 worldUp = float3(0.0, 1.0, 0.0);
    float3 right = normalize(cross(forward, worldUp));
    // If looking nearly straight up/down, rebuild with a different up.
    if (dot(right, right) < 1e-6) {
        right = normalize(cross(forward, float3(0.0, 0.0, 1.0)));
    }
    float3 up = cross(right, forward);
    float3 rd = normalize(forward + right * (uv.x * aspect * 0.7) + up * (uv.y * 0.7));

    float3 lightPos = float3(0.0, 0.92, 0.0);
    float bestT = 1e9;
    float3 albedo = float3(0.02, 0.02, 0.03);
    float3 nrm = float3(0, 1, 0);
    float emissive = 0.0;

    // Room walls as thin AABBs (camera inside).
    float t; float3 n;
    // floor
    if (hit_aabb(ro, rd, float3(-1,-1.02,-1), float3(1,-0.98,1), t, n) && t < bestT) {
        bestT = t; albedo = float3(0.75,0.75,0.75); nrm = n; emissive = 0;
    }
    // ceiling
    if (hit_aabb(ro, rd, float3(-1,0.98,-1), float3(1,1.02,1), t, n) && t < bestT) {
        bestT = t; albedo = float3(0.75,0.75,0.75); nrm = n; emissive = 0;
    }
    // back
    if (hit_aabb(ro, rd, float3(-1,-1,-1.02), float3(1,1,-0.98), t, n) && t < bestT) {
        bestT = t; albedo = float3(0.75,0.75,0.75); nrm = n; emissive = 0;
    }
    // left (red)
    if (hit_aabb(ro, rd, float3(-1.02,-1,-1), float3(-0.98,1,1), t, n) && t < bestT) {
        bestT = t; albedo = float3(0.75,0.12,0.12); nrm = n; emissive = 0;
    }
    // right (green)
    if (hit_aabb(ro, rd, float3(0.98,-1,-1), float3(1.02,1,1), t, n) && t < bestT) {
        bestT = t; albedo = float3(0.12,0.55,0.12); nrm = n; emissive = 0;
    }
    // tall cuboid
    if (hit_aabb(ro, rd, float3(-0.65,-1.0,-0.55), float3(-0.20,0.15,-0.05), t, n) && t < bestT) {
        bestT = t; albedo = float3(0.85,0.85,0.7); nrm = n; emissive = 0;
    }
    // short cuboid
    if (hit_aabb(ro, rd, float3(0.10,-1.0,-0.10), float3(0.55,-0.35,0.40), t, n) && t < bestT) {
        bestT = t; albedo = float3(0.7,0.85,0.85); nrm = n; emissive = 0;
    }
    // emissive ceiling light
    if (hit_aabb(ro, rd, float3(-0.35,0.97,-0.25), float3(0.35,0.999,0.25), t, n) && t < bestT) {
        bestT = t; albedo = float3(1,1,0.9); nrm = n; emissive = 8.0;
    }

    float3 col = albedo * emissive;
    if (emissive < 0.01 && bestT < 1e8) {
        float3 p = ro + rd * bestT;
        float3 l = normalize(lightPos - p);
        float ndotl = saturate(dot(normalize(nrm), l));
        float dist = length(lightPos - p);
        float atten = 1.0 / (0.4 + dist * dist);
        col = albedo * (0.08 + 2.5 * ndotl * atten);
    }
    Output[id.xy] = float4(col, 1.0);
}
END

PARTICLE_UPDATE_SLANG :: #string END
struct Particle {
    float3 Pos;
    float3 Vel;
};

[[vk::binding(0, 0)]]
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

// Valid triangle-domain tessellation (slang spirv tessellation test shape).
TESS_SLANG :: #string END
struct VS_OUT {
    float3 position : POSITION;
};

struct HS_OUT {
    float3 position : POSITION;
};

struct HSC_OUT {
    float EdgeTessFactor[3] : SV_TessFactor;
    float InsideTessFactor : SV_InsideTessFactor;
};

[shader("vertex")]
VS_OUT vs_main(float3 pos : POSITION) {
    VS_OUT o;
    o.position = pos;
    return o;
}

[shader("hull")]
[domain("tri")]
[partitioning("integer")]
[outputtopology("triangle_cw")]
[outputcontrolpoints(3)]
[patchconstantfunc("hs_const")]
HS_OUT hs_main(InputPatch<VS_OUT, 3> patch, uint i : SV_OutputControlPointID) {
    HS_OUT o;
    o.position = patch[i].position;
    return o;
}

HSC_OUT hs_const(InputPatch<VS_OUT, 3> patch) {
    HSC_OUT o;
    o.EdgeTessFactor[0] = 1.0;
    o.EdgeTessFactor[1] = 1.0;
    o.EdgeTessFactor[2] = 1.0;
    o.InsideTessFactor = 1.0;
    return o;
}

[shader("domain")]
[domain("tri")]
float4 ds_main(
    HSC_OUT constants,
    float3 bary : SV_DomainLocation,
    const OutputPatch<HS_OUT, 3> patch
) : SV_Position {
    float3 p =
        patch[0].position * bary.x +
        patch[1].position * bary.y +
        patch[2].position * bary.z;
    return float4(p, 1.0);
}

[shader("fragment")]
float4 fs_main() : SV_Target {
    return float4(1, 0, 1, 1);
}
END
