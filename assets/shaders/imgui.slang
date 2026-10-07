// Dear ImGui draw shader. Vertex color is R8G8B8A8_UNORM (ImDrawVert.col).
struct VSIn
{
    float2 Pos;
    float2 UV;
    float4 Col;
};

struct VSOut
{
    float4 Pos : SV_POSITION;
    float2 UV;
    float4 Col;
};

struct Push
{
    float2 Scale;
    float2 Translate;
};

[shader("vertex")]
VSOut vs_imgui(VSIn input, uniform Push pc)
{
    VSOut o;
    o.Pos = float4(input.Pos * pc.Scale + pc.Translate, 0.0, 1.0);
    o.UV = input.UV;
    o.Col = input.Col;
    return o;
}

[[vk::binding(0, 0)]]
Texture2D font_tex;
[[vk::binding(1, 0)]]
SamplerState font_samp;

[shader("fragment")]
float4 fs_imgui(VSOut input) : SV_TARGET
{
    return font_tex.Sample(font_samp, input.UV) * input.Col;
}
