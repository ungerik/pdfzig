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

    // Clean step - removes build artifacts and caches
    const clean_step = b.step("clean", "Remove build artifacts and caches");
    clean_step.dependOn(&b.addRemoveDirTree(.{ .cwd_relative = ".zig-cache" }).step);
    clean_step.dependOn(&b.addRemoveDirTree(.{ .cwd_relative = "zig-out" }).step);
    clean_step.dependOn(&b.addRemoveDirTree(.{ .cwd_relative = "test-cache" }).step);

    // Format check step
    const fmt_step = b.step("fmt", "Check source code formatting");
    const fmt = b.addFmt(.{
        .paths = &.{ "src", "build.zig" },
        .check = true,
    });
    fmt_step.dependOn(&fmt.step);

    // Format fix step
    const fmt_fix_step = b.step("fmt-fix", "Fix source code formatting");
    const fmt_fix = b.addFmt(.{
        .paths = &.{ "src", "build.zig" },
    });
    fmt_fix_step.dependOn(&fmt_fix.step);

    // Cross-compile for all supported platforms
    const all_step = b.step("all", "Build for all supported platforms");

    // Option to download PDFium for each target platform
    const download_pdfium = b.option(bool, "download-pdfium", "Download PDFium libraries for each target platform") orelse false;

    // Build the download helper if needed
    var download_helper: ?*std.Build.Step.Compile = null;
    if (download_pdfium) {
        const helper_mod = b.createModule(.{
            .root_source_file = b.path("src/build_download_helper.zig"),
            .target = b.graph.host,
        });
        helper_mod.link_libc = true;

        download_helper = b.addExecutable(.{
            .name = "build_download_helper",
            .root_module = helper_mod,
        });
    }

    const targets: []const std.Target.Query = &.{
        .{ .cpu_arch = .x86_64, .os_tag = .macos },
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .arm, .os_tag = .linux, .abi = .gnueabihf },
        .{ .cpu_arch = .x86_64, .os_tag = .windows },
        .{ .cpu_arch = .x86, .os_tag = .windows },
        .{ .cpu_arch = .aarch64, .os_tag = .windows },
    };

    for (targets) |t| {
        const cross_target = b.resolveTargetQuery(t);

        const cross_zigimg = b.dependency("zigimg", .{
            .target = cross_target,
            .optimize = optimize,
        });

        const cross_zstbi = b.dependency("zstbi", .{
            .target = cross_target,
            .optimize = optimize,
        });

        const cross_mod = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = cross_target,
            .optimize = optimize,
        });

        cross_mod.addImport("zigimg", cross_zigimg.module("zigimg"));
        cross_mod.addImport("zstbi", cross_zstbi.module("root"));
        cross_mod.link_libc = true;

        const cross_exe = b.addExecutable(.{
            .name = "pdfzig",
            .root_module = cross_mod,
        });

        const target_triple = t.zigTriple(b.allocator) catch @panic("OOM");
        const install = b.addInstallArtifact(cross_exe, .{
            .dest_dir = .{ .override = .{ .custom = target_triple } },
        });

        // Run download helper to fetch PDFium for this target (if enabled)
        if (download_helper) |helper| {
            const download_run = b.addRunArtifact(helper);
            download_run.addArg(@tagName(t.cpu_arch.?));
            download_run.addArg(@tagName(t.os_tag.?));
            // Output directory: zig-out/<target-triple>/
            const output_dir = b.fmt("{s}/{s}", .{ b.install_path, target_triple });
            download_run.addArg(output_dir);
            // Download must happen after install creates the directory
            download_run.step.dependOn(&install.step);

            all_step.dependOn(&download_run.step);
        } else {
            all_step.dependOn(&install.step);
        }
    }
}
