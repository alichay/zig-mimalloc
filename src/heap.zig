/// A thread-local heap.
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const mi = @import("c.zig");
/// The maximum size of a small allocation.
/// Usually 128 * sizeof(void*), which is 1KB on 64-bit systems.
pub const SMALL_ALLOC_MAX: usize = mi.MI_SMALL_SIZE_MAX;

const debug_assert: bool = switch (builtin.mode) {
    .Debug, .ReleaseSafe => true,
    else => false,
};

const DebugThreadId = if (debug_assert) std.Thread.Id else void;
const DebugBackingHeap = if (debug_assert) mi.mi_heap_t else void;

const Self = @This();

thread_id: DebugThreadId,
thread_backing_heap: DebugBackingHeap,
internal: *mi.mi_heap_t,

inline fn debug_assert_thread(self: *Self) void {
    comptime if (debug_assert) {
        assert(self.thread_id == std.Thread.getCurrentId());
    };
}

fn from_c(heap: *mi.mi_heap_t) Self {
    var thread_id: DebugThreadId = undefined;
    var thread_backing_heap: DebugBackingHeap = undefined;
    comptime if (debug_assert) {
        thread_id = std.Thread.getCurrentId();
        thread_backing_heap = mi.mi_heap_get_backing() orelse unreachable;
    };

    return .{
        .thread_id = thread_id,
        .thread_backing_heap = thread_backing_heap,
        .internal = heap,
    };
}

/// Create a new heap.
pub fn new() Self {
    return from_c(mi.mi_heap_new() orelse @panic("unable to allocate heap"));
}

/// Get the backing heap. This is the *initial* default heap, and cannot be destroyed.
pub fn get_backing_heap() Self {
    return from_c(mi.mi_heap_get_backing() orelse unreachable);
}

/// Get the thread's current default heap, used for mi_malloc/mi_free etc.
pub fn get_default() Self {
    return from_c(mi.mi_heap_get_default() orelse unreachable);
}

/// Set a heap as the thread's default heap. This makes the `global_allocator` use this heap when called from this thread.
pub fn set_as_thread_default(self: *Self) void {
    mi.mi_heap_set_default(self.internal);
}

/// Destroy the heap. If `free_allocations` is true, then all allocations
/// will be freed - otherwise, they will be returned to the global allocator's heap.
pub fn deinit(self: *Self, free_allocations: bool) void {

    // Ensure we're not trying to deestroy the backing heap.
    assert(self.thread_backing_heap != (mi.mi_heap_get_backing() orelse unreachable));

    if (free_allocations) {
        mi.mi_heap_destroy(self.internal);
    } else {
        mi.mi_heap_delete(self.internal);
    }
}

/// Allocate a block of memory.
pub fn malloc(self: *Self, len: usize, opt_ptr_align: ?u8) ?[]u8 {
    self.debug_assert_thread();

    assert(len > 0);

    const ret = alloc: {
        if (opt_ptr_align) |ptr_align| {
            assert(ptr_align > 0);
            assert(std.math.isPowerOfTwo(ptr_align));

            break :alloc mi.mi_heap_malloc_aligned(self.internal, len, ptr_align);
        } else {
            break :alloc mi.mi_heap_malloc(self.internal, len);
        }
    };
    return (ret orelse return null)[0..len];
}

/// Allocate a *small* block of memory. `len` must be less than `Heap.SMALL_ALLOC_MAX`.
pub fn malloc_small(self: *Self, len: usize) ?[]u8 {
    self.debug_assert_thread();
    assert(len > 0);
    assert(len < SMALL_ALLOC_MAX);

    const ret = mi.mi_heap_malloc_small(self.internal, len);
    return (ret orelse return null)[0..len];
}

pub fn resize_in_place(_: *Self, buf: []u8, new_len: usize) ?[]u8 {
    assert(buf.len > 0);
    assert(new_len > 0);

    if (mi.mi_expand(buf.ptr, new_len)) |ret| {
        assert(ret.ptr == buf.ptr);
        return ret[0..new_len];
    }
    return null;
}

/// Resize a chunk of memory. No guarantees are made that this operation will keep the same base address.
/// Buf must be a slice of a previously allocated buffer.
/// Buf.len must be the same as the previous allocation.
/// If opt_ptr_align is provided, it must be the same as the previous allocation.
pub fn realloc(self: *Self, buf: []u8, new_len: usize, opt_ptr_align: ?u8) ?[]u8 {
    self.debug_assert_thread();

    assert(buf.len > 0);
    assert(new_len > 0);

    const ret = alloc: {
        if (opt_ptr_align) |ptr_align| {
            assert(ptr_align > 0);
            assert(std.math.isPowerOfTwo(ptr_align));

            break :alloc mi.mi_heap_realloc_aligned(self.internal, buf.ptr, new_len, ptr_align);
        } else {
            break :alloc mi.mi_heap_realloc(self.internal, buf.ptr, new_len);
        }
    };

    return (ret orelse return null)[0..new_len];
}

/// Release outstanding resources.
/// Regular code should not have to call this function. It can be beneficial in very narrow circumstances;
/// in particular, when a long running thread allocates a lot of blocks that are freed by other
/// threads it may improve resource usage by calling this every once in a while.
pub fn collect(self: *Self, force: bool) void {
    self.debug_assert_thread();
    mi.mi_heap_collect(self.internal, force);
}

pub fn owns(self: *Self, ptr: *const anyopaque) bool {
    return mi.mi_heap_check_owned(self.internal, ptr);
}
