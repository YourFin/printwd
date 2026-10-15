const std = @import("std");

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
    d_type: DType.T,
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

    pub fn name(self: *align(1) const Dirent) [:0]const u8 {
        //std.log.err("{}, {}, {s}\n", .{ self.d_reclen, @offsetOf(Dirent, "d_name"), self.d_name });
        return @as([*:0]const u8, @ptrCast(&(self.d_name)))[0..(self.d_reclen - 2 - @offsetOf(Dirent, "d_name"))];
    }
};

pub const LsIterator = struct {
    fd: i32,
    buf: []u8,
    state: union(enum) {
        pending: void,
        available: struct {
            read_size: usize,
            offset: usize,
        },
    },

    pub fn next(this: *LsIterator) !?*align(1) Dirent {
        switch (this.state) {
            .pending => {
                const result = getdents64(this.fd, this.buf.ptr, this.buf.len);
                std.log.err("read bytes: {}", .{result});
                if (result == 0) {
                    return null;
                }
                const code = errno(result);
                if (code != E.SUCCESS) {
                    return switch (code) {
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
                const prev: *align(1) Dirent = @ptrCast(&this.buf[state.offset]);
                const new_offset = state.offset + prev.d_reclen;
                if (new_offset < state.read_size) {
                    state.*.offset = new_offset;
                    return @ptrCast(this.buf.ptr + state.*.offset);
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
/// They need to be copied if not drained immediately
pub fn ls(buf: []u8, fd: i32) LsIterator {
    return LsIterator{
        .fd = fd,
        .buf = buf,
        .state = .pending,
    };
}

test {
    const ret = std.os.linux.open("/home/pen/", std.os.linux.O{
        .DIRECTORY = true,
        .CREAT = false,
    }, 0);
    assert(std.os.linux.errno(ret) == std.os.linux.E.SUCCESS);
    const fd = fd: {
        const i: isize = @bitCast(ret);
        break :fd @as(i32, @intCast(i));
    };
    std.log.err("fd: {}", .{fd});

    defer _ = std.os.linux.close(fd);

    var buf: [2048]u8 = undefined;
    var ls_iter = ls(&buf, fd);
    while (try ls_iter.next()) |dirent| {
        std.log.err("inode: {}\toff: {}\treclen: {}\ttype: {s}\tname: {s}", .{ dirent.d_ino, dirent.d_off, dirent.d_reclen, dirent.d_type, dirent.name() });
    }
}
