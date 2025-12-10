const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

pub const global_allocator = @import("global_allocator.zig").allocator;
pub const Heap = @import("Heap.zig");
pub const c = @import("c.zig").mi;

pub fn check_owned(ptr: *const anyopaque) bool {
    return c.mi_check_owned(ptr);
}
