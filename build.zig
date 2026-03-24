const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe_optimize: std.builtin.OptimizeMode = if (optimize == .Debug) .ReleaseFast else optimize;

    const lib_mod = b.addModule("dspdsl", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = exe_optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = exe_optimize,
    });
    exe_mod.addImport("dspdsl", lib_mod);

    const exe = b.addExecutable(.{
        .name = "dspdsl",
        .root_module = exe_mod,
    });
    exe.linkLibC();
    exe.linkSystemLibrary("asound");
    exe.linkSystemLibrary("X11");
    b.installArtifact(exe);

    const surface_test_mod = b.createModule(.{
        .root_source_file = b.path("src/surface.zig"),
        .target = target,
        .optimize = optimize,
    });
    const surface_tests = b.addTest(.{
        .root_module = surface_test_mod,
    });
    const run_surface_tests = b.addRunArtifact(surface_tests);

    const realtime_test_mod = b.createModule(.{
        .root_source_file = b.path("src/realtime.zig"),
        .target = target,
        .optimize = optimize,
    });
    const realtime_tests = b.addTest(.{
        .root_module = realtime_test_mod,
    });
    realtime_tests.linkLibC();
    realtime_tests.linkSystemLibrary("asound");
    realtime_tests.linkSystemLibrary("X11");
    const run_realtime_tests = b.addRunArtifact(realtime_tests);

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench_runtime.zig"),
        .target = target,
        .optimize = exe_optimize,
    });
    const bench_exe = b.addExecutable(.{
        .name = "bench-runtime",
        .root_module = bench_mod,
    });
    const run_bench = b.addRunArtifact(bench_exe);

    const test_step = b.step("test", "Run Zig tests");
    test_step.dependOn(&run_surface_tests.step);
    test_step.dependOn(&run_realtime_tests.step);

    const bench_step = b.step("bench-runtime", "Run Zig runtime benchmarks");
    bench_step.dependOn(&run_bench.step);
}
