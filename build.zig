const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // This creates a "module", which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Every executable or library we compile will be based on one or more modules.
    const lib_mod = b.addModule("mimalloc", .{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
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

    if (target.result.isMusl()) {
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
