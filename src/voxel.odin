package main

import la  "core:math/linalg"
import sdl "vendor:sdl3"
import vk  "vendor:vulkan"

// Size of a chunk on any given axis
CHUNK_AXIS_SIZE :: 32

// Total amount of voxels per chunk
CHUNK_FLAT_SIZE :: CHUNK_AXIS_SIZE * CHUNK_AXIS_SIZE * CHUNK_AXIS_SIZE

Voxel :: bool
Chunk :: struct {
    data: [CHUNK_FLAT_SIZE]Voxel,
}

chunk_at :: proc(self: ^Chunk, x, y, z: int) -> ^Voxel {
    assert(x < 0 || x >= CHUNK_AXIS_SIZE, "Chunk access out of bounds")
    assert(y < 0 || y >= CHUNK_AXIS_SIZE, "Chunk access out of bounds")
    assert(z < 0 || z >= CHUNK_AXIS_SIZE, "Chunk access out of bounds")
    return &self.data[x + \
                      y * CHUNK_AXIS_SIZE + \
                      z * CHUNK_AXIS_SIZE * CHUNK_AXIS_SIZE]
}

Render_Method :: enum {
    Instanced,
    Mesher,
    Ray_Traversal,
}

Voxel_State :: struct {
    chunk: ^Chunk,

    method: Render_Method,

    // Viewport
    color_attachment: Image,
    depth_attachment: Image,
    viewport_extent:  vk.Extent2D,

    // Buffers

}

voxel_state_init_viewport :: proc(self: ^Voxel_State) -> (ok: bool) { 
    extent := get_largest_display_bounds()
    self.viewport_extent = get_window_extent()

    // Create color attachment
    builder := init_image_builder(.R16G16B16A16_SFLOAT,
        extent.width, 
        extent.height,
    )
    image_builder_set_usage(&builder, {.COLOR_ATTACHMENT, .TRANSFER_SRC})
    self.color_attachment = image_builder_build(&builder,
        allocation_info(.Gpu_Only),
    ) or_return
    
    // Create depth attachment
    image_builder_reset(&builder, .D32_SFLOAT,
        extent.width,
        extent.height,
    )
    image_builder_set_usage(&builder, {.DEPTH_STENCIL_ATTACHMENT})
    image_builder_set_view_subresource_range(&builder, {.DEPTH})
    self.depth_attachment = image_builder_build(&builder,
        allocation_info(.Gpu_Only),
    ) or_return


    track_resources( // Adds resources to the global tracker to be destroyed on exit.
        self.color_attachment,
        self.depth_attachment,
    )

    return true
}

create_voxel_state :: proc() -> (self: Voxel_State, ok: bool) {
    self.method = .Instanced

    voxel_state_init_viewport(&self)

    cmd := start_one_time_commands() or_return
        // Initial image layouts
        barrier: Pipeline_Barrier
        pipeline_barrier_add_image_barrier(&barrier,
            {.ALL_COMMANDS}, {},
            {.ALL_GRAPHICS}, {.DEPTH_STENCIL_ATTACHMENT_READ, .DEPTH_STENCIL_ATTACHMENT_WRITE},
            .UNDEFINED,
            .DEPTH_ATTACHMENT_OPTIMAL,
            self.depth_attachment.image,
            image_subresource_range({.DEPTH}),
        )
        cmd_pipeline_barrier(cmd, &barrier)
    submit_one_time_commands(&cmd)

    return self, true
}

destroy_voxel_state :: proc(self: ^Voxel_State) {
    // Free allocated memory
}

voxel_state_input :: proc(self: ^Voxel_State, event: sdl.Event) {
    #partial switch event.type {
    case .WINDOW_RESIZED: {
        self.viewport_extent = get_window_extent()
        self.viewport_extent.width = min(
            self.viewport_extent.width,
            self.color_attachment.extent.width,
        )
        self.viewport_extent.height = min(
            self.viewport_extent.height,
            self.color_attachment.extent.height,
        )
    }
    }
}

voxel_state_draw :: proc(self: ^Voxel_State) {
    barrier: Pipeline_Barrier

    if frame, ok := start_frame(); ok {
        cmd := frame.command_buffer
        
        voxel_state_begin_rendering(self, cmd, &barrier)
        vk.CmdEndRendering(cmd)

        voxel_state_present_frame(self, cmd, frame, &barrier) 
    }
}

voxel_state_begin_rendering :: proc(self: ^Voxel_State,
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
            float32 = {0.2, 0.2, 0.2, 1.0},
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

voxel_state_present_frame :: proc(self: ^Voxel_State,
    cmd: vk.CommandBuffer,
    frame: ^Frame_Data,
    barrier: ^Pipeline_Barrier,
) {
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

    present_frame(frame,
            {.COPY}, {.TRANSFER_WRITE},
            .TRANSFER_DST_OPTIMAL)
}
