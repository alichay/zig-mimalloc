/// A thread-local heap.
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const mi = @import("c.zig").mi;
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

        self.heap_ptr_to_thread_id.put(heap, std.Thread.getCurrentId()) catch @panic("failed to push heap<->thread id");
    }
    pub fn remove(self: *ThreadCheckState, heap: *mi.mi_heap_t) void {
        self.mtx.lock();
        defer self.mtx.unlock();

        if (!self.heap_ptr_to_thread_id.remove(heap)) @panic("heap not found");
    }
    pub fn get(self: *ThreadCheckState, heap: *mi.mi_heap_t) ?std.Thread.Id {
        self.mtx.lock();
        defer self.mtx.unlock();

        return self.heap_ptr_to_thread_id.get(heap);
    }
} else struct {} = .{};

internal: *mi.mi_heap_t,

inline fn debug_assert_thread(heap: *mi.mi_heap_t) void {
    if (debug_assert) {
        if (thread_check_state.get(heap)) |thread_id| {
            assert(thread_id == std.Thread.getCurrentId());
        } else {
            std.log.err("thread_check_state.get(heap) returned null", .{});
        }
    }
}

inline fn from_c(heap: *mi.mi_heap_t) Self {
    if (debug_assert) {
        thread_check_state.push(heap);
    }

    return .{ .internal = heap };
}

/// Create a new heap.
pub inline fn init() Self {
    return from_c(mi.mi_heap_new() orelse @panic("unable to allocate heap"));
}

/// Get the backing heap. This is the *initial* default heap, and cannot be destroyed.
pub inline fn get_backing_heap() Self {
    return from_c(mi.mi_heap_get_backing() orelse unreachable);
}

/// Get the thread's current default heap, used for mi_malloc/mi_free etc.
pub inline fn get_default() Self {
    return from_c(mi.mi_heap_get_default() orelse unreachable);
}

/// Set a heap as the thread's default heap. This makes the `global_allocator` use this heap when called from this thread.
pub inline fn set_as_thread_default(self: *Self) void {
    mi.mi_heap_set_default(self.internal);
}

/// Destroy the heap. If `free_allocations` is true, then all allocations
/// will be freed - otherwise, they will be returned to the global allocator's heap.
pub inline fn deinit(self: *Self, free_allocations: bool) void {

    // Ensure we're not trying to deestroy the backing heap.
    assert(self.internal != (mi.mi_heap_get_backing() orelse unreachable));

    if (debug_assert) {
        thread_check_state.remove(self.internal);
    }

    if (free_allocations) {
        mi.mi_heap_destroy(self.internal);
    } else {
        mi.mi_heap_delete(self.internal);
    }
}

/// Allocate a block of memory.
pub inline fn malloc(self: *Self, len: usize, opt_ptr_align: ?std.mem.Alignment) ?[]u8 {
    debug_assert_thread(self.internal);

    assert(len > 0);

    const ret = alloc: {
        if (opt_ptr_align) |alignment| {
            break :alloc mi.mi_heap_malloc_aligned(self.internal, len, alignment.toByteUnits());
        } else {
            break :alloc mi.mi_heap_malloc(self.internal, len);
        }
    } orelse return null;

    const ret_u8: [*]u8 = @ptrCast(ret);
    return ret_u8[0..len];
}

/// Allocate a *small* block of memory. `len` must be less than `Heap.SMALL_ALLOC_MAX`.
pub inline fn malloc_small(self: *Self, len: usize) ?[]u8 {
    debug_assert_thread(self.internal);
    assert(len > 0);
    assert(len < SMALL_ALLOC_MAX);

    const ret = mi.mi_heap_malloc_small(self.internal, len) orelse return null;

    const ret_u8: [*]u8 = @ptrCast(ret);
    return ret_u8[0..len];
}

pub inline fn resize_in_place(_: *Self, buf: []u8, new_len: usize) ?[]u8 {
    assert(buf.len > 0);
    assert(new_len > 0);

    if (mi.mi_expand(buf.ptr, new_len)) |ret| {
        const ret_u8: [*]u8 = @ptrCast(ret);
        assert(ret_u8 == buf.ptr);
        return ret_u8[0..new_len];
    }
    return null;
}

/// Resize a chunk of memory. No guarantees are made that this operation will keep the same base address.
/// Buf must be a slice of a previously allocated buffer.
/// Buf.len must be the same as the previous allocation.
/// If opt_ptr_align is provided, it must be the same as the previous allocation.
pub inline fn realloc(self: *Self, buf: []u8, new_len: usize, opt_ptr_align: ?std.mem.Alignment) ?[]u8 {
    debug_assert_thread(self.internal);

    assert(buf.len > 0);
    assert(new_len > 0);

    const ret = alloc: {
        if (opt_ptr_align) |alignment| {
            break :alloc mi.mi_heap_realloc_aligned(self.internal, buf.ptr, new_len, alignment.toByteUnits());
        } else {
            break :alloc mi.mi_heap_realloc(self.internal, buf.ptr, new_len);
        }
    } orelse return null;

    const ret_u8: [*]u8 = @ptrCast(ret);
    return ret_u8[0..new_len];
}

pub inline fn free(_: *Self, ptr: *const anyopaque, opt_ptr_align: ?std.mem.Alignment) void {
    if (opt_ptr_align) |alignment| {
        mi.mi_free_aligned(@constCast(ptr), alignment.toByteUnits());
    } else {
        mi.mi_free(@constCast(ptr));
    }
}

/// Release outstanding resources.
/// Regular code should not have to call this function. It can be beneficial in very narrow circumstances;
/// in particular, when a long running thread allocates a lot of blocks that are freed by other
/// threads it may improve resource usage by calling this every once in a while.
pub fn collect(self: *Self, force: bool) void {
    debug_assert_thread(self.internal);
    mi.mi_heap_collect(self.internal, force);
}

pub fn owns(self: *Self, ptr: *const anyopaque) bool {
    return mi.mi_heap_check_owned(self.internal, ptr);
}

fn allocator_alloc(ctx: *anyopaque, len: usize, log2_align: std.mem.Alignment, _: usize) ?[*]u8 {
    var heap = Self{ .internal = @ptrCast(@alignCast(ctx)) };
    const ret: []u8 = heap.malloc(len, log2_align) orelse return null;
    return @ptrCast(ret.ptr);
}
fn allocator_resize(ctx: *anyopaque, buf: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
    var heap = Self{ .internal = @ptrCast(@alignCast(ctx)) };
    return heap.resize_in_place(buf, new_len) != null;
}
fn allocator_remap(ctx: *anyopaque, buf: []u8, log2_align: std.mem.Alignment, new_len: usize, _: usize) ?[*]u8 {
    var heap = Self{ .internal = @ptrCast(@alignCast(ctx)) };
    assert(buf.len > 0);
    const ret = heap.realloc(buf, new_len, log2_align) orelse return null;
    return @ptrCast(ret.ptr);
}
fn allocator_free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, _: usize) void {
    var heap = Self{ .internal = @ptrCast(@alignCast(ctx)) };
    assert(buf.len > 0);
    heap.free(buf.ptr, buf_align);
}

const vtable = std.mem.Allocator.VTable{
    .alloc = allocator_alloc,
    .resize = allocator_resize,
    .remap = allocator_remap,
    .free = allocator_free,
};

pub fn allocator(self: *Self) std.mem.Allocator {
    return .{ .ptr = self.internal, .vtable = &vtable };
}
