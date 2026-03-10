package main

import "core:math"
World :: struct {
    chunks: []Chunk,
    size: int,
    updates: map[int3]u8,
}

create_world :: proc(size: int) -> (self: World) {
    self.size = size
    self.chunks = make([]Chunk, size * size * size)
    for &chunk in self.chunks {
        chunk_init(&chunk)
    }
    self.updates = make(map[int3]u8)
    return
}

destroy_world :: proc(self: ^World) {
    for &chunk in self.chunks {
        destroy_chunk(&chunk)
    }
    delete(self.chunks)
    delete(self.updates)
}

world_translate_coords :: proc(world_pos: int3) -> (chunk: int3, pos: int3) { 
    chunk = world_pos / CHUNK_SIZE
    pos   = world_pos % CHUNK_SIZE
    return
}

world_position_in_bounds :: proc(self: ^World, world_pos: int3) -> bool {
    return world_pos.x >= 0 && world_pos.x < self.size * CHUNK_SIZE &&
           world_pos.y >= 0 && world_pos.y < self.size * CHUNK_SIZE &&
           world_pos.z >= 0 && world_pos.z < self.size * CHUNK_SIZE
}

world_get_chunk :: proc(self: ^World, pos: int3) -> ^Chunk {
    return &self.chunks[pos.x +
                        pos.y * self.size +
                        pos.z * self.size * self.size]
}

// Uses coordinates that covers every chunk [0, CHUNK_SIZE * self.world] on any given axis
world_at :: proc(self: ^World, world_pos: int3) -> ^Voxel {
    assert(world_position_in_bounds(self, world_pos))

    chunk, pos := world_translate_coords(world_pos)
    return chunk_at(world_get_chunk(self, chunk), pos)
}

world_set :: proc(self: ^World, world_pos: int3) {
    assert(world_position_in_bounds(self, world_pos))

    chunk, pos := world_translate_coords(world_pos)
    chunk_set(world_get_chunk(self, chunk), pos)

    self.updates[chunk] = 1
}

world_unset :: proc(self: ^World, world_pos: int3) {
    assert(world_position_in_bounds(self, world_pos))
    chunk, pos := world_translate_coords(world_pos)
    chunk_unset(world_get_chunk(self, chunk), pos)

    self.updates[chunk] = 1
}

world_add_cube :: proc(self: ^World, origin: int3, dimensions: int3) {
    minx := origin.x
    maxx := origin.x + dimensions.x

    miny := origin.y
    maxy := origin.y + dimensions.y

    minz := origin.z
    maxz := origin.z + dimensions.z


    for z in minz..<maxz {
        for y in miny..<maxy {
            for x in minx..<maxx {
                if !world_position_in_bounds(self, {x, y, z}) { continue }
                world_set(self, {x, y, z})
            }
        }
    }
}

world_add_sphere :: proc(self: ^World, origin: int3, r: int) {
    minx := origin.x - r
    maxx := origin.x + r

    miny := origin.y - r
    maxy := origin.y + r

    minz := origin.z - r
    maxz := origin.z + r
    for z in minz..=maxz {
        for y in miny..=maxy {
            for x in minx..=maxx {
                if !world_position_in_bounds(self, {x, y, z}) { continue }

                dx := f32(abs(x - origin.x))
                dx *= dx

                dy := f32(abs(y - origin.y))
                dy *= dy
                
                dz := f32(abs(z - origin.z))
                dz *= dz

                d := math.sqrt(dx + dy + dz)

                if d < f32(r) {
                    world_set(self, {x, y, z})
                }
            }
        }
    }
}
