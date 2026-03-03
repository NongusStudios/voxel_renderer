package main

import la  "core:math/linalg"
import vk  "vendor:vulkan"
                                      // size^2               * vertices * faces
MESHER_VERTEX_BUFFER_INIT_CAPACITY :: CHUNK_SIZE * CHUNK_SIZE * 4        * 6
                                      // size^2               * indices  * faces
MESHER_INDEX_BUFFER_INIT_CAPACITY  :: CHUNK_SIZE * CHUNK_SIZE * 6        * 6

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
    self.mesher.vertex_data   = make([dynamic]Vertex, 0, MESHER_VERTEX_BUFFER_INIT_CAPACITY)
    self.mesher.index_data    = make([dynamic]u32,    0, MESHER_INDEX_BUFFER_INIT_CAPACITY)
    self.mesher.chunk_data = make([]Mesher_Chunk_Data, self.world.flat_size)
    
    mesher_init_chunk_data(self) or_return
    mesher_init_pipelines(self) or_return

    return true
}

mesher_destroy :: proc(self: ^Voxel_State) {
    delete(self.mesher.vertex_data)
    delete(self.mesher.index_data)
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

// Rebuilds the voxel mesh for a specific chunk and queues relevant buffers for update for the next frame
mesher_build_chunk_mesh :: proc(self: ^Voxel_State, chunk_pos: int3) {
    clear(&self.mesher.vertex_data)
    clear(&self.mesher.index_data)

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

    chunk := world_get_chunk(&self.world, chunk_pos)

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

    // Grow buffers if necessary
    chunk_data := mesher_get_chunk_data(self, chunk_pos) 

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
}

mesher_draw :: proc(self: ^Voxel_State, frame: ^Frame_Data, barrier: ^Pipeline_Barrier) {
    cmd := frame.command_buffer
    
    // Upload to Gpu buffers after world update
    for chunk_pos, _ in self.world.updates {
        // Rebuild mesh
        mesher_build_chunk_mesh(self, chunk_pos)

        // Copy new data
        data := mesher_get_chunk_data(self, chunk_pos)
        
        /*
            Chunks that are completely solid and are also surrounded by solid voxels on neighbouring chunks
            will have no vertices to display. Trying to copy 0 bytes to a buffer cause vulkan to crash, so these
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


    voxel_state_begin_rendering(self, cmd, barrier)
    vk.CmdBindPipeline(cmd, .GRAPHICS, self.mesher.pipeline.pipeline)
    push_contant := Mesher_Push_Constant {
        view_proj = self.matrices.projection * self.matrices.view,
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
    vk.CmdEndRendering(cmd)
}
