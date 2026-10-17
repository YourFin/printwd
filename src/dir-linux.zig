const std = @import("std");
const builtin = @import("builtin");

const assert = std.debug.assert;

const getdents64 = std.os.linux.getdents64;
const errno = std.os.linux.errno;
const E = std.os.linux.E;
const mem = std.mem;

/// see: man getdents64
///
/// https://github.com/torvalds/linux/blob/72d3fcf802c45d00b300f25b848a93c3a2bd7c7e/tools/include/nolibc/types.h#L129
///
/// ONLY VALID FOR KERNEL >= 2.6.4
const Dirent = extern struct {
    /// TODO: https://codeberg.org/ziglang/zig/issues/36082
    /// Use c unsigned char
    pub const DType = enum(u8) {
        // https://github.com/torvalds/linux/blob/72d3fcf802c45d00b300f25b848a93c3a2bd7c7e/tools/include/nolibc/types.h#L78
        unknown = 0x0,
        fifo = 0x1,
        chr = 0x2,
        dir = 0x4,
        blk = 0x6,
        reg = 0x8,
        lnk = 0xa,
        sock = 0xc,
        _,
    };

    /// Inode number
    d_ino: u64,
    /// Offset to next linux_dirent
    /// Field is ~useless in practice;
    /// the implementing filesystem can use
    /// this for whatever it wishes.
    d_off: i64,
    /// Length of this linux_dirent
    d_reclen: c_ushort,
    /// Type of this linux_dirent
    /// Not always present - must handle unknown case
    d_type: DType,
    /// Filename placeholder
    /// This is mostly here as a way to grab
    /// a pointer to this address for the
    /// "name" function.
    ///
    /// (null-terminated)
    ///
    /// allocated length is actually (d_reclen - 2 -
    ///   offsetof(struct linux_dirent, d_name))
    /// However, the kernel will pad out the
    /// string with null bytes to maintain alignment
    d_name: u8,

    /// Get the name of this directory.
    ///
    /// NOTE: the return value will be PADDED WITH NULL BYTES
    /// out such that the next entry in the buffer aligns
    /// appropriately.
    pub fn name(self: *const Dirent) []const u8 {
        const d_name_ptr: [*]const u8 = @ptrCast(&(self.d_name));
        return d_name_ptr[0..(self.d_reclen - 2 - @offsetOf(Dirent, "d_name"))];
    }
};

pub const LsIterator = struct {
    fd: i32,
    buf: []align(@alignOf(Dirent)) u8,
    state: union(enum) {
        pending: void,
        available: struct {
            read_size: usize,
            offset: usize,
        },
    },

    /// Note:
    pub fn next(this: *LsIterator) !?*Dirent {
        switch (this.state) {
            .pending => {
                var result: usize = undefined;
                while (true) {
                    result = getdents64(this.fd, this.buf.ptr, this.buf.len);
                    if (result == 0) {
                        return null;
                    }
                    const code = errno(result);
                    if (code == E.SUCCESS) {
                        break;
                    }
                    return switch (code) {
                        // Syscall interrupted; e.g. process signaled
                        // while waiting on disk io
                        E.INTR => continue,
                        // Invalid file descriptor
                        E.BADF => error.BADF,

                        // Argument points outside the calling process's address space.
                        E.FAULT => error.FAULT,

                        // Result buffer is too small.
                        E.INVAL => error.BufferTooSmall,

                        // No such directory.
                        E.NOENT => error.NOENT,

                        // File descriptor does not refer to a directory.
                        E.NOTDIR => error.NOTDIR,
                        else => error.UndocumentSyscallResponse,
                    };
                }
                this.*.state = .{ .available = .{
                    .read_size = @intCast(result),
                    .offset = 0,
                } };
                assert(this.state.available.read_size <= this.buf.len);
                return @ptrCast(this.buf.ptr);
            },
            .available => |*state| {
                const prev: *Dirent = @ptrCast(@alignCast(&this.buf[state.offset]));
                const new_offset = state.offset + prev.d_reclen;
                if (new_offset < state.read_size) {
                    state.*.offset = new_offset;
                    assert(state.offset % @alignOf(Dirent) == 0);
                    return @ptrCast(@alignCast(this.buf.ptr + state.offset));
                } else {
                    this.*.state = .pending;
                    return this.next();
                }
            },
        }
    }
};

/// Note: Dirent entries are backed by `buf`,
/// and only valid until the next call to `next`.
///
/// They need to be copied if not consumed immediately
pub fn ls(buf: []align(@alignOf(Dirent)) u8, fd: i32) LsIterator {
    return LsIterator{
        .fd = fd,
        .buf = buf,
        .state = .pending,
    };
}

test "run ls" {
    const ret = std.os.linux.open("/home/pen/", std.os.linux.O{
        .DIRECTORY = true,
        .CREAT = false,
    }, 0);
    assert(std.os.linux.errno(ret) == std.os.linux.E.SUCCESS);
    const fd = fd: {
        const i: isize = @bitCast(ret);
        break :fd @as(i32, @intCast(i));
    };

    defer _ = std.os.linux.close(fd);

    var buf: [2048]u8 align(@alignOf(Dirent)) = undefined;
    var ls_iter = ls(&buf, fd);
    while (try ls_iter.next()) |dirent| {
        std.log.warn("inode: {}\toff: {}\treclen: {}\ttype: {}\tname: {s}", .{ dirent.d_ino, dirent.d_off, dirent.d_reclen, dirent.d_type, dirent.name() });
    }
}

test "Dirent alignment is still 8" {
    try std.testing.expectEqual(@alignOf(Dirent) % 8, 0);
}
