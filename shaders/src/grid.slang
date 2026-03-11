
struct Push_Constant {
    float4x4 view_proj;
    float4x4 model;
    uint world_size;
    uint chunk_size;
}

[vk_push_constant]
Push_Constant push_constant;

[shader("vertex")]
float4 vertex_main(
    uint vertex_index: SV_VertexID,
    uint instance_index: SV_InstanceID,
): SV_Position {
    var world_size = push_constant.world_size + 1;
    var x = instance_index % world_size;
    var y = (instance_index / world_size) % world_size;
    x *= push_constant.chunk_size;
    y *= push_constant.chunk_size;
    
    var size = float((push_constant.world_size) * push_constant.chunk_size);

    // Offset all points by -0.5 to align them with edges of centred voxels
    float3 points[] = {
        // +X
        float3(0.0,  y, x) - 0.5,
        float3(size, y, x) - 0.5,

        // +Y
        float3(x, 0.0,  y) - 0.5,
        float3(x, size, y) - 0.5,

        // +Z
        float3(x, y, 0.0) - 0.5,
        float3(x, y, size) - 0.5,
    };

    var world_pos = mul(push_constant.model, float4(points[vertex_index], 1.0));
    return mul(push_constant.view_proj, world_pos);
}

[shader("fragment")]
float4 fragment_main(): SV_Target {
    return float4(1.0, 1.0, 1.0, 0.8);
}
