package main

import "core:log"
import sdl "vendor:sdl3"
import vk  "vendor:vulkan"

WIDTH  :: 1600
HEIGHT :: 900
TITLE  : cstring : "vulkan_template"

App :: struct {
    window:   ^sdl.Window,
    running:   bool,
    minimized: bool,

    voxel_state: Voxel_State,
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
    }

    voxel_state_input(&self.voxel_state, event)
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

    for self.running { 
        app_wait_if_minimized()
        for sdl.PollEvent(&event) {
            //imgui_process_event(&event)
            app_handle_event(event)
        } 

        voxel_state_draw(&self.voxel_state)
    }
}
