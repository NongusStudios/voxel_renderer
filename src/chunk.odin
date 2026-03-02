package main

import "core:math"
// Size of a chunk on any given axis
CHUNK_SIZE :: 64

// Total amount of voxels per chunk
CHUNK_FLAT_SIZE :: CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE

Voxel :: u8
Chunk :: struct {
    data:   []Voxel,
    solid: map[int3]u8,
}

create_chunk :: proc() -> Chunk {
    return {
        data   = make([]Voxel, CHUNK_FLAT_SIZE),
        solid = make(map[int3]u8),
    }
}

destroy_chunk :: proc(self: ^Chunk) {
    delete(self.data)
    delete(self.solid)
}

chunk_position_in_bounds :: proc(pos: int3) -> bool {
    return pos.x >= 0 && pos.x < CHUNK_SIZE &&
           pos.y >= 0 && pos.y < CHUNK_SIZE &&
           pos.z >= 0 && pos.z < CHUNK_SIZE
}

chunk_at :: proc(self: ^Chunk, pos: int3) -> ^Voxel {
    assert(pos.x >= 0 || pos.x < CHUNK_SIZE, "Chunk access out of bounds")
    assert(pos.y >= 0 || pos.y < CHUNK_SIZE, "Chunk access out of bounds")
    assert(pos.z >= 0 || pos.z < CHUNK_SIZE, "Chunk access out of bounds")
    return &self.data[pos.x + \
                      pos.y * CHUNK_SIZE + \
                      pos.z * CHUNK_SIZE * CHUNK_SIZE]
}

chunk_set :: proc(self: ^Chunk, pos: int3) {
    voxel := chunk_at(self, pos)
    voxel^ = 1
    self.solid[pos] = 1
}

chunk_unset :: proc(self: ^Chunk, pos: int3) {
    voxel := chunk_at(self, pos)
    if voxel^ == 0 { return }
    voxel^ = 0
    delete_key(&self.solid, pos)
}

chunk_add_cube :: proc(self: ^Chunk, origin: int3, dimensions: int3) {
    minx := origin.x
    maxx := origin.x + dimensions.x

    miny := origin.y
    maxy := origin.y + dimensions.y

    minz := origin.z
    maxz := origin.z + dimensions.z


    for z in minz..<maxz {
        for y in miny..<maxy {
            for x in minx..<maxx {
                if !chunk_position_in_bounds({x, y, z}) { continue }
                chunk_set(self, {x, y, z})
            }
        }
    }
}

chunk_add_sphere :: proc(self: ^Chunk, origin: int3, r: int) {
    minx := origin.x - r
    maxx := origin.x + r

    miny := origin.y - r
    maxy := origin.y + r

    minz := origin.z - r
    maxz := origin.z + r
    for z in minz..=maxz {
        for y in miny..=maxy {
            for x in minx..=maxx {
                if !chunk_position_in_bounds({x, y, z}) { continue }

                dx := f32(abs(x - origin.x))
                dx *= dx

                dy := f32(abs(y - origin.y))
                dy *= dy
                
                dz := f32(abs(z - origin.z))
                dz *= dz

                d := math.sqrt(dx + dy + dz)

                if d < f32(r) {
                    chunk_set(self, {x, y, z})
                }
            }
        }
    }
}
