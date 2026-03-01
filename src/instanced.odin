package main

import la  "core:math/linalg"

import vk  "vendor:vulkan"

@(require_results)
instanced_init_buffers :: proc(self: ^Voxel_State) -> (ok: bool) {
    self.instanced.vertex_buffer = create_buffer(
        len(CUBE_VERTICES) * size_of(Vertex),
        {.VERTEX_BUFFER, .TRANSFER_DST},
        allocation_info(.Gpu_Only),
    ) or_return

    self.instanced.index_buffer = create_buffer(
        len(CUBE_INDICES) * size_of(u32),
        {.INDEX_BUFFER, .TRANSFER_DST},
        allocation_info(.Gpu_Only)
    ) or_return

    self.instanced.voxel_buffer = create_buffer(
        CHUNK_FLAT_SIZE * size_of(int32_3),
        {.SHADER_DEVICE_ADDRESS},
        allocation_info(.Cpu_To_Gpu, {.HOST_VISIBLE, .HOST_COHERENT}, {.Mapped}),
    ) or_return

    self.instanced.voxel_buffer_address = buffer_get_device_address(self.instanced.voxel_buffer)

    track_resources(
        self.instanced.vertex_buffer,
        self.instanced.index_buffer,
        self.instanced.voxel_buffer,
    )

    return true
}

@(require_results)
instanced_init_pipelines :: proc(self: ^Voxel_State) -> (ok: bool) {
    builder := create_pipeline_builder(); defer destroy_pipeline_builder(&builder)

    pipeline_builder_add_vertex_binding(&builder, size_of(Vertex))
        pipeline_builder_add_vertex_attribute(&builder, .R32G32B32_SFLOAT, 0)
        pipeline_builder_add_vertex_attribute(&builder, .R32_SFLOAT, size_of(float3))

    pipeline_builder_add_color_attachment_format(&builder, self.color_attachment.format)
    pipeline_builder_set_depth_attachment_format(&builder, .D32_SFLOAT)

    pipeline_builder_enable_depth_test(&builder, .GREATER)
    
    // Each color attachment needs blend state
    pipeline_builder_add_blend_attachment_default(&builder)

    pipeline_builder_add_push_constant_range(&builder, {
        stageFlags = {.VERTEX, .FRAGMENT},
        size = size_of(Instanced_Push_Constant),
    })

    pipeline_builder_set_cull_mode(&builder, {.BACK}, .COUNTER_CLOCKWISE)

    module := create_shader_module(#load("../shaders/instanced.spv")) or_return
    defer vk.DestroyShaderModule(get_device(), module, nil)

    pipeline_builder_add_shader_stage(&builder, .VERTEX,   module, "vertex_main")
    pipeline_builder_add_shader_stage(&builder, .FRAGMENT, module, "fragment_main")

    pipeline_builder_add_dynamic_state(&builder, .POLYGON_MODE_EXT)

    self.instanced.pipeline = pipeline_builder_build(&builder) or_return

    track_resources(
        self.instanced.pipeline,
    )

    return true
}

@(require_results)
instanced_init :: proc(self: ^Voxel_State) -> (ok: bool) {
    instanced_init_buffers(self)   or_return
    instanced_init_pipelines(self) or_return
    return true
}

instanced_upload_data :: proc(self: ^Voxel_State, cmd: vk.CommandBuffer, track: ^Resource_Tracker) -> (ok: bool) {
    staging_buffer := create_staging_buffer(self.instanced.vertex_buffer.size + self.instanced.index_buffer.size) or_return
    resource_tracker_push(track, staging_buffer)

    // Write to staging buffer
    buffer_write_mapped_memory(staging_buffer, CUBE_VERTICES[:])
    buffer_write_mapped_memory(staging_buffer, CUBE_INDICES[:], int(self.instanced.vertex_buffer.size))

    // Upload data to buffers
    cmd_copy_buffer(cmd,
        staging_buffer.buffer, self.instanced.vertex_buffer.buffer,
        self.instanced.vertex_buffer.size,
    )
    
    cmd_copy_buffer(cmd,
        staging_buffer.buffer, self.instanced.index_buffer.buffer,
        self.instanced.index_buffer.size,
        self.instanced.vertex_buffer.size,
    )

    return true
}

instanced_sync_voxel_data :: proc(self: ^Voxel_State) {
    i := 0
    mapped := transmute([^]int32_3)self.instanced.voxel_buffer.allocation_info.mapped_data
    for pos, _ in self.chunk.solid {
        mapped[i] = int32_3{
            i32(pos.x),
            i32(pos.y),
            i32(pos.z),
        }
        i += 1
    }
}

instanced_draw :: proc(self: ^Voxel_State, frame: ^Frame_Data, barrier: ^Pipeline_Barrier) {
    cmd := frame.command_buffer

    voxel_state_begin_rendering(self, cmd, barrier)
    
    // Bind pipeline
    vk.CmdBindPipeline(cmd, .GRAPHICS, self.instanced.pipeline.pipeline)

    // Bind vertex and instance buffers
    offset := vk.DeviceSize(0)
    vk.CmdBindVertexBuffers(cmd, 0, 1, &self.instanced.vertex_buffer.buffer, &offset)
    vk.CmdBindIndexBuffer(cmd, self.instanced.index_buffer.buffer, 0, .UINT32)
    
    // Bind push constant 
    push_constant := Instanced_Push_Constant {
        view_proj = self.matrices.projection * self.matrices.view,
        model     = self.matrices.model,
        color     = { 0.2, 1.0, 0.4, 1.0 },

        voxels = self.instanced.voxel_buffer_address,
    }
    vk.CmdPushConstants(cmd,
        self.instanced.pipeline.layout, {.VERTEX, .FRAGMENT},
        0, size_of(Instanced_Push_Constant), &push_constant)

    // Draw
    vk.CmdDrawIndexed(cmd, len(CUBE_INDICES), u32(len(self.chunk.solid)), 0, 0, 0)

    vk.CmdEndRendering(cmd)
}
