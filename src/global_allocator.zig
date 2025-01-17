const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const mi = @import("c.zig");

var garbage_state: i32 = 0;

var vtable = Allocator.VTable{
    .alloc = mimalloc_alloc,
    .resize = mimalloc_resize,
    .free = mimalloc_free,
};

pub const allocator = Allocator{
    .ptr = &garbage_state,
    .vtable = &vtable,
};

fn mimalloc_alloc(_: *anyopaque, len: usize, log2_align: u8, _: usize) ?[*]u8 {
    assert(len > 0);
    assert(log2_align > 0);
    const alignment = @as(usize, 1) << @as(Allocator.Log2Align, @intCast(log2_align));

    const res_ptr = mi.mi_malloc_aligned(len, alignment) orelse return null;
    return @ptrCast(res_ptr);
}

fn mimalloc_resize(_: *anyopaque, buf: []u8, log2_align: u8, new_len: usize, _: usize) bool {
    assert(new_len > 0);
    assert(buf.len > 0);
    assert(log2_align > 0);

    return mi.mi_expand(buf.ptr, new_len) != null;
}
fn mimalloc_free(_: *anyopaque, buf: []u8, log2_align: u8, _: usize) void {
    assert(log2_align > 0);
    const alignment = @as(usize, 1) << @as(Allocator.Log2Align, @intCast(log2_align));
    return mi.mi_free_aligned(buf.ptr, alignment);
}
