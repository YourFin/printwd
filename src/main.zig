const std = @import("std");
const builtin = @import("builtin");
const dir_linux = @import("dir-linux.zig");

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

    const fd = try dir_linux.openDirAt(0, "/");
    defer _ = std.os.linux.close(fd);

    var buf: [2048]u8 align(dir_linux.Dirent.buffer_align) = undefined;
    var ls_iter = dir_linux.ls(&buf, fd);
    while (try ls_iter.next()) |dirent| {
        try stdout.print("inode: {}\toff: {}\treclen: {}\ttype: {}\tname: {s}", .{ dirent.d_ino, dirent.d_off, dirent.d_reclen, dirent.d_type, dirent.name() });
    }

    try stdout.flush(); // don't forget to flush!
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test {
    std.testing.refAllDecls(@This());
}
