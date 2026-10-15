const std = @import("std");
const builtin = @import("builtins");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Error = error{
    InvalidWd,

    Details,
    OutOfMemory,
};

pub const ErrorCtx = struct {
    alloc: Allocator,

    ///
    pub fn init(alloc: Allocator) Errors {}

    pub fn deinit() void {}
};

pub const Result = struct {
    pub const Elt = union(enum) {
        sep: void,
        homedir: void,
        utf8: []u8,
        binary: []u8,
    }
    /// don't depend on this to be constant
    sep: []u8 = "/",
    elts: std.ArrayList(Elt),
    
    
    pub fn ansi(self: *Result, sink: std.Io.Writer) std.Io.Writer.Error!usize {
        return 0;
    }

    pub fn debug(self: *Result, sink: std.Io.Writer) std.Io.Writer.Error!usize {
        return 0;
    }
};

/// Fully parameterized implementation
///
/// - Working directories that don't exist on disk *are allowed*, although
///   compression may not work as well
/// - File names *should* be valid UTF-8. UTF-16 etc. file names not currently supported.
/// - Results must be safe to render
/// - Don't depend on this function to be *perfect* on actual rendered width.
///   We do our best, but perfection is impossible without access to the font.
pub fn printwd(io: Io, alloc: Allocator, home_dir: ?[]u8, wd: []u8, target_grapheme_width: u64) Error!Result {

    return .{};
}
