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
    self.updates = make(map[int3]u8)
    return
}

destroy_world :: proc(self: ^World) {
    delete(self.chunks)
    delete(self.updates)
}

world_queue_update :: proc(self: ^World, chunk: int3, pos: int3) {
    self.updates[chunk] = 1
    
    // no further updates required if voxel doesn't border the chunk
    if pos.x > 0 && pos.y > 0 && pos.z > 0 &&
       pos.x < CHUNK_SIZE-1 && pos.y < CHUNK_SIZE-1 && pos.z < CHUNK_SIZE-1 {
        return
    }
    
    // Queue affected neighbours on change of a bordering voxel
    for axis in 0..<3 {
        diff := int3_zero
        diff[axis] = 1

        // Check negative borders
        if pos[axis] == 0 && chunk[axis] > 0 {    
            self.updates[chunk - diff] = 1
            continue
        }

        // Check positive borders
        if pos[axis] == CHUNK_SIZE-1 && chunk[axis] < self.size-1 {
            self.updates[chunk + diff] = 1
        }
    }
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
    
    world_queue_update(self, chunk, pos)
}

world_unset :: proc(self: ^World, world_pos: int3) {
    assert(world_position_in_bounds(self, world_pos))
    chunk, pos := world_translate_coords(world_pos)
    chunk_unset(world_get_chunk(self, chunk), pos)

    world_queue_update(self, chunk, pos)
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
