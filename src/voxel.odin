package main

import la  "core:math/linalg"

import sdl "vendor:sdl3"
import vk  "vendor:vulkan"
import im "../lib/imgui"

VOXEL_COLOR :: float4 {1.0, 0.2, 0.2, 1.0}
WORLD_SIZE  :: 4

Render_Method :: enum i32 {
    Mesher,
    Mesher_Gpu,
    Ray_Traversal,
}

Voxel_State :: struct {
    chunk: Chunk,
    world: World,

    method: Render_Method,

    // Viewport
    color_attachment: Image,
    depth_attachment: Image,
    viewport_extent:  vk.Extent2D,
    
    mesher: struct {
        vertex_buffer:  Buffer,
        index_buffer:   Buffer,
        staging_buffer: Buffer,
        vertex_buffer_address: vk.DeviceAddress,

        chunk_objects: []Mesher_Chunk_Objects,

        pipeline: Pipeline,
        
        vertex_data: [dynamic]Vertex,
        index_data:  [dynamic]u32,
        
        update_queued: bool,
    },

    camera:      Camera, 

    matrices: struct {
        projection: float4x4,
        view:       float4x4,
        model:      float4x4,
    },

    gui: struct {
        wireframe: bool,

        sphere_origin: int32_3,
        sphere_radius: i32,

        cube_origin:     int32_3,
        cube_dimensions: int32_3,
        
        remove_min: int32_3,
        remove_max: int32_3,
    }
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
    self.chunk = create_chunk()
    chunk_add_cube(&self.chunk, {0, 0, 0}, {64, 4, 64})
    mesher_build_mesh(&self)

    self.world = create_world(WORLD_SIZE)

    self.method = .Mesher

    voxel_state_init_viewport(&self) or_return

    mesher_init(&self) or_return

    onetime_tracker := create_resource_tracker(); defer destroy_resource_tracker(&onetime_tracker)
    cmd := start_one_time_commands() or_return

        // Initial depth attachment layout
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

    // Setup projection, view and model matrices
    self.matrices.projection = get_projection_matrix()

    self.camera.position = float3{0.0, 0.0, 20.0}
    self.matrices.view = camera_view_matrix(&self.camera)
 
    self.matrices.model = la.matrix4_scale(float3{0.5, 0.5, 0.5})
    self.matrices.model *= la.matrix4_translate(float3{
        -f32(CHUNK_SIZE) / 2.0,
        -f32(CHUNK_SIZE) / 2.0,
        -f32(CHUNK_SIZE) / 2.0,
    }) 

    return self, true
}

destroy_voxel_state :: proc(self: ^Voxel_State) {
    destroy_world(&self.world)
    destroy_chunk(&self.chunk)

    vk.DeviceWaitIdle(get_device())
    mesher_destroy(self)
}

get_projection_matrix :: proc(fov: f32 = 80.0) -> float4x4 {
    extent := get_window_extent()
    aspect := f32(extent.width) / f32(extent.height)

    return matrix4_perspective_reverse_z_f32(la.to_radians(fov), aspect, 0.1)
}

voxel_state_event :: proc(self: ^Voxel_State, event: sdl.Event) {
    #partial switch event.type {
    case .WINDOW_RESIZED:
        self.viewport_extent = get_window_extent()
        self.viewport_extent.width = min(
            self.viewport_extent.width,
            self.color_attachment.extent.width,
        )
        self.viewport_extent.height = min(
            self.viewport_extent.height,
            self.color_attachment.extent.height,
        )

        self.matrices.projection = get_projection_matrix()
    }

    camera_input(&self.camera, event)
}

voxel_state_update :: proc(self: ^Voxel_State, dt: f32) {
    camera_update(&self.camera, dt)
}

voxel_state_draw_imgui :: proc(self: ^Voxel_State) {
    imgui_new_frame()
    
    update_voxels := false
    if im.begin("Debug", nil, {.Always_Auto_Resize}) { 
        im.checkbox("Wireframe", &self.gui.wireframe)
    
        if im.begin_menu("Place") {
            im.text("Sphere:")
            im.input_int3("sphere::origin", &self.gui.sphere_origin)
            im.input_int("sphere::radius", &self.gui.sphere_radius)
            
            if im.button("sphere::place") {
                o := self.gui.sphere_origin
                oi := int3{
                    int(o.x),
                    int(o.y),
                    int(o.z)
                }
                chunk_add_sphere(&self.chunk, oi, int(self.gui.sphere_radius))
                update_voxels = true
            }

            im.text("Cube:")
            im.input_int3("cube::origin", &self.gui.cube_origin)
            im.input_int3("cube::dimensions", &self.gui.cube_dimensions)
            if im.button("cube::place") {
                o := self.gui.cube_origin
                oi := int3{
                    int(o.x),
                    int(o.y),
                    int(o.z)
                }

                d := self.gui.cube_dimensions
                di := int3{
                    int(d.x),
                    int(d.y),
                    int(d.z),
                }

                chunk_add_cube(&self.chunk, oi, di)
                update_voxels = true
            }

            im.end_menu()
        }

        if im.begin_menu("Remove") {
            im.input_int3("remove::min", &self.gui.remove_min)
            im.input_int3("remove::max", &self.gui.remove_max)
            if im.button("remove") {
                for z in self.gui.remove_min.z..<self.gui.remove_max.z {
                    for y in self.gui.remove_min.y..<self.gui.remove_max.y {
                        for x in self.gui.remove_min.x..<self.gui.remove_max.x {
                            p := int3{
                                int(x),
                                int(y),
                                int(z),
                            }
                            if !chunk_position_in_bounds(p) { continue }
                            chunk_unset(&self.chunk, p)
                            update_voxels = true
                        }
                    }
                }
                
            }
            im.end_menu()
        }

        items := []cstring {
            "Mesher",
        }
        im.combo_char("Rendering Method", transmute(^i32)&self.method, raw_data(items[:]), i32(len(items)))
    }; im.end()
    
    if update_voxels {
        mesher_build_mesh(self)
    }

    im.render()
}

voxel_state_draw :: proc(self: ^Voxel_State) {
    barrier: Pipeline_Barrier

    voxel_state_draw_imgui(self)
    self.matrices.view = camera_view_matrix(&self.camera)


    if frame, ok := start_frame(); ok {
        // Set options
        vk.CmdSetPolygonModeEXT(frame.command_buffer, .LINE if self.gui.wireframe else .FILL)

        #partial switch self.method {
        case .Mesher:       mesher_draw(self, frame, &barrier)
        } 
        voxel_state_present_frame(self, frame, &barrier)
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

voxel_state_present_frame :: proc(self: ^Voxel_State,
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
