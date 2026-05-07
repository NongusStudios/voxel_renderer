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

world_cube :: proc(self: ^World, origin: int3, dimensions: int3, place := true) {
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
                if place {
                    world_set(self, {x, y, z})
                } else {
                    world_unset(self, {x, y, z})
                }
            }
        }
    }
}

world_sphere :: proc(self: ^World, origin: int3, r: int, place := true) {
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
                    if place {
                        world_set(self,   {x, y, z})
                    } else {
                        world_unset(self, {x, y, z})
                    }
                }
            }
        }
    }
}

world_to_grid_local_position :: proc(position: float3, world_size: int) -> float3 {
    size := f32(world_size * CHUNK_SIZE) / 2
    return position / VOXEL_UNIT_SIZE + size
}

world_cast_ray :: proc(self: ^World, origin: float3, direction: float3) -> (pos: int3, normal: int3, hit: bool) {
    /* Initialisation */
    grid_origin := world_to_grid_local_position(origin, self.size)
    grid_max_bounds := self.size * CHUNK_SIZE

    start_index := int3{
        int(math.floor(grid_origin.x)),
        int(math.floor(grid_origin.y)),
        int(math.floor(grid_origin.z)),
    }
    current_index := start_index

    // Step
    get_step :: proc(dir: f32) -> int {
        if dir > 0 {
            return  1
        } else if dir < 0 {
            return -1
        }
        return 0
    }

    // t_max
    get_t_max :: proc(dir: f32, current: int, org: f32) -> f32 {
        cur: int
        if dir > 0 {
            cur = current + 1
        } else if dir < 0 {
            cur = current - 1
        } else {
            return math.INF_F32
        }

        return (f32(cur) - org) / dir
    }
    
    step: int3
    t_delta, t_max: float3

    for a in 0..<3 {
        step[a]    = get_step(direction[a])
        t_delta[a] = abs(1 / direction[a]) if direction[a] != 0 else math.INF_F32
        
        /* NOTE not accounted for:
            tMin - Calculated during the initialization phase, this determines the minimum time needed to cross into the grid.
            This would be added to tMaxX in the initialization phase.
        */
        //t_max[a] = get_t_max(direction[a], current_index[a], grid_origin[a])
        t_max[a] = (f32(start_index[a]) - grid_origin[a]) / direction[a]
    }

    /* Traversal */
    for {
        // Keeps track of the traversal direction
        traversal : int3

        // Find smallest t_max
        if t_max.x < t_max.y && t_max.x < t_max.z {
            // Move in X
            current_index.x += step.x
            t_max.x += t_delta.x
            traversal.x = step.x
        } else if t_max.y < t_max.z {
            // Move in Y
            current_index.y += step.y
            t_max.y += t_delta.y
            traversal.y = step.y
        } else {
            // Move in Z
            current_index.z += step.z
            t_max.z += t_delta.z
            traversal.z = step.z
        }

        if  current_index.x < 0 || current_index.x >= grid_max_bounds ||
            current_index.y < 0 || current_index.y >= grid_max_bounds ||
            current_index.z < 0 || current_index.z >= grid_max_bounds
        {
            break
        }

        // Check if current voxel is solid
        if world_at(self, current_index)^ > 0 {
            return current_index, -traversal, true
        }
    }

    return {}, {}, false
}
