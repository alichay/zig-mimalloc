const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.addModule("mimalloc", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const c_sources = b.dependency("mimalloc-src", .{});
    lib_mod.link_libc = true;

    lib_mod.addIncludePath(c_sources.path("include"));

    const secure = b.option(bool, "secure", "Use full security mitigations (like guard pages, allocation randomization, double-free mitigation, and free-list corruption detection)") orelse false;
    const debug_full = b.option(bool, "debug_full", "Use full internal heap invariant checking in DEBUG mode (expensive)") orelse switch (optimize) {
        .Debug => true,
        .ReleaseSafe, .ReleaseFast, .ReleaseSmall => false,
    };
    const padding = b.option(bool, "padding", "Enable padding to detect heap block overflow (always on in DEBUG or SECURE mode, or with Valgrind/ASAN)") orelse false;

    if (target.result.isMuslLibC()) {
        lib_mod.addCMacro("MI_LIBC_MUSL", "1");
    }

    if (secure) {
        lib_mod.addCMacro("MI_SECURE", "4");
    }

    if (debug_full) {
        lib_mod.addCMacro("MI_DEBUG", "3");
    }

    if (padding) {
        lib_mod.addCMacro("MI_PADDING", "1");
    }

    switch (optimize) {
        .ReleaseFast, .ReleaseSmall => {
            lib_mod.addCMacro("NDEBUG", "1");
        },
        .Debug, .ReleaseSafe => {},
    }

    const tsan = lib_mod.sanitize_thread != null and lib_mod.sanitize_thread.?;
    const ubsan = lib_mod.sanitize_c != null and lib_mod.sanitize_c.?;
    const valgrind = lib_mod.valgrind != null and lib_mod.valgrind.?;

    if (tsan) {
        lib_mod.addCMacro("MI_TSAN", "1");
    }

    if (ubsan) {
        lib_mod.addCMacro("MI_UBSAN", "1");
        lib_mod.addCSourceFile(.{ .file = b.path("src/ubsan_main.cpp") });
        lib_mod.addIncludePath(c_sources.path("src"));
        lib_mod.link_libcpp = true;
    } else {
        lib_mod.addCSourceFile(.{ .file = c_sources.path("src/static.c") });
    }

    if (valgrind) {
        lib_mod.addCMacro("MI_TRACK_VALGRIND", "1");
    }
}
