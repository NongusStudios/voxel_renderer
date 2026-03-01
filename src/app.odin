package main

import "core:log"
import sdl "vendor:sdl3"
import vk  "vendor:vulkan"

WIDTH  :: 1600
HEIGHT :: 900
TITLE  : cstring : "voxel_renderer"

App :: struct {
    window:   ^sdl.Window,
    running:   bool,
    minimized: bool,

    voxel_state: Voxel_State,
    mouse_captured: bool,
}

@(private="file")
self: ^App
get_app :: proc() -> ^App { return self }

get_window_extent :: proc() -> vk.Extent2D {
    w, h: i32
    sdl.GetWindowSizeInPixels(get_app().window, &w, &h)
    return vk.Extent2D {
        width  = u32(w),
        height = u32(h),
    }
}

get_largest_display_bounds :: proc() -> vk.Extent2D {
    display_count: i32
    displays := sdl.GetDisplays(&display_count)
    
    largest_w: i32 = 0
    largest_h: i32 = 0
    rect: sdl.Rect
    for i: i32 = 0; i < display_count; i += 1 {
        sdl.GetDisplayBounds(displays[i], &rect)
        if rect.w > largest_w { largest_w = rect.w }
        if rect.h > largest_h { largest_h = rect.h }
    }

    return vk.Extent2D {
        width  = u32(largest_w),
        height = u32(largest_h),
    }
}

init_app :: proc() -> (ok: bool) {
    self = new(App)
    defer if !ok { free(self) }

    if !sdl.Init({.VIDEO, .AUDIO}) {
        log.errorf("failed to initialise sdl3:\n%s", sdl.GetError())
        return false
    }

    self.window = sdl.CreateWindow(TITLE, WIDTH, HEIGHT, {.VULKAN})
    if self.window == nil {
        log.errorf("failed to create a window:\n%s", sdl.GetError())
        return false
    }

    self.mouse_captured = true
    sdl.SetWindowRelativeMouseMode(self.window, self.mouse_captured) or_return
    
    init_vulkan() or_return
    init_imgui()  or_return

    self.voxel_state = create_voxel_state() or_return

    self.running = true
    return true
}

destroy_app :: proc() {
    destroy_voxel_state(&self.voxel_state)
    cleanup_vulkan()

    sdl.DestroyWindow(self.window)
    sdl.Quit()
    
    free(self)
}

app_handle_resize :: proc() {
    resize_swapchain()
}

app_handle_event :: proc(event: sdl.Event) {
    #partial switch event.type {
    case .QUIT: self.running = false
    case .WINDOW_MINIMIZED: self.minimized = true
    case .WINDOW_RESIZED:   app_handle_resize()
    case .KEY_DOWN:
        switch event.key.key {
            case sdl.K_ESCAPE:
                self.mouse_captured = !self.mouse_captured
                ok := sdl.SetWindowRelativeMouseMode(self.window, self.mouse_captured)
        }
    }
    
    voxel_state_event(&self.voxel_state, event)
}

app_wait_if_minimized :: proc() {
    if self.minimized { // If minimized wait for RESTORED event
        event: sdl.Event
        for sdl.WaitEvent(&event) {
            app_handle_resize()
            self.minimized = false
        }
    }
}

app_run :: proc() {
    event: sdl.Event
    barrier: Pipeline_Barrier
    
    last_time: f32 = 0.0
    for self.running {
        now := f32(sdl.GetTicks()) / 1000.0
        dt := now - last_time
        last_time = now

        app_wait_if_minimized()

        for sdl.PollEvent(&event) {
            imgui_process_event(&event)
            app_handle_event(event)
        }
        
        voxel_state_update(&self.voxel_state, dt)
        voxel_state_draw(&self.voxel_state)
    }
}
