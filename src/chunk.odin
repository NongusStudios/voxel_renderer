package main

// Size of a chunk on any given axis
CHUNK_SIZE :: 32

// Total amount of voxels per chunk
CHUNK_FLAT_SIZE :: CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE

Voxel :: u8
Chunk :: [CHUNK_FLAT_SIZE]Voxel

chunk_position_in_bounds :: proc(pos: int3) -> bool {
    return pos.x >= 0 && pos.x < CHUNK_SIZE &&
           pos.y >= 0 && pos.y < CHUNK_SIZE &&
           pos.z >= 0 && pos.z < CHUNK_SIZE
}

chunk_at :: proc(self: ^Chunk, pos: int3) -> ^Voxel {
    assert(pos.x >= 0 || pos.x < CHUNK_SIZE, "Chunk access out of bounds")
    assert(pos.y >= 0 || pos.y < CHUNK_SIZE, "Chunk access out of bounds")
    assert(pos.z >= 0 || pos.z < CHUNK_SIZE, "Chunk access out of bounds")
    return &self[pos.x + \
                 pos.y * CHUNK_SIZE + \
                 pos.z * CHUNK_SIZE * CHUNK_SIZE]
}

chunk_set :: proc(self: ^Chunk, pos: int3) {
    voxel := chunk_at(self, pos)
    voxel^ = 1
}

chunk_unset :: proc(self: ^Chunk, pos: int3) {
    voxel := chunk_at(self, pos)
    voxel^ = 0
}
