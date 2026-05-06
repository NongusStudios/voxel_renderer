package main

import "core:log"
import "core:math"
import "core:time"
import "core:math/noise"
import la  "core:math/linalg"

import sdl "vendor:sdl3"
import vk  "vendor:vulkan"
import im "../lib/imgui"

VOXEL_COLOR :: float4 {0.3, 1.0, 0.4, 1.0}
VOXEL_UNIT_SIZE :: 2
WORLD_SIZE  :: 16

Render_Method :: enum i32 {
    Mesher,
    Ray_Traversal,
    Mesher_Gpu,
}

Voxel_State :: struct {
    world: World,

    method: Render_Method,

    // Viewport
    color_attachment: Image,
    depth_attachment: Image,
    viewport_extent:  vk.Extent2D,
    
    mesher: struct {
        chunk_data: []Mesher_Chunk_Data,

        pipeline: Pipeline,
        
        vertex_data: [dynamic]Vertex,
        index_data:  [dynamic]u32,
        quad_data:   [dynamic]Mesher_Quad,
    },

    ray: struct {
        pipeline: Pipeline,
        descriptor_group: Descriptor_Group,
        descriptor_layout: vk.DescriptorSetLayout,
        descriptor_set: vk.DescriptorSet,
        voxel_buffer: Buffer,
    },

    grid_pipeline: Pipeline,

    camera:      Camera, 

    matrices: struct {
        projection: float4x4,
        view:       float4x4,
        model:      float4x4,
    },

    gui: struct {
        wireframe: bool,
        grid: bool,

        sphere_origin: int32_3,
        sphere_radius: i32,

        cube_origin:     int32_3,
        cube_dimensions: int32_3,
        
        remove_min: int32_3,
        remove_max: int32_3,
        
        triangle_count: int,
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
    image_builder_set_usage(&builder,
        {.COLOR_ATTACHMENT, .TRANSFER_SRC, .TRANSFER_DST, .STORAGE})
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

voxel_state_create_pipelines :: proc(self: ^Voxel_State) -> (ok: bool) {
    builder := create_pipeline_builder(); defer destroy_pipeline_builder(&builder)
    pipeline_builder_add_color_attachment_format(&builder, self.color_attachment.format)
    pipeline_builder_set_depth_attachment_format(&builder, .D32_SFLOAT)
    pipeline_builder_add_blend_attachment_alphablend(&builder)
    pipeline_builder_enable_depth_test(&builder)

    pipeline_builder_add_push_constant_range(&builder, {
        stageFlags = {.VERTEX, .FRAGMENT},
        size = size_of(Grid_Push_Constant),
    })

    pipeline_builder_set_topology(&builder, .LINE_LIST)

    module := create_shader_module(#load("../shaders/grid.spv")) or_return
    defer vk.DestroyShaderModule(get_device(), module, nil)

    pipeline_builder_add_shader_stage(&builder, .VERTEX,   module, "vertex_main")
    pipeline_builder_add_shader_stage(&builder, .FRAGMENT, module, "fragment_main")

    pipeline_builder_add_dynamic_state(&builder, .POLYGON_MODE_EXT)

    self.grid_pipeline = pipeline_builder_build(&builder) or_return

    track_resources(
        self.grid_pipeline,
    )

    return true
}

voxel_state_generate_terrain :: proc(self: ^Voxel_State) {
    seed := i64(0b100011100101)
    for z in 0..<WORLD_SIZE*CHUNK_SIZE {
        for x in 0..<WORLD_SIZE*CHUNK_SIZE {
            n := noise.noise_2d_improve_x(seed, {
                f64(x)*0.008,
                f64(z)*0.008,
            })
            
            n =  (n + 1.0) * 0.5
            h := int(math.round(n * CHUNK_SIZE))
            for y in 0..<h+1 {
                world_set(&self.world, {x, y, z})
            }
        }
    }
}

create_voxel_state :: proc() -> (self: Voxel_State, ok: bool) {
    self.method = .Mesher
    self.world = create_world(WORLD_SIZE)
    
    benchmark_start_reading("terrain_gen")
    voxel_state_generate_terrain(&self)    
    benchmark_end_reading("terrain_gen")
    log.info("Terrain generated in: ", time.duration_seconds(benchmark_get_last_reading("terrain_gen")), "s")
    
    voxel_state_init_viewport(&self) or_return
    voxel_state_create_pipelines(&self) or_return

    mesher_init(&self) or_return
    ray_init(&self) or_return

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

    self.camera.position = float3{0, CHUNK_SIZE * 2 + 5, 0}
    self.matrices.view = camera_view_matrix(&self.camera)
 
    self.matrices.model = la.matrix4_scale(float3{VOXEL_UNIT_SIZE, VOXEL_UNIT_SIZE, VOXEL_UNIT_SIZE})
    self.matrices.model *= la.matrix4_translate(float3{
        -(WORLD_SIZE * CHUNK_SIZE) / 2.0,
        0,
        -(WORLD_SIZE * CHUNK_SIZE) / 2.0,
    }) 

    return self, true
}

destroy_voxel_state :: proc(self: ^Voxel_State) {
    destroy_world(&self.world)

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
    @(static)
    elapsed: f32 = 1.0
    elapsed += get_app().dt
    
    @(static)
    frame_times: f32 = 0.0
    frame_times += get_app().dt

    @(static)
    frame_avg: f32 = 0.0

    @(static)
    frame_count := 0
    frame_count += 1

    if elapsed >= 0.5 {
        frame_avg = frame_times / f32(frame_count)
        frame_times = 0.0
        frame_count = 0
        elapsed = 0.0
    }

    imgui_new_frame()
    
    if im.begin("Debug", nil, {.Always_Auto_Resize}) { 
        im.checkbox("Wireframe", &self.gui.wireframe)
        im.checkbox("Draw Grid", &self.gui.grid)
    
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
                world_add_sphere(&self.world, oi, int(self.gui.sphere_radius))
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

                world_add_cube(&self.world, oi, di)
            }

            im.end_menu()
        }

        if im.begin_menu("Remove") {
            im.input_int3("remove::start", &self.gui.remove_min)
            im.input_int3("remove::extent", &self.gui.remove_max)
            if im.button("remove") {
                for z in self.gui.remove_min.z..<self.gui.remove_max.z+self.gui.remove_min.z {
                    for y in self.gui.remove_min.y..<self.gui.remove_max.y+self.gui.remove_min.y {
                        for x in self.gui.remove_min.x..<self.gui.remove_max.x+self.gui.remove_min.x {
                            p := int3{
                                int(x),
                                int(y),
                                int(z),
                            }
                            if !world_position_in_bounds(&self.world, p) { continue }
                            world_unset(&self.world, p)
                        }
                    }
                }
                
            }
            im.end_menu()
        }

        items := []cstring {
            "Mesher",
            "Ray_Traversal"
        }
        im.combo_char("Rendering Method", transmute(^i32)&self.method, raw_data(items[:]), i32(len(items)))
        im.text("Frame Time: %f ms", frame_avg * 1000)
        im.text("Avg Mesh Gen: %i us", int(time.duration_microseconds(
            benchmark_get_metric_avg("chunk_mesh"),
        )))
        im.text("Triangle Count: %li", self.gui.triangle_count)
    }; im.end()
    
    im.render()
}

voxel_state_draw_grid :: proc(self: ^Voxel_State, cmd: vk.CommandBuffer, view_proj: float4x4) {
    if self.gui.grid {
        vk.CmdBindPipeline(cmd, .GRAPHICS, self.grid_pipeline.pipeline)
        
        push_constant := Grid_Push_Constant {
            view_proj = view_proj,
            model     = self.matrices.model,
            world_size = u32(self.world.size),
            chunk_size = CHUNK_SIZE,
        }

        vk.CmdPushConstants(cmd,
            self.grid_pipeline.layout,
            {.VERTEX, .FRAGMENT},
            0, size_of(Grid_Push_Constant),
            &push_constant,
        )

        instance_count := self.world.size+1
        instance_count *= instance_count
        vk.CmdDraw(cmd, 6, u32(instance_count), 0, 0)
    }
}

voxel_state_draw :: proc(self: ^Voxel_State) {
    barrier: Pipeline_Barrier

    voxel_state_draw_imgui(self)
    self.matrices.view = camera_view_matrix(&self.camera)


    if frame, ok := start_frame(); ok {
        // Set options
        vk.CmdSetPolygonModeEXT(frame.command_buffer, .LINE if self.gui.wireframe else .FILL)

        #partial switch self.method {
        case .Mesher:        mesher_draw(self, frame, &barrier)
        case .Ray_Traversal: ray_draw(self, frame, &barrier)
        } 
    }
}
