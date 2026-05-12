package main

import "core:log"
import intr "base:intrinsics"
import la  "core:math/linalg"
import vk  "vendor:vulkan"

MESHER_CHUNK_VOXEL_INIT_CAPACITY :: 448
                                      // size                          * vertices * faces
MESHER_VERTEX_BUFFER_INIT_CAPACITY :: MESHER_CHUNK_VOXEL_INIT_CAPACITY * 4        * 6
                                      // size                          * indices  * faces
MESHER_INDEX_BUFFER_INIT_CAPACITY  :: MESHER_CHUNK_VOXEL_INIT_CAPACITY * 6        * 6

Mesher_Chunk_Data :: struct {
    vertex_buffer:  Buffer,
    index_buffer:   Buffer,
    staging_buffer: Buffer,
    vertex_address: vk.DeviceAddress,

    vertex_count: vk.DeviceSize,
    index_count: vk.DeviceSize,
}

@(require_results)
mesher_init_chunk_data :: proc(self: ^Voxel_State) -> (ok: bool) {
    for &data in self.mesher.chunk_data {
        data.vertex_buffer = create_buffer(
            MESHER_VERTEX_BUFFER_INIT_CAPACITY * size_of(Vertex),
            {.SHADER_DEVICE_ADDRESS, .TRANSFER_DST},
            allocation_info(.Gpu_Only)
        ) or_return

        data.vertex_address = buffer_get_device_address(data.vertex_buffer)

        data.index_buffer = create_buffer(
            MESHER_INDEX_BUFFER_INIT_CAPACITY * size_of(u32),
            {.INDEX_BUFFER, .TRANSFER_DST},
            allocation_info(.Gpu_Only)
        ) or_return

        data.staging_buffer = create_staging_buffer(
            data.vertex_buffer.size + data.index_buffer.size
        ) or_return
    }

    return true
}

@(require_results)
mesher_init_pipelines :: proc(self: ^Voxel_State) -> (ok: bool) {
    builder := create_pipeline_builder(); defer destroy_pipeline_builder(&builder)

    pipeline_builder_add_color_attachment_format(&builder, self.color_attachment.format)

    pipeline_builder_set_depth_attachment_format(&builder, .D32_SFLOAT)
    pipeline_builder_enable_depth_test(&builder, .GREATER)
    
    // Each color attachment needs blend state
    pipeline_builder_add_blend_attachment_default(&builder)

    pipeline_builder_add_push_constant_range(&builder, {
        stageFlags = {.VERTEX, .FRAGMENT},
        size = size_of(Mesher_Push_Constant),
    })

    pipeline_builder_set_cull_mode(&builder, {.BACK}, .COUNTER_CLOCKWISE)

    module := create_shader_module(#load("../shaders/mesher.spv")) or_return
    defer vk.DestroyShaderModule(get_device(), module, nil)

    pipeline_builder_add_shader_stage(&builder, .VERTEX,   module, "vertex_main")
    pipeline_builder_add_shader_stage(&builder, .FRAGMENT, module, "fragment_main")

    pipeline_builder_add_dynamic_state(&builder, .POLYGON_MODE_EXT)

    self.mesher.pipeline = pipeline_builder_build(&builder) or_return

    track_resources(
        self.mesher.pipeline,
    )

    return true
}

@(require_results)
mesher_init :: proc(self: ^Voxel_State) -> (ok: bool) {
    self.mesher.vertex_data = make([dynamic]Vertex, 0, MESHER_VERTEX_BUFFER_INIT_CAPACITY)
    self.mesher.index_data  = make([dynamic]u32,    0, MESHER_INDEX_BUFFER_INIT_CAPACITY)
    self.mesher.quad_data   = make([dynamic]Mesher_Quad)
    self.mesher.chunk_data  = make([]Mesher_Chunk_Data, len(self.world.chunks))
    
    mesher_init_chunk_data(self) or_return
    mesher_init_pipelines(self) or_return

    return true
}

mesher_destroy :: proc(self: ^Voxel_State) {
    delete(self.mesher.vertex_data)
    delete(self.mesher.index_data)
    delete(self.mesher.quad_data)
    for data in self.mesher.chunk_data {
        destroy_buffer(data.vertex_buffer)
        destroy_buffer(data.index_buffer)
        destroy_buffer(data.staging_buffer)
    }
    delete(self.mesher.chunk_data)
}

// Grows the vertex and index buffers until they reach the desired size, desired size is in bytes.
mesher_grow_chunk_data :: proc(self: ^Voxel_State,
    desired: vk.DeviceSize,
    data: ^Mesher_Chunk_Data
) -> (ok: bool) {
    vertex_next_size := data.vertex_buffer.size
    index_next_size  := data.index_buffer.size
    for vertex_next_size < desired {
        vertex_next_size += MESHER_VERTEX_BUFFER_INIT_CAPACITY * size_of(Vertex)
        index_next_size  += MESHER_INDEX_BUFFER_INIT_CAPACITY * size_of(u32)
    }

    // Wait for current frame to finish before recreating the buffer
    vk.DeviceWaitIdle(get_device())
    destroy_buffer(data.vertex_buffer)
    destroy_buffer(data.index_buffer)
    destroy_buffer(data.staging_buffer)

    data.vertex_buffer = create_buffer(
        vertex_next_size,
        {.SHADER_DEVICE_ADDRESS, .TRANSFER_DST},
        allocation_info(.Gpu_Only)
    ) or_return
    data.vertex_address = buffer_get_device_address(data.vertex_buffer)

    data.index_buffer = create_buffer(
        index_next_size,
        {.INDEX_BUFFER, .TRANSFER_DST},
        allocation_info(.Gpu_Only)
    ) or_return

    data.staging_buffer = create_staging_buffer(
        data.vertex_buffer.size + data.index_buffer.size
    ) or_return

    return true
}

mesher_get_chunk_data :: proc(self: ^Voxel_State, pos: int3) -> ^Mesher_Chunk_Data {
    return &self.mesher.chunk_data[pos.x +
                                   pos.y * self.world.size +
                                   pos.z * self.world.size * self.world.size]
}

// Binary Mesher
Face :: enum {
    Left,
    Right,
    Bottom,
    Top,
    Back,
    Front,
}

Mesher_Quad :: struct {
    face: Face,
    position: float3,
    extent:   float3,
}

binary_greedy_mesher_generate_quads :: proc(self: ^Voxel_State, chunk_pos: int3, quads: ^[dynamic]Mesher_Quad) {
    // Array size is padded to include voxels outside the current chunk
    CHUNK_SIZE_PADDED :: CHUNK_SIZE + 2
    
    // Binary representation of voxel data along each axis
    voxel_masks: [3][CHUNK_SIZE_PADDED][CHUNK_SIZE_PADDED]u64

    // Binary representation of faces on each axis in both directions
    face_masks: [6][CHUNK_SIZE_PADDED][CHUNK_SIZE_PADDED]u64

    // Create binary mask of voxel data
    for z in 0..<CHUNK_SIZE_PADDED {
        for y in 0..<CHUNK_SIZE_PADDED {
            for x in 0..<CHUNK_SIZE_PADDED {
                // Get world pos
                pos := (int3{x, y, z} + chunk_pos * CHUNK_SIZE) - int3_one

                // Keep padded bits zero for edge chunks
                max_pos := self.world.size * CHUNK_SIZE
                if pos.x < 0 || pos.x >= max_pos ||
                   pos.y < 0 || pos.y >= max_pos ||
                   pos.z < 0 || pos.z >= max_pos {
                    continue
                }

                if world_at(&self.world, pos) == 1 {
                    // x axis
                    voxel_masks[0][z][y] |= 1 << u64(x)
                    // y axis
                    voxel_masks[1][z][x] |= 1 << u64(y)
                    // z axis
                    voxel_masks[2][y][x] |= 1 << u64(z)
                }
            }
        }
    }

    // Cull Faces
    for axis in 0..<3 {
        for row in 0..<CHUNK_SIZE_PADDED {
            for col in 0..<CHUNK_SIZE_PADDED {
                voxel_mask := voxel_masks[axis][row][col]

                // sample descending and ascending axis, creating a mask where air meets solid in both directions
                face_masks[    axis * 2][row][col] = voxel_mask & ~(voxel_mask << 1)
                face_masks[1 + axis * 2][row][col] = voxel_mask & ~(voxel_mask >> 1)
            }
        }
    }

    // Construct binary planes
    planes: [6][CHUNK_SIZE][CHUNK_SIZE]u64

    for axis in 0..<6 {
        for row in 0..<CHUNK_SIZE {
            for col in 0..<CHUNK_SIZE {
                // Get column and remove left and right most padding value
                face_mask := face_masks[axis][row + 1][col + 1]
                face_mask >>= 1
                face_mask &= ~(u64(1) << CHUNK_SIZE)

                for face_mask != 0 {
                    bit := int(intr.count_trailing_zeros(face_mask))
                    planes[axis][bit][row] |= 1 << u64(col)

                    // Clear least significant bit
                    face_mask &= face_mask - 1
                }
            }
        }
    }

    mesh_binary_plane :: proc(plane: ^[CHUNK_SIZE]u64, quads: ^[dynamic]Mesher_Quad, axis: int, plane_pos: int, chunk_pos: int3) {
        for row in 0..<CHUNK_SIZE {
            for {
                bit := intr.count_trailing_zeros(plane[row])
                if bit >= CHUNK_SIZE { break }

                // Get the height of the face by counting trailing ones
                height := intr.count_trailing_zeros(~(plane[row] >> bit))
                
                // Convert height number into repeated positive bits aligned with mask
                height_mask: u64 = (1 << height) - 1
                height_mask = height_mask << bit

                // Zero bits expanded into in the current column
                plane[row] = plane[row] &~ height_mask

                // Grow horizontally
                width := 1
                for row + width < CHUNK_SIZE {
                    // Get bits spanning height in the next row
                    next_row := plane[row + width] & height_mask
                    if next_row != height_mask {
                        break // Face can no longer be expanded horizontally
                    }

                    // Zero bits that were expanded into
                    plane[row + width] = plane[row + width] &~ height_mask
                    width += 1
                }

                quad := Mesher_Quad {
                    face = Face(axis)
                }
                switch axis {
                case 0, 1: // X
                    quad.position = int3_to_float3({plane_pos, int(bit),    row})
                    quad.extent   = int3_to_float3({1,         int(height), width})
                case 2, 3: // Y
                    quad.position = int3_to_float3({int(bit),    plane_pos, row})
                    quad.extent   = int3_to_float3({int(height), 1,         width})
                case 4, 5: // Z
                    quad.position = int3_to_float3({int(bit),    row,   plane_pos})
                    quad.extent   = int3_to_float3({int(height), width, 1})
                }

                // Transform quad position for faces with centred origins
                quad.position += quad.extent * 0.5 - 0.5
                quad.position += int3_to_float3(chunk_pos * CHUNK_SIZE)

                append(quads, quad)
            }
        }
    }

    // Mesh binary planes
    for axis in 0..<6 {
        for plane_pos in 0..<CHUNK_SIZE {
            mesh_binary_plane(&planes[axis][plane_pos], quads, axis, plane_pos, chunk_pos)
        }
    }
}

// Rebuilds the voxel mesh for a specific chunk and queues relevant buffers for update for the next frame
mesher_build_chunk :: proc(self: ^Voxel_State, chunk_pos: int3) {
    benchmark_start_reading("chunk_mesh") 

    clear(&self.mesher.quad_data)
    clear(&self.mesher.vertex_data)
    clear(&self.mesher.index_data)

    binary_greedy_mesher_generate_quads(self, chunk_pos, &self.mesher.quad_data)

    face_vertices := [Face][]Vertex {
        .Left   = CUBE_VERTICES[8:12],
        .Right  = CUBE_VERTICES[12:16],
        .Bottom = CUBE_VERTICES[20:24],
        .Top    = CUBE_VERTICES[16:20],
        .Back   = CUBE_VERTICES[4:8],
        .Front  = CUBE_VERTICES[0:4],
    }

    for quad in self.mesher.quad_data {
        base_vertex := u32(len(self.mesher.vertex_data)) 

        for vertex in face_vertices[quad.face] {
            vert := vertex
            vert.position *= quad.extent
            vert.position += quad.position
            append(&self.mesher.vertex_data, vert)
        }

        append(&self.mesher.index_data,
            base_vertex, base_vertex + 1, base_vertex + 2,
            base_vertex, base_vertex + 2, base_vertex + 3,
        )
    }

    benchmark_end_reading("chunk_mesh") 

    // Grow buffers if necessary
    chunk_data := mesher_get_chunk_data(self, chunk_pos)

    // Record triangle count
    self.gui.triangle_count -= int(chunk_data.index_count) / 3
    self.gui.triangle_count += len(self.mesher.index_data) / 3

    vertex_data_size := vk.DeviceSize(len(self.mesher.vertex_data) * size_of(Vertex))
    if vertex_data_size > chunk_data.vertex_buffer.size {
        mesher_grow_chunk_data(self, vertex_data_size, chunk_data)
    }

    buffer_write_mapped_memory(chunk_data.staging_buffer,
        self.mesher.vertex_data[:],
    )
    buffer_write_mapped_memory(chunk_data.staging_buffer,
        self.mesher.index_data[:],
        len(self.mesher.vertex_data) * size_of(Vertex),
    )

    chunk_data.vertex_count = vk.DeviceSize(len(self.mesher.vertex_data))
    chunk_data.index_count =  vk.DeviceSize(len(self.mesher.index_data))

    /* Unoptimised face culling logic
    chunk := world_get_chunk(&self.world, chunk_pos)
    // Take slices of vertices for each face
    faces := [?][]Vertex{
        CUBE_VERTICES[0:4],
        CUBE_VERTICES[4:8],
        CUBE_VERTICES[8:12],
        CUBE_VERTICES[12:16],
        CUBE_VERTICES[16:20],
        CUBE_VERTICES[20:24],
    }
    
    // Build Mesh from voxel data
    push_face :: proc(self: ^Voxel_State, face: []Vertex, x, y, z: int) {
        base := u32(len(self.mesher.vertex_data))
        for face_vertex in face {
            vertex := face_vertex
            vertex.position += float3{
                f32(x),
                f32(y),
                f32(z),
            }

            append(&self.mesher.vertex_data, vertex)
        }

        append(&self.mesher.index_data,
            base, base + 1, base + 2,
            base, base + 2, base + 3,
        )
    }

    for pos, _ in chunk.solid {
        x, y, z := pos.x + CHUNK_SIZE * chunk_pos.x, 
                   pos.y + CHUNK_SIZE * chunk_pos.y,
                   pos.z + CHUNK_SIZE * chunk_pos.z
        world_size := self.world.size * CHUNK_SIZE - 1
        neighbours := [?]int3 {
            // Front/Back
            {x, y, min(z + 1, world_size)},
            {x, y, max(z - 1, 0)},
            
            // Left/Right
            {max(x - 1, 0), y, z},
            {min(x + 1, world_size), y, z},

            // Top/Bottom
            {x, min(y + 1, world_size), z},
            {x, max(y - 1, 0), z},
        }

        for neighbour, i in neighbours {
            // Push faces for cubes on the edge of the world
            if neighbour == {x, y, z} {
                push_face(self, faces[i], x, y, z)
                continue
            }

            if world_at(&self.world, neighbour)^ == 0 {
                push_face(self, faces[i], x, y, z)
            }
        }
    }
    */
}

mesher_draw :: proc(self: ^Voxel_State, frame: ^Frame_Data, barrier: ^Pipeline_Barrier) {
    cmd := frame.command_buffer
    
    // Upload to Gpu buffers after world update
    for chunk_pos, _ in self.world.updates {
        // Rebuild mesh
        mesher_build_chunk(self, chunk_pos)

        // Copy new data
        data := mesher_get_chunk_data(self, chunk_pos)
        
        /*
            Chunks that are completely solid and are also surrounded by solid voxels on neighbouring chunks
            will have no vertices to display. Trying to copy 0 bytes to a buffer causes a crash, so these
            chunks get skipped.
        */
        if data.vertex_count == 0 {
            continue
        }

        pipeline_barrier_add_buffer_barrier(barrier,
            {.ALL_GRAPHICS}, {.SHADER_READ},
            {.COPY},         {.MEMORY_WRITE},
            data.vertex_buffer.buffer,
        )
        pipeline_barrier_add_buffer_barrier(barrier,
            {.ALL_GRAPHICS}, {.INDEX_READ},
            {.COPY},         {.MEMORY_WRITE},
            data.index_buffer.buffer,
        )
        cmd_pipeline_barrier(cmd, barrier)

        cmd_copy_buffer(cmd,
            data.staging_buffer.buffer,
            data.vertex_buffer.buffer,
            data.vertex_count * size_of(Vertex),
        )
        cmd_copy_buffer(cmd,
            data.staging_buffer.buffer,
            data.index_buffer.buffer,
            data.index_count  * size_of(u32),
            data.vertex_count * size_of(Vertex),
        )

        pipeline_barrier_add_buffer_barrier(barrier,
            {.COPY},         {.MEMORY_WRITE},
            {.ALL_GRAPHICS}, {.SHADER_READ},
            data.vertex_buffer.buffer,
        )
        pipeline_barrier_add_buffer_barrier(barrier,
            {.COPY},         {.MEMORY_WRITE},
            {.ALL_GRAPHICS}, {.INDEX_READ},
            data.index_buffer.buffer,
        )
        cmd_pipeline_barrier(cmd, barrier)
    }
    clear(&self.world.updates)

    mesher_begin_rendering(self, cmd, barrier)
    view_proj := self.matrices.projection * self.matrices.view
 
    /* draw world chunks */
    vk.CmdBindPipeline(cmd, .GRAPHICS, self.mesher.pipeline.pipeline)
    push_contant := Mesher_Push_Constant {
        view_proj = view_proj,
        model     = self.matrices.model,
        color     = VOXEL_COLOR,
    }

    for z in 0..<self.world.size {
        for y in 0..<self.world.size {
            for x in 0..<self.world.size {
                data := mesher_get_chunk_data(self, {x, y, z})
                if data.index_count == 0 { continue }

                vk.CmdBindIndexBuffer(cmd, data.index_buffer.buffer, 0, .UINT32)

                push_contant.vertex_buffer = data.vertex_address

                vk.CmdPushConstants(cmd,
                    self.mesher.pipeline.layout,
                    {.VERTEX, .FRAGMENT},
                    0, size_of(Mesher_Push_Constant),
                    &push_contant,
                )

                vk.CmdDrawIndexed(cmd, u32(data.index_count), 1, 0, 0, 0)
            }
        }
    }

    voxel_state_draw_grid(self, cmd, view_proj) 

    vk.CmdEndRendering(cmd)
    mesher_present_frame(self, frame, barrier)
}

mesher_begin_rendering :: proc(self: ^Voxel_State,
    cmd: vk.CommandBuffer,
    barrier: ^Pipeline_Barrier,
) {
    pipeline_barrier_add_image_barrier(barrier,
        {.ALL_COMMANDS}, {},
        {.ALL_GRAPHICS}, {.COLOR_ATTACHMENT_READ, .COLOR_ATTACHMENT_WRITE},
        .UNDEFINED,
        .COLOR_ATTACHMENT_OPTIMAL,
        self.color_attachment.image,
        image_subresource_range({.COLOR}),
    )
    cmd_pipeline_barrier(cmd, barrier)

    color_clear := vk.ClearValue {
        color = {
            float32 = {0., 0., 0., 1.0},
        }
    }
    
    depth_clear := vk.ClearValue {
        depthStencil = {
            depth = 0.0,
        }
    }

    color_attachment := attachment_info(
        self.color_attachment.view,
        &color_clear,
        .COLOR_ATTACHMENT_OPTIMAL,
    )

    depth_attachment := attachment_info(
        self.depth_attachment.view,
        &depth_clear,
        .DEPTH_ATTACHMENT_OPTIMAL,
    )

    render_info := rendering_info(self.viewport_extent,
        &color_attachment,
        &depth_attachment
    )

    vk.CmdBeginRendering(cmd, &render_info)

    viewport := vk.Viewport {
        x = 0,
        y = 0,
        width =  f32(self.viewport_extent.width),
        height = f32(self.viewport_extent.height),
        minDepth = 0.0,
        maxDepth = 1.0,
    }

    scissor := vk.Rect2D {
        extent = self.viewport_extent,
    }

    vk.CmdSetViewport(cmd, 0, 1, &viewport)
    vk.CmdSetScissor(cmd,  0, 1, &scissor)
}

mesher_present_frame :: proc(self: ^Voxel_State,
    frame: ^Frame_Data,
    barrier: ^Pipeline_Barrier,
) {
    cmd := frame.command_buffer
    swapchain_image := get_swapchain().images[frame.image_index]


    subresource := image_subresource_range({.COLOR})
    pipeline_barrier_add_image_barrier(barrier,
        {.ALL_GRAPHICS}, {.COLOR_ATTACHMENT_READ, .COLOR_ATTACHMENT_WRITE},
        {.COPY}, {.TRANSFER_READ},
        .COLOR_ATTACHMENT_OPTIMAL,
        .TRANSFER_SRC_OPTIMAL,
        self.color_attachment.image,
        subresource,
    )

    pipeline_barrier_add_image_barrier(barrier,
        {.ALL_COMMANDS}, {},
        {.COPY}, {.TRANSFER_WRITE},
        .UNDEFINED,
        .TRANSFER_DST_OPTIMAL,
        swapchain_image,
        subresource,
    )

    cmd_pipeline_barrier(cmd, barrier)

    layers := image_subresource_layers({.COLOR})
    cmd_copy_image(cmd,
        self.color_attachment.image,
        swapchain_image,
        self.viewport_extent,
        get_swapchain().extent,
        layers, layers,
    )

    draw_imgui_and_present_frame(frame,
            {.COPY}, {.TRANSFER_WRITE},
            .TRANSFER_DST_OPTIMAL)
}
