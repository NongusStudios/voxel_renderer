package main

import "core:math"
import la "core:math/linalg"
import sdl "vendor:sdl3"

CAMERA_SPEED :: 30.0
CAMERA_FOV   :: 80.0

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

camera_input :: proc(self: ^Camera, event: ^sdl.Event) {
    if get_app().mouse_captured && event.type == .MOUSE_MOTION {
        sensitivity: f32 = 0.005
        self.yaw   -= event.motion.xrel * sensitivity

        self.pitch -= event.motion.yrel * sensitivity
        self.pitch = clamp(self.pitch, -89.0 * la.RAD_PER_DEG, 89.0 * la.RAD_PER_DEG)
    }
}

camera_update :: proc(self: ^Camera, dt: f32) {
    keys := sdl.GetKeyboardState(nil)

    speed := CAMERA_SPEED * dt
    if keys[sdl.Scancode.LSHIFT] {
        speed *= 5.0
    }

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

camera_rotation_matrix :: proc(self: ^Camera) -> float4x4 {
    forward := camera_forward_vector(self)
    right := camera_right_vector(self)
    up := la.cross(right, forward)

    return float4x4{
        right.x,   up.x,   forward.x,   0,
        right.y,   up.y,   forward.y,   0,
        right.z,   up.z,   forward.z,   0,
        0,         0,      0,           1,
    }
}

camera_pixel_to_ray_matrix :: proc(self: ^Camera, extent: uint2, fov: f32 = CAMERA_FOV) -> float4x4 {
    aspect := f32(extent.x) / f32(extent.y)
    tan_fov := math.tan(fov * 0.5 * math.PI / 180.0)

    // Center pixel: (0..w, 0..h) → (-0.5..0.5, -0.5..0.5)
    center_pixel := la.identity(float4x4)
    center_pixel[0][2] = 0.5
    center_pixel[1][2] = 0.5

    pixel_to_uv := la.identity(float4x4)
    pixel_to_uv[0][0] =  2.0 / f32(extent.x)
    pixel_to_uv[1][1] = -2.0 / f32(extent.y)
    pixel_to_uv[0][2] = -1.0
    pixel_to_uv[1][2] =  1.0
    
    uv_to_view := la.identity(float4x4)
    uv_to_view[0][0] = tan_fov * max(aspect, 1.0)
    uv_to_view[1][1] = tan_fov / min(1.0, aspect)

    swap_yz := float4x4{
        1, 0, 0, 0,
        0, 0, 1, 0,
        0, 1, 0, 0,
        0, 0, 0, 1,
    }

    rotation := camera_rotation_matrix(self)
    translation := la.identity(float4x4)
    translation[0][3] = self.position.x
    translation[1][3] = self.position.y
    translation[2][3] = self.position.z

    return center_pixel * pixel_to_uv * uv_to_view * swap_yz * rotation * translation
}
