const std = @import("std");
const builtin = @import("builtin");

const ls_buf_len = 1024 * 64;
var ls_buf: [ls_buf_len]u8 = undefined;

// Implemented directly via getdirents64 syscall
// for a couple reasons:
// 1. readdir(3) allocates a heap dirents stream without control
//    of the buffer size passed to the kernel; we can just pass a
//    big honking buffer and load the whole directory tree into
//    contiguous memory. This probably also means we can keep
//    mode switches to (hopefully) 1 per directory.
//
// 2. musl and glibc don't have a consistent interface for
//    the syscall wrapper

/// see: man getdirents64
///
/// https://github.com/torvalds/linux/blob/72d3fcf802c45d00b300f25b848a93c3a2bd7c7e/tools/include/nolibc/types.h#L129
///
/// ONLY VALID FOR KERNEL >= 2.6.4
const Dirent = switch (builtin.os.tag) {
    .linux => extern struct {
        /// Inode number
        d_ino: u64,
        /// Offset to next linux_dirent
        d_off: i64,
        /// Length of this linux_dirent
        d_reclen: c_ushort,
        /// Type of this linux_dirent
        /// Not always present - must handle unknown case
        d_type: DType.T,
        /// Filename (null-terminated)
        ///
        /// length is actually (d_reclen - 2 -
        ///   offsetof(struct linux_dirent, d_name))
        d_name: [*:0]u8,

        pub const DType = struct {
            /// TODO: https://codeberg.org/ziglang/zig/issues/36082
            /// Use c unsigned char
            pub const T = u8;
            // https://github.com/torvalds/linux/blob/72d3fcf802c45d00b300f25b848a93c3a2bd7c7e/tools/include/nolibc/types.h#L78
            pub const unknown: T = 0x0;
            pub const fifo: T = 0x1;
            pub const chr: T = 0x2;
            pub const dir: T = 0x4;
            pub const blk: T = 0x6;
            pub const reg: T = 0x8;
            pub const lnk: T = 0xa;
            pub const sock: T = 0xc;
        };
    },
    else => undefined,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // Prints to stderr
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    // stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("Run `zig build test` to run the tests.\n", .{});

    try stdout.flush(); // don't forget to flush!
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
