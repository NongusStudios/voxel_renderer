[vk_binding(0, 0)]
RWTexture2D<float4> output;

[vk_binding(1, 0)]
StructuredBuffer<uint8_t> voxel_data;

static const uint CHUNK_SIZE = 32;
static const float EPSILON = 1e-5F;
static const float INF = 3.402823466e+38F;

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
    if (pos.x >= di || pos.y >= di || pos.z >= di ||
        pos.x < 0   || pos.y < 0   || pos.z < 0) return 0;

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

Ray_Intersection_Result ray_intersect_grid(float3 origin, float3 direction, float3 inv_dir) {
    Ray_Intersection_Result result;
    result.t_min = -INF;
    result.t_max =  INF;
    result.hit   = false;

    float grid_min = 0;
    float grid_max = float(p.world_size * CHUNK_SIZE);

    float3 t_min, t_max;
    for (var a = 0; a < 3; a++) {
        if (direction[a] == 0.0) {
            continue;
        }

        if (inv_dir[a] >= 0) {
            t_min[a] = (grid_min - origin[a]) * inv_dir[a];
            t_max[a] = (grid_max - origin[a]) * inv_dir[a];
        } else {
            t_min[a] = (grid_max - origin[a]) * inv_dir[a];
            t_max[a] = (grid_min - origin[a]) * inv_dir[a];
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

    var grid_max = p.world_size * CHUNK_SIZE;
    var inv_dir = 1.0 / direction;
    var sgn_dir = sign(inv_dir);

    var intersect = ray_intersect_grid(origin, direction, inv_dir);
    if (!intersect.hit) {
        return result;
    }

    intersect.t_min = max(intersect.t_min, 0);
    var ray_start = origin + direction * intersect.t_min;
    var ray_end   = origin + direction * intersect.t_max;
    
    var start_index = int3(
        int(floor(ray_start.x)),
        int(floor(ray_start.y)),
        int(floor(ray_start.z)),
    );

    var current_index = start_index;

    var step = uint3(int3(sgn_dir));
    float3 t_delta, t_max;
    
    t_max = (float3(current_index) - ray_start) * inv_dir;
    t_delta = abs(inv_dir);

    while (true) {
        var traversal_dir = int3(0);
        if (t_max.x < t_max.y && t_max.x < t_max.z) {
            current_index.x += step.x;
            t_max.x += t_delta.x;
            traversal_dir.x = step.x;
        } else if (t_max.y < t_max.z) {
            current_index.y += step.y;
            t_max.y += t_delta.y;
            traversal_dir.y = step.y;
        } else {
            current_index.z += step.z;
            t_max.z += t_delta.z;
            traversal_dir.z = step.z;
        }
        
        if  (current_index.x < 0 || current_index.x >= grid_max ||
             current_index.y < 0 || current_index.y >= grid_max ||
             current_index.z < 0 || current_index.z >= grid_max)
        {
            break;
        }

        if (is_solid(current_index)) {
            result.pos    = current_index;
            result.normal = -traversal_dir;
            result.hit    = true;
            return result;
        }
    }
    
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
    var ray_world = normalize(mul((float3x3)p.inv_view, ray_cam.xyz));

    var ray_colour = float4(ray_world * 0.5 + 0.5, 1.0);

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
        } else {
            brightness = 0.5;
        }

        output[texel] = float4(p.color.xyz * brightness, 1.0) * ray_colour;
    } else {
        output[texel] = float4(0.0, 0.0, 0.0, 1.0);
    }
}
