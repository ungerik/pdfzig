const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get zigimg dependency
    const zigimg_dep = b.dependency("zigimg", .{
        .target = target,
        .optimize = optimize,
    });

    // Get zstbi dependency for JPEG encoding
    const zstbi_dep = b.dependency("zstbi", .{
        .target = target,
        .optimize = optimize,
    });

    // Create the main module
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add zigimg import
    exe_mod.addImport("zigimg", zigimg_dep.module("zigimg"));

    // Add zstbi import for JPEG encoding
    exe_mod.addImport("zstbi", zstbi_dep.module("root"));

    // Link libc for dlopen on Unix
    exe_mod.link_libc = true;

    // Build the executable
    const exe = b.addExecutable(.{
        .name = "pdfzig",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    // Install license files
    b.installFile("LICENSE", "LICENSE");
    b.installFile("THIRD_PARTY_NOTICES.md", "THIRD_PARTY_NOTICES.md");

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run pdfzig");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    test_mod.addImport("zigimg", zigimg_dep.module("zigimg"));
    test_mod.addImport("zstbi", zstbi_dep.module("root"));
    test_mod.link_libc = true;

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
