[vk_binding(0, 0)]
RWTexture2D<float4> output;

[vk_binding(1, 0)]
StructuredBuffer<uint8_t> voxel_data;

static const uint CHUNK_SIZE = 32;
static const uint VOXEL_UNIT_SIZE = 2;
static const float INF = 3.402823466e+38F;

struct Push_Constants {
    uint2 viewport_extent;
    uint  world_size;
}

[vk_push_constant]
Push_Constants p;

uint8_t at(uint3 pos) {
    var di = p.world_size * CHUNK_SIZE;
    if (pos.x >= di || pos.y >= di || pos.z >= di) { return 0; }
    return voxel_data[pos.x + pos.y * di + pos.z * di * di];
}

bool is_solid(uint3 pos) {
    return at(pos) > 0;
}

float3 world_to_grid_local_position(float3 position) {
    var di = float(p.world_size * CHUNK_SIZE) * 0.5;
    return position / VOXEL_UNIT_SIZE + di;
}

struct Ray_Intersection_Result {
    float t_min;
    float t_max;
    bool  hit;
}

Ray_Intersection_Result ray_intersect_grid(float3 origin, float3 direction) {
    Ray_Intersection_Result result;
    result.t_min = -INF;
    result.t_max =  INF;
    result.hit   = false;

    float grid_min = 0;
    float grid_max = float(p.world_size * CHUNK_SIZE);

    float3 t_min, t_max;
    for (var a = 0; a < 3; a++) {
        float inv;
        if (direction[a] != 0.0) {
            inv = 1.0 / direction[a];
        } else {
            continue;
        }

        if (inv >= 0) {
            t_min[a] = (grid_min - origin[a]) * inv;
            t_max[a] = (grid_max - origin[a]) * inv;
        } else {
            t_min[a] = (grid_max - origin[a]) * inv;
            t_max[a] = (grid_min - origin[a]) * inv;
        }

        if (result.t_min > t_max[a] || t_min[a] > result.t_max) { return result; }
        if (t_min[a] > result.t_min) {
            result.t_min = t_min[a];
        }
        if (t_max[a] < result.t_max) {
            result.t_max = t_max[a];
        }
    }
    
    result.hit = result.t_min < INF && result.t_max > 0.0;
    return result;
}

struct Ray_Traversal_Result {
    uint3 pos;
    int3 normal;
    bool hit;
}

Ray_Traversal_Result traverse(float3 origin, float3 direction) {
    Ray_Traversal_Result result;
    result.hit = false;

    var grid_origin = world_to_grid_local_position(origin);
    var intersect = ray_intersect_grid(grid_origin, direction);
    if (!intersect.hit) {
        return result;
    }

    intersect.t_min = max(intersect.t_min, 0);
    var ray_start = grid_origin + direction * intersect.t_min;
    var ray_end   = grid_origin + direction * intersect.t_max;
    
    var start_index = uint3(
        uint(max(1, ceil(ray_start.x))),
        uint(max(1, ceil(ray_start.y))),
        uint(max(1, ceil(ray_start.z))),
    );
    var end_index = uint3(
        uint(max(1, ceil(ray_end.x))),
        uint(max(1, ceil(ray_end.y))),
        uint(max(1, ceil(ray_end.z))),
    );
    var current_index = start_index;

    int3 step;
    float3 t_delta, t_max;
    
    for (var a = 0; a < 3; a++) {
        uint current;
        if (direction[a] > 0.0) {
            step[a] =  1;
            current = current_index[a] + 1;
        } else if (direction[a] < 0) {
            step[a] = -1;
            current = current_index[a] - 1;
        } else {
            step[a] = 0;
            t_max[a] = INF;
        }
        
        t_delta[a] = (direction[a] != 0.0) ? abs(1.0 / direction[a]) : 0.0;
        if (t_max[a] != INF) {
            t_max[a] = (float(current) - ray_start[a]) / direction[a];
        }
    }
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

    var half_extent = float2(p.viewport_extent) * 0.5;
    var ndc = (float2(id.xy) - half_extent) / half_extent;
}
