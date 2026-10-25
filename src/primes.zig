const std = @import("std");
const math = std.math;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var safe = std.heap.SafeAllocator.init(std.heap.smp_allocator, .{});
    defer {
        const leak_count = safe.deinit();
        if (leak_count != 0) {
            std.log.err("leak count: {}", .{leak_count});
        }
    }
    const gpa = safe.allocator();

    // stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var p: ?u32 = undefined;
    var gen = SieveOfEratosthenes(u32).init();
    defer gen.deinit(gpa);
    for (0..1_000_000) |_| {
        p = try gen.next(gpa);
    }
    try stdout.print("{?}\n", .{p});

    try stdout.flush();
}

// Calculates primes up to max(usize)
pub fn SieveOfEratosthenes(comptime T: type) type {
    const max: usize = switch (@typeInfo(T)) {
        .int => math.maxInt(T),
        .float => @min(math.pow(2, math.floatMantissaBits(T)), math.maxInt(usize)),
        else => @compileError("Requires numeric type"),
    };
    return struct {
        const first_prime = 2;
        state: union(enum) { init: void, running: struct {
            is_prime: std.bit_set.Dynamic,
            is_prime_idx: usize,
            q: T,
        } },

        pub fn init() @This() {
            return .{
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

        pub fn next(self: *@This(), alloc: std.mem.Allocator) !?T {
            //@breakpoint();
            switch (self.state) {
                .init => {
                    self.*.state = .{
                        .running = .{
                            .is_prime = bitset: {
                                var bitset = try std.bit_set.Dynamic.initFull(alloc, first_prime * first_prime);
                                bitset.unset(0);
                                bitset.unset(1);
                                break :bitset bitset;
                            },
                            .is_prime_idx = 0,
                            .q = 2,
                        },
                    };
                    return self.next(alloc);
                },
                .running => |*s| while (true) {
                    // Drain primes between q and the end of the explored
                    // space
                    while (s.is_prime_idx < s.is_prime.bit_length - 1) {
                        s.*.is_prime_idx += 1;
                        if (s.is_prime.isSet(s.is_prime_idx)) {
                            return to_T(s.is_prime_idx);
                        }
                    }

                    // Find next q
                    s.*.q += 1;
                    while (!s.is_prime.isSet(s.q)) : (s.*.q += 1) {}

                    // Expand is_prime
                    try s.is_prime.resize(alloc, s.q * s.q, true);
                    var p: usize = first_prime;
                    while (p <= s.q) : (p += 1) {
                        if (!s.is_prime.isSet(s.q)) {
                            continue;
                        }
                        var i: usize = 1;
                        while (p * i < s.is_prime.bit_length) : (i += 1) {
                            s.is_prime.unset(p * i);
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

        // fn initInterface(alloc: std.mem.Allocator) std.Io.Reader {
        // return std.Io.Reader{
        //     .buffer = {},
        //     .seek = 0,
        //     .end = 0,
        //     .vtable = .{}
        // };
        // };
    };
}
