package main

import "core:log"
import "core:encoding/ini"
import "core:math"
import la "core:math/linalg"
import sdl "vendor:sdl3"
import vk  "vendor:vulkan"

Ray_Push_Constant :: struct {
    inv_projection: float4x4,
    inv_view: float4x4,
    color: float4,
    origin: float3,
    _: byte,
    viewport_extent: uint2,
    world_size: u32,
}

ray_init_voxel_objects :: proc(self: ^Voxel_State) -> (ok: bool) {
    self.ray.voxel_staging_buffer = create_staging_buffer(
        vk.DeviceSize(self.world.size * self.world.size * self.world.size *
        CHUNK_FLAT_SIZE * size_of(Voxel)),
    ) or_return

    di := u32(self.world.size * CHUNK_SIZE)
    builder := init_image_builder(.R32G32B32A32_UINT, di / 4, di / 4, di / 8)
    image_builder_set_usage(&builder, {.TRANSFER_DST, .SAMPLED})
    image_builder_set_type(&builder, .D3, .D3)
    self.ray.voxel_image = image_builder_build(&builder, allocation_info(.Gpu_Only)) or_return

    cmd := start_one_time_commands() or_return
    barrier: Pipeline_Barrier
    pipeline_barrier_add_image_barrier(&barrier,
        {.ALL_COMMANDS},   {},
        {.COMPUTE_SHADER}, {.SHADER_READ},
        .UNDEFINED, .GENERAL,
        self.ray.voxel_image.image, image_subresource_range({.COLOR}),
    )
    cmd_pipeline_barrier(cmd, &barrier)
    submit_one_time_commands(&cmd)

    track_resources(
        self.ray.voxel_staging_buffer,
        self.ray.voxel_image,
    )

    return true
}

ray_init_descriptors :: proc(self: ^Voxel_State) -> (ok: bool) {
    builder := create_descriptor_group_builder()
    defer destroy_descriptor_group_builder(builder)

    descriptor_group_builder_add_set(&builder)
    descriptor_group_builder_add_binding(&builder, .STORAGE_IMAGE, {.COMPUTE})
    descriptor_group_builder_add_binding(&builder, .SAMPLED_IMAGE, {.COMPUTE})

    self.ray.descriptor_group = descriptor_group_builder_build(&builder) or_return
    self.ray.descriptor_layout = self.ray.descriptor_group.layouts[0]
    self.ray.descriptor_set = self.ray.descriptor_group.sets[0]

    // Write to descriptor sets
    writer := create_descriptor_writer()
    defer destroy_descriptor_writer(&writer)

    descriptor_writer_target_set(&writer, self.ray.descriptor_set)
    descriptor_writer_add_single_image_write(&writer, .STORAGE_IMAGE, vk.DescriptorImageInfo {
        imageLayout = .GENERAL,
        imageView   = self.color_attachment.view,
    })

    descriptor_writer_add_single_image_write(&writer, .SAMPLED_IMAGE, vk.DescriptorImageInfo {
        imageLayout = .GENERAL,
        imageView   = self.ray.voxel_image.view,
    })

    descriptor_writer_write(&writer)

    track_resources(
        self.ray.descriptor_group,
    )

    return true
}

ray_init_pipelines :: proc(self: ^Voxel_State) -> (ok: bool) {
    builder := init_compute_pipeline_builder()

    module := create_shader_module(#load("../shaders/ray.spv")) or_return
    defer vk.DestroyShaderModule(get_device(), module, nil)

    compute_pipeline_builder_set_shader_module(&builder, module)

    compute_pipeline_builder_add_descriptor_layout(&builder, self.ray.descriptor_layout)
    compute_pipeline_builder_add_push_constant_range(&builder, {
        stageFlags = {.COMPUTE},
        size = size_of(Ray_Push_Constant),
        offset = 0,
    })

    self.ray.pipeline = compute_pipeline_builder_build(&builder) or_return

    track_resources(
        self.ray.pipeline
    )
    
    return true
}

ray_init :: proc(self: ^Voxel_State) -> (ok: bool) {
    ray_init_voxel_objects(self) or_return
    ray_init_descriptors(self) or_return
    ray_init_pipelines(self) or_return

    return true
}

ray_upload_voxels :: proc(self: ^Voxel_State, cmd: vk.CommandBuffer, barrier: ^Pipeline_Barrier) {
    if !self.world.flat_dirty {
        return
    }
    self.world.flat_dirty = false
    buffer_write_mapped_memory(self.ray.voxel_staging_buffer, self.world.packed_voxels)

    pipeline_barrier_add_image_barrier(barrier,
        {.ALL_COMMANDS}, {},
        {.COPY},         {.TRANSFER_WRITE},
        .GENERAL, .TRANSFER_DST_OPTIMAL,
        self.ray.voxel_image.image, image_subresource_range({.COLOR}),
    )
    cmd_pipeline_barrier(cmd, barrier)

    cmd_copy_buffer_to_image(cmd,
        self.ray.voxel_staging_buffer.buffer,
        self.ray.voxel_image.image, self.ray.voxel_image.extent,
        image_subresource_layers({.COLOR}),
    )

    pipeline_barrier_add_image_barrier(barrier,
        {.COPY}, {.TRANSFER_WRITE},
        {.COMPUTE_SHADER}, {.SHADER_READ},
        .TRANSFER_DST_OPTIMAL, .GENERAL,
        self.ray.voxel_image.image, image_subresource_range({.COLOR}),
    )
    cmd_pipeline_barrier(cmd, barrier)
}

ray_begin_rendering :: proc(self: ^Voxel_State,
    cmd: vk.CommandBuffer,
    barrier: ^Pipeline_Barrier
) {
    // Transition output image to CLEAR stage
    pipeline_barrier_add_image_barrier(barrier,
        {.ALL_COMMANDS}, {},
        {.CLEAR}, {.MEMORY_WRITE},
        .UNDEFINED,
        .GENERAL,
        self.color_attachment.image,
        image_subresource_range({.COLOR}),
    )
    cmd_pipeline_barrier(cmd, barrier)

    color := vk.ClearColorValue {
        float32 = {0., 0., 0., 1.0},
    }
    subresource := image_subresource_range({.COLOR})
    vk.CmdClearColorImage(cmd,
        self.color_attachment.image, .GENERAL,
        &color, 1, &subresource,
    )

    // Transition output image to COMPUTE stage
    pipeline_barrier_add_image_barrier(barrier,
        {.ALL_COMMANDS}, {},
        {.COMPUTE_SHADER}, {.SHADER_READ, .SHADER_WRITE},
        .GENERAL,
        .GENERAL,
        self.color_attachment.image,
        image_subresource_range({.COLOR}),
    )
    cmd_pipeline_barrier(cmd, barrier)
    
}

ray_present_frame :: proc(self: ^Voxel_State,
    frame: ^Frame_Data,
    barrier: ^Pipeline_Barrier
) {
    cmd := frame.command_buffer
    swapchain_image := get_swapchain().images[frame.image_index]
    
    // Transition output image to be copied to the current swapchain image
    subresource := image_subresource_range({.COLOR})
    pipeline_barrier_add_image_barrier(barrier,
        {.COMPUTE_SHADER}, {.SHADER_READ, .SHADER_WRITE},
        {.COPY}, {.TRANSFER_READ},
        .GENERAL, .TRANSFER_SRC_OPTIMAL,
        self.color_attachment.image,
        subresource
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

ray_draw :: proc(self: ^Voxel_State, frame: ^Frame_Data, barrier: ^Pipeline_Barrier) {
    cmd := frame.command_buffer

    ray_upload_voxels(self, cmd, barrier)
    ray_begin_rendering(self, cmd, barrier)
    
    vk.CmdBindPipeline(cmd, .COMPUTE, self.ray.pipeline.pipeline)

    extent := uint2{
        self.viewport_extent.width,
        self.viewport_extent.height,
    }

    pixel_to_clip := float4x4{
        2.0/f32(extent.x),  0.0,               0.0, -1.0,
        0.0,                2.0/f32(extent.y), 0.0, -1.0,
        0.0,                0.0,               1.0,  0.0,
        0.0,                0.0,               0.0,  1.0
    }

    pconst := Ray_Push_Constant{
        viewport_extent = extent,
        world_size = u32(self.world.size),
        color = VOXEL_COLOR,
        origin = world_to_grid_local_position(self.camera.position, self.world.size),
        inv_projection = la.inverse(self.matrices.projection) * pixel_to_clip,
        inv_view       = la.inverse(self.matrices.view),
    }
    vk.CmdPushConstants(cmd,
        self.ray.pipeline.layout, {.COMPUTE},
        0, size_of(Ray_Push_Constant), &pconst,
    )

    vk.CmdBindDescriptorSets(cmd, .COMPUTE,
        self.ray.pipeline.layout, 0, 1,
        &self.ray.descriptor_set, 0, nil
    )

    dispatch_x := u32(math.ceil(f32(self.viewport_extent.width)  / 8))
    dispatch_y := u32(math.ceil(f32(self.viewport_extent.height) / 8))
    vk.CmdDispatch(cmd, dispatch_x, dispatch_y, 1)

    ray_present_frame(self, frame, barrier)
}
