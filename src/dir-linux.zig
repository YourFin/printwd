const std = @import("std");
const builtin = @import("builtin");
const config = @import("build-flags");
const bloom = @import("bloom-filter.zig");

const assert = std.debug.assert;

inline fn getdents64(fd: i32, dirp: [*]u8, len: c_uint) usize {
    return @call(if (config.profile_build) .never_inline else .auto, std.os.linux.getdents64, .{ fd, dirp, len });
}
const errno = std.os.linux.errno;
const E = std.os.linux.E;
const mem = std.mem;

const safe_mode = switch (builtin.mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseFast, .ReleaseSmall => false,
};

/// see: man getdents64
/// https://github.com/torvalds/linux/blob/72d3fcf802c45d00b300f25b848a93c3a2bd7c7e/tools/include/nolibc/types.h#L129
///
/// (only valid for kernel >= 2.6.4)
pub const Dirent = extern struct {
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

    /// See: https://github.com/torvalds/linux/blob/58161ead29e50d70a317ea26b472e0c7508e69da/fs/readdir.c#L352
    pub const buffer_align = @sizeOf(u64);

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
    /// names are null-terminated
    ///
    /// allocated length is actually (d_reclen - 2 -
    ///   offsetof(struct linux_dirent, d_name))
    /// However, the kernel will pad out the
    /// string with uninit bytes to maintain alignment
    d_name: u8,

    pub inline fn name_allocated_len(self: *const Dirent) usize {
        return self.d_reclen - 1 - @offsetOf(Dirent, "d_name");
    }

    /// Get the name of this directory.
    ///
    /// NOTE: the return value will be PADDED WITH NULL BYTES
    /// out such that the next entry in the buffer aligns
    /// appropriately.
    pub fn name(self: *const Dirent) []const u8 {
        const d_name_ptr: [*]const u8 = @ptrCast(&(self.d_name));
        return d_name_ptr[0..self.name_allocated_len()];
    }

    pub fn accurate_name(self: *const Dirent) [:0]const u8 {
        const d_name_ptr: [*]const u8 = @ptrCast(&(self.d_name));
        var len: usize = 0;
        while (d_name_ptr[len] != 0) {
            len += 1;
        }
        const alloc_len = self.name_allocated_len();
        if (len > alloc_len) {
            @breakpoint();
            std.debug.panic("Unable to find null byte before allocated length; expected to find at {}, actual len {}", .{ self.name_allocated_len(), len });
        }
        return d_name_ptr[0..len :0];
    }

    /// Do not depend on the /only/ sentinel
    /// being at name[name.len]; if the filesystem
    /// is corrupted, it's possible for a null
    /// byte to show up early.
    ///
    const Name = [:0]const u8;

    /// O(1) instead of O(len(dirname)), but
    /// will give a different response for
    /// some corrupted filesystems
    pub fn fast_name(self: *const Dirent) Dirent.Name {
        // Q: WTF?
        // A: The dirname entries returned by the syscall are
        // pointer aligned within the buffer, but the trailing
        // name field may not be.
        //
        // Annoyingly (for us), the d_reclen field on the
        // returned buffer returns `&self - &next`, not
        // the distance between `&self` and the
        // null byte terminating the name string.
        //
        // This means that we need to count our way to the
        // null byte ourselves to find the real length of
        // the string.
        //
        // Fortunately, we don't have to count from the start.
        // We know that the kernel (should) only do the minimum
        // padding necessary
        //
        // Kernel code pointers:
        // reclen calculation:
        //   https://github.com/torvalds/linux/blob/58161ead29e50d70a317ea26b472e0c7508e69da/fs/readdir.c#L352
        // dirent name verification - run per entry in the kernel >7.3:
        //   https://github.com/torvalds/linux/blob/58161ead29e50d70a317ea26b472e0c7508e69da/fs/readdir.c#L155
        // only checks that name is short enough () and doesn't contain '/'
        var idx: u32 = @max(
            @offsetOf(Dirent, "d_name"),
            self.d_reclen - Dirent.buffer_align,
        );
        // TODO: mem.findScalarPos
        while (@as([*]const u8, @ptrCast(self))[idx] != 0 and (
            // in safe compilation modes, blow up here if the name is non-sentinel
            // terminated. This would happen anyway on the return,
            // but it's clearer here.
            if (safe_mode) true else idx < self.d_reclen)) : (idx += 1)
        {
            assert(idx < self.d_reclen);
        }

        const d_name_ptr: [*]const u8 = @ptrCast(&(self.d_name));
        return d_name_ptr[0 .. idx - @offsetOf(Dirent, "d_name") :0];
    }
};

pub const LsIterator = struct {
    fd: i32,
    buf: []align(Dirent.buffer_align) u8,
    state: union(enum) {
        pending: void,
        available: struct {
            read_size: usize,
            offset: usize,
        },
    },

    /// Note:
    pub fn next(this: *LsIterator) !?*align(Dirent.buffer_align) Dirent {
        switch (this.state) {
            .pending => {
                var result: usize = undefined;
                while (true) {
                    result = getdents64(this.fd, this.buf.ptr, @intCast(this.buf.len));
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

                        // Documented: Result buffer is too small.
                        //
                        // Undocumented:
                        //  - Observed trying to list /proc/<pid>/net dir
                        E.INVAL => error.INVAL,

                        // No such directory.
                        E.NOENT => error.NOENT,

                        // File descriptor does not refer to a directory.
                        E.NOTDIR => error.NOTDIR,

                        // Undocumented
                        //
                        // Suspect this occurs when user has `x` but not `r`
                        // permissions on the directory
                        E.ACCES => error.ACCES,

                        else => els: {
                            std.log.err("Unhandled code: {}", .{code});
                            break :els error.UndocumentSyscallResponse;
                        },
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
                const prev: *align(Dirent.buffer_align) Dirent = @ptrCast(@alignCast(&this.buf[state.offset]));
                const new_offset = state.offset + prev.d_reclen;
                if (new_offset < state.read_size) {
                    state.*.offset = new_offset;
                    assert(state.offset % Dirent.buffer_align == 0);
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
pub fn ls(buf: []align(Dirent.buffer_align) u8, fd: i32) LsIterator {
    return LsIterator{
        .fd = fd,
        .buf = buf,
        .state = .pending,
    };
}

test "run ls" {
    try skipTest();
    const ret = std.os.linux.open("/", std.os.linux.O{
        .DIRECTORY = true,
        .CREAT = false,
    }, 0);
    try std.testing.expectEqual(std.os.linux.errno(ret), std.os.linux.E.SUCCESS);
    const fd = fd: {
        const i: isize = @bitCast(ret);
        break :fd @as(i32, @intCast(i));
    };
    defer _ = std.os.linux.close(fd);

    var buf: [2048]u8 align(Dirent.buffer_align) = undefined;
    var ls_iter = ls(&buf, fd);
    while (try ls_iter.next()) |dirent| {
        std.log.warn("inode: {}\toff: {}\treclen: {}\ttype: {}\tname: {s}", .{ dirent.d_ino, dirent.d_off, dirent.d_reclen, dirent.d_type, dirent.name() });
    }
}

test "check /nix/store for screwy null bytes" {
    const ret = std.os.linux.open("/nix/store", std.os.linux.O{
        .DIRECTORY = true,
        .CREAT = false,
    }, 0);
    try std.testing.expectEqual(std.os.linux.errno(ret), std.os.linux.E.SUCCESS);
    const fd = fd: {
        const i: isize = @bitCast(ret);
        break :fd @as(i32, @intCast(i));
    };

    defer _ = std.os.linux.close(fd);

    var buf: [2048]u8 align(Dirent.buffer_align) = undefined;
    var ls_iter = ls(&buf, fd);
    var count: usize = 0;
    var acc_name: []const u8 = undefined;
    while (try ls_iter.next()) |dirent| {
        count += 1;
        acc_name = dirent.accurate_name();
        try std.testing.expectEqualSlices(u8, acc_name, dirent.name()[0..acc_name.len]);
        try std.testing.expectEqualSlices(u8, acc_name, dirent.fast_name());
        // File should exist. faccessat doesn't actually open the file
        try std.testing.expectEqual(0, std.os.linux.faccessat(fd, @ptrCast(acc_name.ptr), std.os.linux.F_OK, 0));
    }
}

pub fn openDirAt(dirfd: i32, path: [:0]const u8) !i32 {
    const r = @call(if (config.profile_build) .never_inline else .auto, std.os.linux.openat, .{ dirfd, @as([*:0]const u8, @ptrCast(path.ptr)), std.os.linux.O{
        .DIRECTORY = true,
        .CREAT = false,
    }, 0 });

    switch (std.os.linux.errno(r)) {
        .SUCCESS => {},
        .ACCES => {
            return error.ACCES;
        },
        else => {
            return error.UNKNOWN;
        },
    }
    const fd = fd: {
        const i: isize = @bitCast(r);
        break :fd @as(i32, @intCast(i));
    };
    return fd;
}

test "walk whole filesystem dirs only" {
    try skipTest();

    const gpa = if (safe_mode) std.testing.allocator else std.heap.smp_allocator;
    const init_capacity = 24;

    var iter_pool = std.heap.MemoryPool(LsIterator).empty;
    defer iter_pool.deinit(gpa);
    try iter_pool.addCapacity(gpa, init_capacity);

    var buf_pool = std.heap.memory_pool.Aligned([2 << 10]u8, std.mem.Alignment.fromByteUnits(Dirent.buffer_align)).empty;
    defer buf_pool.deinit(gpa);
    try buf_pool.addCapacity(gpa, init_capacity);

    var stack = try std.ArrayList(*LsIterator)
        .initCapacity(gpa, init_capacity);
    defer stack.deinit(gpa);
    errdefer {
        while (stack.pop()) |iter| {
            _ = std.os.linux.close(iter.fd);
        }
    }

    {
        const root_fd = try openDirAt(0, "/");
        const iter_p = try iter_pool.create(gpa);
        iter_p.* = ls(try buf_pool.create(gpa), root_fd);
        try stack.append(gpa, iter_p);
    }

    var dot_h_file_count: i32 = 0;

    stk: while (stack.getLastOrNull()) |ls_iter| {
        ls_iter: while (ls_iter.next()) |maybe_dirent| {
            const dirent = maybe_dirent orelse break;
            switch (dirent.d_type) {
                .reg => {
                    const name = dirent.fast_name();
                    if (name.len > 2 and name[name.len - 2] == '.' and name[name.len - 1] == 'h') {
                        dot_h_file_count += 1;
                    }
                },
                .dir => {
                    const name = dirent.fast_name();
                    // . and ..
                    if (dirent.d_reclen == 24) {
                        if (name.len < 3 and name[0] == '.' and (name.len == 1 or name[1] == '.')) {
                            continue;
                        }
                    }

                    const entry_fd = openDirAt(ls_iter.fd, name) catch {
                        continue;
                    };
                    const iter_p = try iter_pool.create(gpa);
                    iter_p.* = ls(try buf_pool.create(gpa), entry_fd);
                    try stack.append(gpa, iter_p);
                    continue :stk;
                },
                else => {},
            }
        } else |err| { // ls_iter.next
            switch (err) {
                error.ACCES, error.BADF, error.INVAL, error.NOENT, error.NOTDIR => break :ls_iter,
                else => return err,
            }
        }

        buf_pool.destroy(@ptrCast(ls_iter.buf));
        _ = std.os.linux.close(ls_iter.fd);
        iter_pool.destroy(ls_iter);
        _ = stack.pop();
    }

    std.log.warn(".h files: {}", .{dot_h_file_count});
}

pub const ScannedDirs = struct {
    pub const Index = packed struct(u32) {
        block: u16,
    };

    blocksize: usize,

    alloc: std.mem.Allocator,
};

fn skipTest() !void {
    return error.SkipZigTest;
}
