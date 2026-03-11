package main

import vk "vendor:vulkan"

Mesher_Push_Constant :: struct {
    view_proj: float4x4,
    model:     float4x4,
    color:     float4,

    vertex_buffer: vk.DeviceAddress,
}

Grid_Push_Constant :: struct {
    view_proj: float4x4,
    model:     float4x4,
    world_size: u32,
    chunk_size: u32,
}

Vertex :: struct {
    position:   float3,
    brightness: f32,
}

CUBE_VERTICES := [?]Vertex {
    // Front (+Z) 0-3
    { position = {-0.5,  0.5,  0.5}, brightness = 0.8, },
    { position = {-0.5, -0.5,  0.5}, brightness = 0.8, },
    { position = { 0.5, -0.5,  0.5}, brightness = 0.8, },
    { position = { 0.5,  0.5,  0.5}, brightness = 0.8, },
    
    // Back (-Z) 4-7
    { position = {-0.5,  0.5, -0.5}, brightness = 0.5, },
    { position = { 0.5,  0.5, -0.5}, brightness = 0.5, },
    { position = { 0.5, -0.5, -0.5}, brightness = 0.5, },
    { position = {-0.5, -0.5, -0.5}, brightness = 0.5, },

    // Left (-X) 8-11
    { position = {-0.5,  0.5, -0.5}, brightness = 0.6, },
    { position = {-0.5, -0.5, -0.5}, brightness = 0.6, },
    { position = {-0.5, -0.5,  0.5}, brightness = 0.6, },
    { position = {-0.5,  0.5,  0.5}, brightness = 0.6, },

    // Right (+X) 12-15
    { position = { 0.5,  0.5, -0.5}, brightness = 0.7, },
    { position = { 0.5,  0.5,  0.5}, brightness = 0.7, },
    { position = { 0.5, -0.5,  0.5}, brightness = 0.7, },
    { position = { 0.5, -0.5, -0.5}, brightness = 0.7, },

    // Top (+Y) 16-19
    { position = {-0.5,  0.5,  0.5}, brightness = 0.9, },
    { position = { 0.5,  0.5,  0.5}, brightness = 0.9, },
    { position = { 0.5,  0.5, -0.5}, brightness = 0.9, },
    { position = {-0.5,  0.5, -0.5}, brightness = 0.9, },

    // Bottom (-Y) 20-23
    { position = {-0.5, -0.5,  0.5}, brightness = 0.4, },
    { position = {-0.5, -0.5, -0.5}, brightness = 0.4, },
    { position = { 0.5, -0.5, -0.5}, brightness = 0.4, },
    { position = { 0.5, -0.5,  0.5}, brightness = 0.4, },
}

CUBE_INDICES := [?]u32 {
    // Front Face 0-5
    0, 1, 2,
    0, 2, 3,

    // Back Face 6-11
    4, 5, 6,
    4, 6, 7,

    // Left Face 12-17
    8, 9, 10,
    8, 10, 11,

    // Right Face 18-23
    12, 13, 14,
    12, 14, 15,

    // Top Face 24-29
    16, 17, 18,
    16, 18, 19,

    // Bottom Face 30-35
    20, 21, 22,
    20, 22, 23,
}
