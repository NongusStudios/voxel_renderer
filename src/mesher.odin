package main

import "core:log"
import la  "core:math/linalg"
import vk  "vendor:vulkan"
                                      // size^2               * vertices * faces
MESHER_VERTEX_BUFFER_INIT_CAPACITY :: CHUNK_SIZE * CHUNK_SIZE * 4        * 6
                                      // size^2               * indices  * faces
MESHER_INDEX_BUFFER_INIT_CAPACITY  :: CHUNK_SIZE * CHUNK_SIZE * 6        * 6

Mesher_Chunk_Objects :: struct {
    vertex_buffer:  Buffer,
    index_buffer:   Buffer,
    staging_buffer: Buffer,
    vertex_address: vk.DeviceAddress,

    index_count: u32,
    update_queued: bool,
}

@(require_results)
mesher_init_chunk_data :: proc(self: ^Voxel_State) -> (ok: bool) {
    for &object in self.mesher.chunk_objects {
        object.vertex_buffer = create_buffer(
            MESHER_VERTEX_BUFFER_INIT_CAPACITY * size_of(Vertex),
            {.SHADER_DEVICE_ADDRESS, .TRANSFER_DST},
            allocation_info(.Gpu_Only)
        ) or_return

        object.vertex_address = buffer_get_device_address(self.mesher.vertex_buffer)

        object.index_buffer = create_buffer(
            MESHER_INDEX_BUFFER_INIT_CAPACITY * size_of(u32),
            {.INDEX_BUFFER, .TRANSFER_DST},
            allocation_info(.Gpu_Only)
        ) or_return

        object.staging_buffer = create_staging_buffer(
            self.mesher.vertex_buffer.size + self.mesher.index_buffer.size
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
    self.mesher.chunk_objects = make([]Mesher_Chunk_Objects, self.world.flat_size)
    
    mesher_init_chunk_data(self) or_return
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
mesher_grow_buffer :: proc(self: ^Voxel_State,
    desired: vk.DeviceSize,
    object: ^Mesher_Chunk_Objects
) -> (ok: bool) {
    vertex_next_size := object.vertex_buffer.size
    index_next_size  := object.index_buffer.size
    for vertex_next_size < desired {
        vertex_next_size += MESHER_VERTEX_BUFFER_INIT_CAPACITY * size_of(Vertex)
        index_next_size  += MESHER_INDEX_BUFFER_INIT_CAPACITY * size_of(u32)
    }
    
    // Wait for current frame to finish before recreating the buffer
    vk.DeviceWaitIdle(get_device())
    destroy_buffer(object.vertex_buffer)
    destroy_buffer(object.index_buffer)
    destroy_buffer(object.staging_buffer)

    object.vertex_buffer = create_buffer(
        vertex_next_size,
        {.SHADER_DEVICE_ADDRESS, .TRANSFER_DST},
        allocation_info(.Gpu_Only)
    ) or_return
    object.vertex_address = buffer_get_device_address(self.mesher.vertex_buffer)

    object.index_buffer = create_buffer(
        index_next_size,
        {.INDEX_BUFFER, .TRANSFER_DST},
        allocation_info(.Gpu_Only)
    ) or_return

    object.staging_buffer = create_staging_buffer(
        self.mesher.vertex_buffer.size + self.mesher.index_buffer.size
    ) or_return

    return true
}

// Rebuilds the voxel mesh and queues relevant buffers for update for the next frame
mesher_build_mesh :: proc(self: ^Voxel_State, chunk_pos: int3) {
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
        x, y, z := pos.x, pos.y, pos.z
        neighbours := [?]int3 {
            // Front/Back
            {x, y, min(z + 1, CHUNK_SIZE-1)},
            {x, y, max(z - 1, 0)},
            
            // Left/Right
            {max(x - 1, 0), y, z},
            {min(x + 1, CHUNK_SIZE-1), y, z},

            // Top/Bottom
            {x, min(y + 1, CHUNK_SIZE-1), z},
            {x, max(y - 1, 0), z},
        }

        for neighbour, i in neighbours {
            // Push faces for cubes on the edge of the chunk
            if neighbour == {x, y, z} {
                push_face(self, faces[i], x, y, z)
                continue
            }

            if chunk_at(&self.chunk, neighbour)^ == 0 {
                push_face(self, faces[i], x, y, z)
            }
        }
    }

    // Grow buffers if necessary
    flat_id := chunk_pos.x +
               chunk_pos.y * self.world.size +
               chunk_pos.z * self.world.size * self.world.size
    object := &self.mesher.chunk_objects[flat_id]

    vertex_data_size := vk.DeviceSize(len(self.mesher.vertex_data) * size_of(Vertex))
    if vertex_data_size > self.mesher.vertex_buffer.size {
        mesher_grow_buffer(self, vertex_data_size, object)
    }

    self.mesher.update_queued = true

    buffer_write_mapped_memory(object.staging_buffer,
        self.mesher.vertex_data[:],
    )
    buffer_write_mapped_memory(object.staging_buffer,
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
        color     = VOXEL_COLOR,
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
