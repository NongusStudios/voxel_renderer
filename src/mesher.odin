package main

import la  "core:math/linalg"
import vk  "vendor:vulkan"
                                      // 32^2 * vertices * faces
MESHER_VERTEX_BUFFER_INIT_CAPACITY :: 32 * 32 * 4        * 6

                                      // 32^2 * indices * faces
MESHER_INDEX_BUFFER_INIT_CAPACITY  :: 32 * 32 * 6       * 6

@(require_results)
mesher_init_buffers :: proc(self: ^Voxel_State) -> (ok: bool) {
    self.mesher.vertex_buffer = create_buffer(
        MESHER_VERTEX_BUFFER_INIT_CAPACITY * size_of(Vertex),
        {.SHADER_DEVICE_ADDRESS, .TRANSFER_DST},
        allocation_info(.Gpu_Only)
    ) or_return

    self.mesher.vertex_buffer_address = buffer_get_device_address(self.mesher.vertex_buffer)

    self.mesher.index_buffer = create_buffer(
        MESHER_INDEX_BUFFER_INIT_CAPACITY * size_of(u32),
        {.INDEX_BUFFER, .TRANSFER_DST},
        allocation_info(.Gpu_Only)
    ) or_return

    self.mesher.staging_buffer = create_staging_buffer(
        self.mesher.vertex_buffer.size + self.mesher.index_buffer.size
    ) or_return

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
    
    mesher_init_buffers(self) or_return
    mesher_init_pipelines(self) or_return

    return true
}

mesher_destroy :: proc(self: ^Voxel_State) {
    destroy_buffer(self.mesher.vertex_buffer)
    destroy_buffer(self.mesher.index_buffer)
    destroy_buffer(self.mesher.staging_buffer)
    delete(self.mesher.vertex_data)
    delete(self.mesher.index_data)
}

// Grows the vertex and index buffers until they reach the desired size, desired size is in bytes.
mesher_grow_buffer :: proc(self: ^Voxel_State, desired: vk.DeviceSize) -> (ok: bool) {
    vk.DeviceWaitIdle(get_device())

    vertex_next_size := self.mesher.vertex_buffer.size
    index_next_size  := self.mesher.index_buffer.size
    for vertex_next_size < desired {
        vertex_next_size += MESHER_VERTEX_BUFFER_INIT_CAPACITY * size_of(Vertex)
        index_next_size  += MESHER_INDEX_BUFFER_INIT_CAPACITY * size_of(u32)
    }
    
    destroy_buffer(self.mesher.vertex_buffer)
    destroy_buffer(self.mesher.index_buffer)
    destroy_buffer(self.mesher.staging_buffer)

    self.mesher.vertex_buffer = create_buffer(
        vertex_next_size,
        {.SHADER_DEVICE_ADDRESS, .TRANSFER_DST},
        allocation_info(.Gpu_Only)
    ) or_return
    self.mesher.vertex_buffer_address = buffer_get_device_address(self.mesher.vertex_buffer)

    self.mesher.index_buffer = create_buffer(
        index_next_size,
        {.INDEX_BUFFER, .TRANSFER_DST},
        allocation_info(.Gpu_Only)
    ) or_return

    self.mesher.staging_buffer = create_staging_buffer(
        self.mesher.vertex_buffer.size + self.mesher.index_buffer.size
    ) or_return

    return true
}

// Rebuilds the voxel mesh and queues relevant buffers for update for the next frame
mesher_build_mesh :: proc(self: ^Voxel_State) {
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

    for z in 0..<CHUNK_SIZE {
        for y in 0..<CHUNK_SIZE {
            for x in 0..<CHUNK_SIZE {
                if chunk_at(&self.chunk, x, y, z)^ == 0 { continue }
                
                neighbours := [?]int3 {
                    // Front/Back
                    int3{x, y, min(z + 1, CHUNK_SIZE-1)},
                    int3{x, y, max(z - 1, 0)},
                    
                    // Left/Right
                    int3{max(x - 1, 0), y, z},
                    int3{min(x + 1, CHUNK_SIZE-1), y, z},

                    // Top/Bottom
                    int3{x, min(y + 1, CHUNK_SIZE-1), z},
                    int3{x, max(y - 1, 0), z},
                }

                for neighbour, i in neighbours {
                    if neighbour == {x, y, z} {
                        push_face(self, faces[i], x, y, z)
                        continue
                    }

                    if chunk_at(&self.chunk, neighbour)^ == 0 {
                        push_face(self, faces[i], x, y, z)
                    }
                }
            }
        }
    }

    // Grow buffers if necessary
    vertex_data_size := vk.DeviceSize(len(self.mesher.vertex_data) * size_of(Vertex))
    if vertex_data_size > self.mesher.vertex_buffer.size {
        mesher_grow_buffer(self, vertex_data_size)
    }

    self.mesher.update_queued = true

    buffer_write_mapped_memory(self.mesher.staging_buffer,
        self.mesher.vertex_data[:],
    )
    buffer_write_mapped_memory(self.mesher.staging_buffer,
        self.mesher.index_data[:],
        len(self.mesher.vertex_data) * size_of(Vertex),
    )
}

mesher_draw :: proc(self: ^Voxel_State, frame: ^Frame_Data, barrier: ^Pipeline_Barrier) {
    cmd := frame.command_buffer
    
    // Upload to Gpu buffers after world update
    if self.mesher.update_queued {
        pipeline_barrier_add_buffer_barrier(barrier,
            {.ALL_GRAPHICS}, {.SHADER_READ},
            {.COPY},         {.MEMORY_WRITE},
            self.mesher.vertex_buffer.buffer,
        )
        pipeline_barrier_add_buffer_barrier(barrier,
            {.ALL_GRAPHICS}, {.INDEX_READ},
            {.COPY},         {.MEMORY_WRITE},
            self.mesher.index_buffer.buffer,
        )
        cmd_pipeline_barrier(cmd, barrier)

        cmd_copy_buffer(cmd,
            self.mesher.staging_buffer.buffer,
            self.mesher.vertex_buffer.buffer,
            vk.DeviceSize(len(self.mesher.vertex_data) * size_of(Vertex)),
        )
        cmd_copy_buffer(cmd,
            self.mesher.staging_buffer.buffer,
            self.mesher.index_buffer.buffer,
            vk.DeviceSize(len(self.mesher.index_data)  * size_of(u32)),
            vk.DeviceSize(len(self.mesher.vertex_data) * size_of(Vertex)),
        )

        pipeline_barrier_add_buffer_barrier(barrier,
            {.COPY},         {.MEMORY_WRITE},
            {.ALL_GRAPHICS}, {.SHADER_READ},
            self.mesher.vertex_buffer.buffer,
        )
        pipeline_barrier_add_buffer_barrier(barrier,
            {.COPY},         {.MEMORY_WRITE},
            {.ALL_GRAPHICS}, {.INDEX_READ},
            self.mesher.index_buffer.buffer,
        )
        cmd_pipeline_barrier(cmd, barrier)

        self.mesher.update_queued = false
    }


    voxel_state_begin_rendering(self, cmd, barrier)

    vk.CmdBindPipeline(cmd, .GRAPHICS, self.mesher.pipeline.pipeline)
    vk.CmdBindIndexBuffer(cmd, self.mesher.index_buffer.buffer, 0, .UINT32)

    push_contant := Mesher_Push_Constant {
        view_proj = self.matrices.projection * self.matrices.view,
        model     = self.matrices.model,
        color     = { 0.2, 1.0, 0.4, 1.0 },
        vertex_buffer = self.mesher.vertex_buffer_address,
    }
    vk.CmdPushConstants(cmd,
        self.mesher.pipeline.layout,
        {.VERTEX, .FRAGMENT},
        0, size_of(Mesher_Push_Constant),
        &push_contant,
    )

    vk.CmdDrawIndexed(cmd, u32(len(self.mesher.index_data)), 1, 0, 0, 0)

    vk.CmdEndRendering(cmd)
}
