[vk_binding(0, 0)]
RWTexture2D<float4> output;

[vk_binding(1, 0)]
StructuredBuffer<uint8_t> voxel_data;

struct Push_Constants {
    uint2 viewport_extent;
}

[vk_push_constant]
Push_Constants p;

[shader("compute")]
[numthreads(8, 8, 1)]
void main(
    uint3 id:  SV_DispatchThreadID,
    uint3 gid: SV_GroupThreadID,
) {
    // Don't write to output outside of the current resolution
    if(id.x >= p.viewport_extent.x || id.y >= p.viewport_extent.y) return;

    int2 texel = int2(id.xy);
    
    if (voxel_data[texel.x + texel.y * 16 * 32] > 0) {
        output[texel] = float4(float2(gid.xy) / 8.0, 0.0, 1.0);
    }
}
