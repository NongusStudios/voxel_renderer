
struct Push_Constant {
    float4x4 model;
    float4x4 view_proj;
    uint world_size;
    uint chunk_size;
}

[shader("vertex")]
float4 vertex_main(uint instance_index: SV_InstanceID): SV_Position {
    return float4(0.0);
}
