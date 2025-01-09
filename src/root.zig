const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

pub const global_allocator = @import("global_allocator.zig").allocator;
pub const Heap = @import("heap.zig");
const mi = @import("c.zig");

pub fn check_owned(ptr: *const anyopaque) bool {
    return mi.mi_check_owned(ptr);
}

// test "basic add functionality" {
//     try testing.expect(add(3, 7) == 10);
// }
