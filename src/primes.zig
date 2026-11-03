const std = @import("std");
const math = std.math;
const assert = std.debug.assert;

/// Prime number generator
///
/// `T` - numeric type to return.
///
/// NOTE: Can only calculate primes
/// that are less than max(usize).
///
/// `max_mem_bytes` - max size of the underlying bitset.
/// Also constrains the output to
///
/// This is not an optimal implementation,
/// but under -OReleaseFast it should be good enough
/// for most mortal uses. On my laptop
/// (AMD Ryzen AI 300 Series - A9 + fast ssd) it
/// can generate the the first ~2 billion primes
/// (up to 45650166253) in 7 minutes or so.
///
/// Fancier Sieves can probably play better with
/// memory locality, be multithreaded, etc.
/// This implementation also doesn't re-use the low
/// bitvector space after it goes dead.
pub fn SieveOfEratosthenes(comptime T: type) type {
    const max: usize = switch (@typeInfo(T)) {
        .int => math.maxInt(T),
        .float => @min(math.pow(2, math.floatMantissaBits(T)), math.maxInt(usize)),
        else => @compileError("Requires numeric type"),
    };
    return struct {
        max_bitsize: usize,
        state: union(enum) { init: void, running: struct {
            is_prime: std.bit_set.Dynamic,
            is_prime_idx: usize,
            q: T,
            prev_q: T,

            q_sqr: usize,
        } },

        const bytes_to_bits = 8;
        const first_prime = 2;

        pub fn init() @This() {
            return init_mem_constrained(math.maxInt(usize));
        }

        /// `max_mem_bytes` - max size of the underlying bitset.
        /// Also constrains the output to no primes larger
        /// than 2^(8 * max_mem_bytes)
        pub fn init_mem_constrained(max_mem_bytes: usize) @This() {
            assert(max_mem_bytes > 0);
            return .{
                .max_bitsize = max_mem_bytes * bytes_to_bits,
                .state = .{
                    .init = undefined,
                },
            };
        }

        pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
            switch (self.state) {
                .running => |*s| {
                    s.is_prime.deinit(alloc);
                },
                else => {},
            }
        }

        /// Return the next prime number.
        ///
        /// Will return `null` when primes no longer fit in
        /// the provided numeric type with full precision,
        /// or if there are no more primes available less than
        /// 2^(8 * max_mem_bytes)
        ///
        /// Only errors on OOM from allocator.
        pub fn next(self: *@This(), alloc: std.mem.Allocator) !?T {
            switch (self.state) {
                .init => {
                    self.*.state = .{
                        .running = .{
                            .is_prime = bitset: {
                                var bitset = try std.bit_set.Dynamic.initFull(alloc, @min(self.max_bitsize, @sizeOf(usize) * bytes_to_bits));
                                bitset.unset(0);
                                bitset.unset(1);
                                break :bitset bitset;
                            },
                            .q_sqr = 4,
                            .is_prime_idx = 0,
                            .q = 2,
                            .prev_q = 0,
                        },
                    };
                    return self.next(alloc);
                },
                .running => |*s| while (true) {
                    // Drain primes between q and the end of the explored
                    // space
                    while (s.is_prime_idx < @min(s.is_prime.bit_length, s.q_sqr) - 1) {
                        s.*.is_prime_idx += 1;
                        if (s.is_prime.isSet(s.is_prime_idx)) {
                            return to_T(s.is_prime_idx);
                        }
                    }

                    // We already maxed out the bitsize
                    if (s.q_sqr > self.max_bitsize) {
                        return null;
                    }

                    // Find next q
                    s.*.prev_q = s.q;
                    s.*.q += 1;
                    while (!s.is_prime.isSet(s.q)) : (s.*.q += 1) {}

                    // Expand is_prime
                    {
                        // Going over max possible index
                        if (s.q > sqrt_int(math.maxInt(usize))) {
                            return null;
                        }
                        s.*.q_sqr = s.q * s.q;
                        if (s.q_sqr > s.is_prime.bit_length) {
                            // NOTE: q_sqr is not used directly as the bit length
                            // because we /really/ want a the allocation to grow
                            // exponentially within bounds.
                            //
                            // Attempting to just resize to q_sqr with a general
                            // purpose allocator will thrash hard with copy resizing
                            // over it's exponential allocation regime
                            try s.is_prime.resize(alloc, @min(s.is_prime.bit_length * 2, self.max_bitsize), true);
                        }
                    }

                    // Write out primes in the new region
                    {
                        var p: usize = first_prime;
                        while (p <= s.q) : (p += 1) {
                            if (!s.is_prime.isSet(s.q)) {
                                continue;
                            }
                            var i: usize = (s.prev_q * s.prev_q) / p;
                            while (p * i < @min(s.q_sqr, s.is_prime.bit_length)) : (i += 1) {
                                s.is_prime.unset(p * i);
                            }
                        }
                    }
                },
            }
        }

        inline fn to_T(prime: usize) ?T {
            if (prime > max) {
                return null;
            }
            const usize_bits = switch (@typeInfo(usize)) {
                .int => |usize_info| usize_info.bits,
                else => unreachable,
            };
            switch (@typeInfo(T)) {
                .int => |int_info| {
                    if (usize_bits > int_info.bits or (int_info.signedness == .signed and usize_bits == int_info.bits)) {
                        return @truncate(prime);
                    } else {
                        return @intCast(prime);
                    }
                },
                .float => {
                    return @floatFromInt(prime);
                },
                else => unreachable,
            }
        }
    };
}

// Didn't put thought into making this reasonable from
// a speed perspective; hence the comptime constraint
fn sqrt_int(comptime val: anytype) @TypeOf(val) {
    return @trunc(@sqrt(@as(f128, @floatFromInt(val))));
}

// Writes out the first $argv[1] prime numbers
// out to $argv[2] (or stdout if not provided)
// as little-endian u64
//
// Shows a kinda jank progress meter for millions
// of prime numbers generated.
//
// ```
// zig build-exe -OReleaseFast src/primes.zig
//
// ./primes 10_000_000 primes_le_u64.bin
// ```
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const count, const out = args: {
        var iter = init.minimal.args.iterate();
        _ = iter.next() orelse {
            std.process.fatal("No command line argument provided", .{});
        };
        const arg = iter.next() orelse {
            std.process.fatal("No command line argument provided", .{});
        };
        const parsed = std.fmt.parseInt(u64, arg, 10) catch |err| {
            std.process.fatal("Error parsing command line: {}", .{err});
        };

        const file = if (iter.next()) |fname|
            try std.Io.Dir.createFile(std.Io.Dir.cwd(), io, fname, .{ .read = true, .truncate = true })
        else
            std.Io.File.stdout();

        break :args .{ parsed, file };
    };
    defer out.close(io);

    var safe = std.heap.SafeAllocator.init(std.heap.smp_allocator, .{});
    defer {
        const leak_count = safe.deinit();
        if (leak_count != 0) {
            std.log.err("leak count: {}", .{leak_count});
        }
    }
    const gpa = safe.allocator();

    var out_buffer: [1024]u8 = undefined;
    var out_writer = out.writer(io, &out_buffer);
    const output = &out_writer.interface;

    var p: ?u64 = undefined;
    var gen = SieveOfEratosthenes(u64).init();
    defer gen.deinit(gpa);

    const progress_interval = 1_000_000;
    const node = std.Progress.start(io, .{ .root_name = "Calculating..." });
    defer node.end();
    node.setEstimatedTotalItems(count / progress_interval);
    for (0..count) |_| {
        p = try gen.next(gpa) orelse break;
        if (p == null) break;
        try output.writeInt(u64, p.?, .little);
        if (count % progress_interval == 0) {
            node.completeOne();
        }
    }

    try output.flush();
}
