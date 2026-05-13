[vk_binding(0, 0)]
RWTexture2D<float4> output;

[vk_binding(1, 0)]
StructuredBuffer<uint8_t> voxel_data;

static const uint CHUNK_SIZE = 32;
static const float FLT_MAX = 3.402823466e+38F;

struct Push_Constants {
    float4x4 inv_projection;
    float4x4 inv_view;
    float4   color;
    float4   origin;
    uint2    viewport_extent;
    uint     world_size;
}

[vk_push_constant]
Push_Constants p;

uint8_t at(int3 pos) {
    uint di = p.world_size * CHUNK_SIZE;
    return voxel_data[pos.x + pos.y * di + pos.z * di * di];
}

bool is_solid(int3 pos) {
    return at(pos) > 0;
}

struct Ray_Intersection_Result {
    float t_min;
    float t_max;
    bool  hit;
}

Ray_Intersection_Result ray_intersect_grid(float3 origin, uint grid_max, float3 inv_dir, float3 sgn_dir) {
    Ray_Intersection_Result result = {};

    // Simpler method of calculating entry and exit t values
    var t1 = -origin * inv_dir;
    var t2 = (float3(grid_max) - origin) * inv_dir;

    var t_mins = min(t1, t2);
    var t_maxs = max(t1, t2);

    float t_min = 0, t_max = FLT_MAX;
    for(int i = 0; i < 3; i++){
        t_min = max(t_min, t_mins[i]);
        t_max = min(t_max, t_maxs[i]);
    }

    // Ray doesn't intersect grid
    if (t_min > t_max) return result;
    
    result.hit = true;
    result.t_min = t_min;
    result.t_max = t_max;
    return result;
}

struct Ray_Traversal_Result {
    uint3 pos;
    float3 normal;
    bool hit;
}

Ray_Traversal_Result traverse(float3 origin, float3 direction) {
    Ray_Traversal_Result result = {};

    var grid_max = p.world_size * CHUNK_SIZE;
    var inv_dir = clamp(1.0 / direction, -FLT_MAX, FLT_MAX);
    var sgn_dir = sign(inv_dir);

    var intersect = ray_intersect_grid(origin, grid_max, inv_dir, sgn_dir);
    if (!intersect.hit) return result;

    // Ensure origin is inside the grid
    origin += direction * intersect.t_min;
    var current_index = uint3(clamp(floor(origin), float3(0.0), float3(grid_max-1)));
    var t_max = (float3(current_index) + 0.5 * (1.0 + sgn_dir) - origin) * inv_dir;
    
    var step = uint3(int3(sgn_dir));
    var t_delta = abs(inv_dir);
    
    var traversal_dir = int(-1);

    if (!is_solid(current_index)) // Don't traverse if instant hit
    while (true) {
        if (t_max.x < t_max.y && t_max.x < t_max.z) { // X traversal
            current_index.x += step.x;
            t_max.x += t_delta.x;
            traversal_dir = 0;
        } else if (t_max.y < t_max.z) { // Y traversal
            current_index.y += step.y;
            t_max.y += t_delta.y;
            traversal_dir = 1;
        } else { // Z traversal
            current_index.z += step.z;
            t_max.z += t_delta.z;
            traversal_dir = 2;
        }
        
        if (any(current_index >= grid_max)) return result; 

        if (is_solid(current_index)) {
            break;
        }
    }

    result.hit = true;
    if (traversal_dir >= 0) result.normal[traversal_dir] = -sgn_dir[traversal_dir];
    result.pos = current_index;
    return result;
}

[shader("compute")]
[numthreads(8, 8, 1)]
void main(
    uint3 id:  SV_DispatchThreadID,
    uint3 gid: SV_GroupThreadID,
) {
    // Don't write to output outside of the current resolution
    if(id.x >= p.viewport_extent.x || id.y >= p.viewport_extent.y) return;

    var texel = uint2(id.xy);
    
    var ray_cam   = mul(p.inv_projection, float4(float2(texel), 0.0, 1.0));
    var ray_world = mul((float3x3)p.inv_view, ray_cam.xyz);

    var ray_colour = float3(ray_world * 0.5 + 0.5);

    var result = traverse(p.origin.xyz, ray_world);

    if (result.hit) {
        var normal = result.normal;

        // Calculate face brightness
        float brightness = 0.0;
        if (normal.x > 0) {
            brightness = 0.7;
        } else if (normal.x < 0) {
            brightness = 0.6;
        } else if (normal.y > 0) {
            brightness = 0.9;
        } else if (normal.y < 0) {
            brightness = 0.4;
        } else if (normal.z > 0) {
            brightness = 0.8;
        } else if (normal.z < 0) {
            brightness = 0.5;
        } else {
            brightness = 1.0;
        }

        output[texel] = float4(p.color.xyz * brightness, 1.0);
    } else {
        output[texel] = float4(ray_colour * 0.2, 1.0);
    }
}
