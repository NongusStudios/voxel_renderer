package main

import "core:math"
import la "core:math/linalg"
import sdl "vendor:sdl3"

Camera :: struct {
    position: float3,
    yaw: f32,
    pitch: f32,
}

camera_forward_vector :: proc(self: ^Camera) -> float3 {
    return {
        -math.sin(self.yaw),
        0.0,
        -math.cos(self.yaw),
    }
}

camera_target_vector :: proc(self: ^Camera) -> float3 {
    return {
        -math.sin(self.yaw) * math.cos(self.pitch),
        math.sin(self.pitch),
        -math.cos(self.yaw) * math.cos(self.pitch),
    }
}

camera_right_vector :: proc(self: ^Camera) -> float3 {
    return {
        math.sin(self.yaw + math.PI * 0.5),
        0.0,
        math.cos(self.yaw + math.PI * 0.5),
    }
}

camera_input :: proc(self: ^Camera, event: sdl.Event) {
    if get_app().mouse_captured && event.type == .MOUSE_MOTION {
        sensitivity: f32 = 0.005
        self.yaw   -= event.motion.xrel * sensitivity

        self.pitch -= event.motion.yrel * sensitivity
        self.pitch = clamp(self.pitch, -89.0 * la.RAD_PER_DEG, 89.0 * la.RAD_PER_DEG)
    }
}

camera_update :: proc(self: ^Camera, dt: f32) {
    keys := sdl.GetKeyboardState(nil)

    speed := 10.0 * dt
    forward := camera_forward_vector(self)
    forward.y = 0.0

    right   := camera_right_vector(self)

    if keys[sdl.Scancode.W] {
        self.position += forward * speed
    }
    if keys[sdl.Scancode.S] {
        self.position -= forward * speed
    }

    if keys[sdl.Scancode.D] {
        self.position += right * speed
    }
    if keys[sdl.Scancode.A] {
        self.position -= right * speed
    }

    if keys[sdl.Scancode.Q] {
        self.position.y += speed
    }
    if keys[sdl.Scancode.E] {
        self.position.y -= speed
    }
}

camera_view_matrix :: proc(self: ^Camera) -> float4x4 {
    target := camera_target_vector(self) + self.position
    return la.matrix4_look_at(
        self.position,
        target,
        float3{0.0, 1.0, 0.0},
    )
}
