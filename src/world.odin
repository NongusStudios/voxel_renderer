package main

World :: struct {
    chunks: []Chunk,
    size: int,
    flat_size: int,
}

create_world :: proc(size: int) -> (self: World) {
    self.size = size
    self.flat_size = size * size * size
    self.chunks = make([]Chunk, self.flat_size)
    return
}

destroy_world :: proc(self: ^World) {
    delete(self.chunks)
}

world_translate_coords :: proc(world_pos: int3) -> (chunk: int3, pos: int3) { 
    chunk = world_pos / CHUNK_SIZE
    pos   = world_pos % CHUNK_SIZE
    return
}

world_is_in_bounds :: proc(self: ^World, world_pos: int3) -> bool {
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
    assert(world_is_in_bounds(self, world_pos))

    chunk, pos := world_translate_coords(world_pos)
    return chunk_at(world_get_chunk(self, chunk), pos)
}

world_set :: proc(self: ^World, world_pos: int3) {
    assert(world_is_in_bounds(self, world_pos))

    chunk, pos := world_translate_coords(world_pos)
    chunk_set(world_get_chunk(self, chunk), pos)
}

world_unset :: proc(self: ^World, world_pos: int3) {
    assert(world_is_in_bounds(self, world_pos))
    chunk, pos := world_translate_coords(world_pos)
    chunk_unset(world_get_chunk(self, chunk), pos)
}
