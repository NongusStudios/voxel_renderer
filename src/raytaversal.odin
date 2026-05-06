package main

import "core:math"
import sdl "vendor:sdl3"
import vk  "vendor:vulkan"

Ray_Push_Constant :: struct {
    viewport_extent: vk.Extent2D,
}

ray_init_voxel_objects :: proc(self: ^Voxel_State) -> (ok: bool) {
    self.ray.voxel_buffer = create_buffer(
        vk.DeviceSize(self.world.size * self.world.size * self.world.size *
        CHUNK_FLAT_SIZE * size_of(Voxel)),
        {.STORAGE_BUFFER}, allocation_info(.Cpu_To_Gpu, {}, {.Mapped})
    ) or_return

    track_resources(self.ray.voxel_buffer)

    return true
}

ray_init_descriptors :: proc(self: ^Voxel_State) -> (ok: bool) {
    builder := create_descriptor_group_builder()
    defer destroy_descriptor_group_builder(builder)

    descriptor_group_builder_add_set(&builder)
    descriptor_group_builder_add_binding(&builder, .STORAGE_IMAGE,  {.COMPUTE})
    descriptor_group_builder_add_binding(&builder, .STORAGE_BUFFER, {.COMPUTE})

    self.ray.descriptor_group = descriptor_group_builder_build(&builder) or_return
    self.ray.descriptor_layout = self.ray.descriptor_group.layouts[0]
    self.ray.descriptor_set = self.ray.descriptor_group.sets[0]

    // Write to descriptor sets
    writer := create_descriptor_writer()
    defer destroy_descriptor_writer(&writer)

    descriptor_writer_add_single_image_write(&writer, .STORAGE_IMAGE, vk.DescriptorImageInfo {
        imageLayout = .GENERAL,
        imageView   = self.color_attachment.view,
    })

    descriptor_writer_add_single_buffer_write(&writer, .STORAGE_BUFFER, vk.DescriptorBufferInfo {
        buffer = self.ray.voxel_buffer.buffer,
        range  = self.ray.voxel_buffer.size,
    })

    descriptor_writer_write_set(&writer, self.ray.descriptor_set)

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

ray_destroy :: proc(self: ^Voxel_State) {

}

ray_upload_voxels :: proc(self: ^Voxel_State) {
    buffer_write_mapped_memory(self.ray.voxel_buffer, self.world.chunks[:])
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
    ray_begin_rendering(self, cmd, barrier)
    
    vk.CmdBindPipeline(cmd, .COMPUTE, self.ray.pipeline.pipeline)

    pconst := Ray_Push_Constant{
        viewport_extent = self.viewport_extent,
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
