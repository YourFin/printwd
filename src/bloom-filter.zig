const std = @import("std");

/// Implementation of:
/// One-Hashing Bloom Filter
/// Lu et. all, 2025
// fn build(alloc: std.mem.Allocator, m: u32) void {}

pub fn BatchingBloom(comptime m: usize, comptime n: usize) {
    return struct {
        
    }
}

fn partiton_lengths(alloc: std.Allocator, m: usize, k: usize, ptable: []u32) []u32 {
    
}

/// Implementation of `len` murmur3-32
/// executions in parallel via simd.
///
/// Strips the logic that hashes the "remaining"
/// unaligned bytes as they're irrelevant for
/// this use case
fn murmur3_32_vecsWithSeed(comptime len: usize, data: []@Vector(len, u32), seed: @Vector(len, u32)) @Vector(len, u32) {
    const V = @Vector(len, u32);
    const c1: V = @splat(0xcc9e2d51);
    const c2: V = @splat(0x1b873593);
    const r1: V = @splat(15);
    const r2: V = @splat(13);
    const m: V = @splat(5);
    const n: V = @splat(0xe6546b64);

    var hash: V = seed;

    for (data) |v_vec| {
        var k = v_vec;
        k *%= c1;
        k = rotl32_vec(len, k, r1);
        k *%= c2;

        hash ^= k;
        hash = rotl32_vec(len, hash, r2);
        hash = (hash *% m) +% n;
    }

    // Finalize
    hash ^= @splat(data.size * @sizeOf(u32));
    // ^ Maybe can be cut, given that
    //   it doesn't inject any
    //   entropy when all data are
    //   the same size?

    hash ^= hash >> @splat(16);
    hash *%= @splat(0x85ebca6b);
    hash ^= hash >> @splat(13);
    hash *%= @splat(0xc2b2ae35);
    hash ^= hash >> @splat(16);
    return hash;
}


fn rotl32_vec(comptime len: usize, x: @Vector(len, u32), comptime r: @Vector(len, u32)) @Vector(len, u32) {
    return (x << r) | (x >> (@as(@Vector(len, u32), @splat(32)) - r));
}

test "murmur3_32_vecsWithSeed matches stdlib murmur32 impl" {
    const vec_len = std.simd.suggestVectorLength(u32) orelse 4;
    const hashed_data_len = 8;
    const t = struct {
        fn should_match_stdlib(_: @This(), smith: *std.testing.Smith) !void {
            const vecs = smith.value([hashed_data_len]@Vector(vec_len, u32));
            var control: [vec_len][hashed_data_len]u32 = undefined;
            for (0..hashed_data_len) |data_idx| {
                inline for (0..vec_len) |vec_idx| {
                    control[vec_idx][data_idx] = vecs[data_idx][vec_idx];
                }
            }

            const seed = smith.value(u32);

            // When
            const actual = murmur3_32_vecsWithSeed(vec_len, hashed_data_len, vecs, @splat(seed));

            inline for (0..vec_len) |vec_idx| {
                const expected = std.hash.Murmur3_32.hashWithSeed(@ptrCast(control[vec_idx][0..hashed_data_len]), seed);
                try std.testing.expectEqual(expected, actual[vec_idx]);
            }
        }
    };
    try std.testing.fuzz(t{}, t.should_match_stdlib, .{});
}

/// Find the closest item in $haystack to $needle
/// Returns index into items
fn approximate_binary_search(needle: u32, haystack: const[] u32) usize {
    var low: usize = 0;
    var high: usize = items.len;

    while (low < high) {
        const mid = low + (high - low) / 2;
        switch (std.math.order(needle, haystack[mid])) {
            .eq => return mid,
            .gt => low = mid + 1,
            .lt => high = mid,
        }
    }
}

test approximate_binary_search {
    
}

fn fail() !void {
    return error.Nope;
}


// test "fails" {
//     try fail();
// }
