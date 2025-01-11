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

const Self = @This();

var thread_check_state: if (debug_assert) struct {
    heap_ptr_to_thread_id: std.AutoHashMap(*mi.mi_heap_t, std.Thread.Id) = .{
        .unmanaged = .empty,
        .allocator = @import("global_allocator.zig").allocator,
        .ctx = undefined,
    },
    mtx: std.Thread.Mutex = .{},

    const ThreadCheckState = @This();

    pub fn push(self: *ThreadCheckState, heap: *mi.mi_heap_t) void {
        self.mtx.lock();
        defer self.mtx.unlock();

        self.heap_ptr_to_thread_id.put(heap, std.Thread.getCurrentId()) catch unreachable;
    }
    pub fn remove(self: *ThreadCheckState, heap: *mi.mi_heap_t) void {
        self.mtx.lock();
        defer self.mtx.unlock();

        self.heap_ptr_to_thread_id.remove(heap) catch unreachable;
    }
    pub fn get(self: *ThreadCheckState, heap: *mi.mi_heap_t) ?std.Thread.Id {
        self.mtx.lock();
        defer self.mtx.unlock();

        return self.heap_ptr_to_thread_id.get(heap);
    }
} else struct {} = .{};

internal: *mi.mi_heap_t,

inline fn debug_assert_thread(heap: *mi.mi_heap_t) void {
    comptime if (debug_assert) {
        if (thread_check_state.get(heap)) |thread_id| {
            assert(thread_id == std.Thread.getCurrentId());
        } else {
            std.log.err("thread_check_state.get(heap) returned null", .{});
        }
    };
}

fn from_c(heap: *mi.mi_heap_t) Self {
    comptime if (debug_assert) {
        thread_check_state.push(heap);
    };

    return .{ .internal = heap };
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
    assert(self.internal != (mi.mi_heap_get_backing() orelse unreachable));

    comptime if (debug_assert) {
        thread_check_state.remove(self.internal);
    };

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

pub inline fn free(_: *Self, ptr: *const anyopaque, opt_ptr_align: ?u8) void {
    if (opt_ptr_align) |ptr_align| {
        mi.mi_free_aligned(ptr, ptr_align);
    } else {
        mi.mi_free(ptr);
    }
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

fn allocator_alloc(ctx: *anyopaque, len: usize, ptr_align: u8, _: usize) ?[*]u8 {
    var heap = Self{ .internal = @ptrCast(@alignCast(ctx)) };
    return heap.malloc(len, ptr_align);
}
fn allocator_resize(ctx: *anyopaque, buf: []u8, _: u8, new_len: usize, _: usize) bool {
    var heap = Self{ .internal = @ptrCast(@alignCast(ctx)) };
    return heap.resize_in_place(buf, new_len) != null;
}
fn allocator_free(ctx: *anyopaque, buf: []u8, buf_align: u8, _: usize) void {
    var heap = Self{ .internal = @ptrCast(@alignCast(ctx)) };
    assert(buf.len > 0);
    assert(buf_align > 0);
    assert(std.math.isPowerOfTwo(buf_align));
    heap.free(buf.ptr, buf_align);
}

const vtable = std.mem.Allocator.VTable{
    .alloc = allocator_alloc,
    .resize = allocator_resize,
    .free = allocator_free,
};

pub fn allocator(self: *Self) std.mem.Allocator {
    return .{ .ptr = self.internal, .vtable = &vtable };
}
