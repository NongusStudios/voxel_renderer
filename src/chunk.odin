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

chunk_at :: proc{
    chunk_at_ints,
    chunk_at_int3,
}

chunk_at_int3 :: proc(self: ^Chunk, pos: int3) -> ^Voxel {
    return chunk_at_ints(self, pos.x, pos.y, pos.z)
}

chunk_at_ints :: proc(self: ^Chunk, x, y, z: int) -> ^Voxel {
    assert(x >= 0 || x < CHUNK_SIZE, "Chunk access out of bounds")
    assert(y >= 0 || y < CHUNK_SIZE, "Chunk access out of bounds")
    assert(z >= 0 || z < CHUNK_SIZE, "Chunk access out of bounds")
    return &self.data[x + \
                      y * CHUNK_SIZE + \
                      z * CHUNK_SIZE * CHUNK_SIZE]
}

chunk_set :: proc(self: ^Chunk, x, y, z: int) {
    voxel := chunk_at(self, x, y, z)
    voxel^ = 1
    self.solid[{x, y, z}] = 1
}

chunk_unset :: proc(self: ^Chunk, x, y, z: int) {
    voxel := chunk_at(self, x, y, z)
    if voxel^ == 0 { return }
    voxel^ = 0
    delete_key(&self.solid, int3{x, y, z})
}

chunk_add_cube :: proc(self: ^Chunk, ox, oy, oz, w, h, d: int) {
    minx := ox
    maxx := ox + w
    assert(minx >= 0 && maxx <= CHUNK_SIZE, "Cube width goes out of bounds")

    miny := oy
    maxy := oy + h
    assert(miny >= 0 && maxy <= CHUNK_SIZE, "Cube height goes out of bounds")

    minz := oz
    maxz := oz + d
    assert(minz >= 0 && maxz <= CHUNK_SIZE, "Cube depth goes out of bounds")


    for z in minz..<maxz {
        for y in miny..<maxy {
            for x in minx..<maxx {
                chunk_set(self, x, y, z)
            }
        }
    }
}

chunk_add_sphere :: proc(self: ^Chunk, ox, oy, oz, r: int) {
    minx := ox - r
    maxx := ox + r
    assert(minx >= 0 && maxx < CHUNK_SIZE, "Cube width goes out of bounds")

    miny := oy - r
    maxy := oy + r
    assert(miny >= 0 && maxy < CHUNK_SIZE, "Cube height goes out of bounds")

    minz := oz - r
    maxz := oz + r
    assert(minz >= 0 && maxz < CHUNK_SIZE, "Cube depth goes out of bounds")
    for z in minz..=maxz {
        for y in miny..=maxy {
            for x in minx..=maxx {
                dx := f32(abs(x - ox))
                dx *= dx

                dy := f32(abs(y - oy))
                dy *= dy
                
                dz := f32(abs(z - oz))
                dz *= dz

                d := math.sqrt(dx + dy + dz)

                if d < f32(r) {
                    chunk_set(self, x, y, z)
                }
            }
        }
    }
}
