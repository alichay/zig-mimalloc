const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const mi = @import("c.zig");

var garbage_state: i32 = 0;

var vtable = Allocator.VTable{};

var allocator_object = Allocator{
    .ptr = &garbage_state,
    .vtable = &vtable,
};

pub const allocator = &allocator_object;

fn mimalloc_alloc(_: *anyopaque, len: usize, ptr_align: u8, _: usize) ?[*]u8 {
    assert(len > 0);
    assert(ptr_align > 0);
    assert(std.math.isPowerOfTwo(ptr_align));

    var res_ptr = mi.mi_malloc_aligned(len, ptr_align) orelse return null;
    return @ptrCast([*]u8, res_ptr);
}

fn mimalloc_resize(_: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, _: usize) bool {
    assert(new_len > 0);
    assert(buf.len > 0);
    assert(buf_align > 0);
    assert(std.math.isPowerOfTwo(buf_align));

    return mi.mi_expand(buf.ptr, new_len) != null;
}
fn mimalloc_free(_: *anyopaque, buf: []u8, buf_align: u8, _: usize) void {
    return mi.mi_free_aligned(buf.ptr, buf_align);
}
