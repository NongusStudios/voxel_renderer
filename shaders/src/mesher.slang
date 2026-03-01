struct Vertex {
    float3 position;
    float  brightness;
}

struct VS_Output {
    float4 position: SV_Position;
    float  brightness: BRIGHTNESS;
}

struct Push_Constant {
    float4x4 view_proj;
    float4x4 model;
    float4   color;

    Vertex* vertex_buffer;
}

[vk_push_constant]
Push_Constant push_constant;

[shader("vertex")]
VS_Output vertex_main(
    uint vertex_index: SV_VertexID,
) {
    VS_Output output;

    var vertex = push_constant.vertex_buffer[vertex_index];
    var world_pos = mul(push_constant.model, float4(vertex.position, 1.0));

    output.position = mul(push_constant.view_proj, world_pos);
    output.brightness = vertex.brightness;

    return output;
}

struct FS_Input {
    float  brightness: BRIGHTNESS;
}

[shader("fragment")]
float4 fragment_main(FS_Input input): SV_Target {
    return float4(push_constant.color.xyz * input.brightness, 1.0); 
}
