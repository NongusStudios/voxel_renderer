struct VS_Input {
    float3 position: POSITION;
    float  brightness: BRIGHTNESS;
}

struct VS_Output {
    float4 position: SV_Position;
    float  brightness: BRIGHTNESS;
}

struct Push_Constant {
    float4x4 view_proj;
    float4x4 model;
    float4   color;
    
    int3* voxels;
}

[vk_push_constant]
Push_Constant push_constant;

[shader("vertex")]
VS_Output vertex_main(
    VS_Input input,
    uint index: SV_InstanceID,
) {
    VS_Output output;

    var offset_pos = input.position + float3(push_constant.voxels[index].xyz);
    var world_pos = mul(push_constant.model, float4(offset_pos, 1.0));

    output.position = mul(push_constant.view_proj, world_pos);
    output.brightness = input.brightness;

    return output;
}

struct FS_Input {
    float  brightness: BRIGHTNESS;
}

[shader("fragment")]
float4 fragment_main(FS_Input input): SV_Target {
    return float4(push_constant.color.xyz * input.brightness, 1.0); 
}
