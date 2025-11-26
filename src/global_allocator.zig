const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const mi = @import("c.zig").mi;

var garbage_state: i32 = 0;

var vtable = Allocator.VTable{
    .alloc = mimalloc_alloc,
    .resize = mimalloc_resize,
    .remap = mimalloc_remap,
    .free = mimalloc_free,
};

pub const allocator = Allocator{
    .ptr = &garbage_state,
    .vtable = &vtable,
};

fn mimalloc_alloc(_: *anyopaque, len: usize, log2_align: std.mem.Alignment, _: usize) ?[*]u8 {
    assert(len > 0);
    const alignment = log2_align.toByteUnits();

    const res_ptr = mi.mi_malloc_aligned(len, alignment) orelse return null;
    return @ptrCast(res_ptr);
}

fn mimalloc_resize(_: *anyopaque, buf: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
    assert(new_len > 0);
    assert(buf.len > 0);

    return mi.mi_expand(buf.ptr, new_len) != null;
}
fn mimalloc_remap(_: *anyopaque, buf: []u8, log2_align: std.mem.Alignment, new_len: usize, _: usize) ?[*]u8 {
    assert(new_len > 0);
    assert(buf.len > 0);

    const res_ptr = mi.mi_realloc_aligned(buf.ptr, new_len, log2_align.toByteUnits()) orelse return null;
    return @ptrCast(res_ptr);
}
fn mimalloc_free(_: *anyopaque, buf: []u8, log2_align: std.mem.Alignment, _: usize) void {
    const alignment = log2_align.toByteUnits();
    return mi.mi_free_aligned(buf.ptr, alignment);
}
