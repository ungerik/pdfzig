const std = @import("std");
const builtin = @import("builtin");

/// Add pdfzig library dependencies to a module
fn addPdfzigDeps(
    mod: *std.Build.Module,
    zigimg_mod: *std.Build.Module,
    zstbi_mod: *std.Build.Module,
    glob_mod: *std.Build.Module,
) void {
    mod.addImport("zigimg", zigimg_mod);
    mod.addImport("zstbi", zstbi_mod);
    mod.addImport("glob", glob_mod);
    mod.link_libc = true;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Option to download PDFium libraries
    const download_pdfium = b.option(bool, "download-pdfium", "Download PDFium library for target platform(s)") orelse false;

    // Build the download helper if needed (for host platform)
    var download_helper: ?*std.Build.Step.Compile = null;
    if (download_pdfium) {
        const helper_mod = b.createModule(.{
            .root_source_file = b.path("src/pdfium/build_download_helper.zig"),
            .target = b.graph.host,
        });
        helper_mod.link_libc = true;

        download_helper = b.addExecutable(.{
            .name = "build_download_helper",
            .root_module = helper_mod,
        });
    }

    // Get dependencies
    const zigimg_dep = b.dependency("zigimg", .{
        .target = target,
        .optimize = optimize,
    });

    const zstbi_dep = b.dependency("zstbi", .{
        .target = target,
        .optimize = optimize,
    });

    const glob_dep = b.dependency("glob", .{
        .target = target,
        .optimize = optimize,
    });

    // Create pdfzig library module
    const pdfzig_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    addPdfzigDeps(pdfzig_mod, zigimg_dep.module("zigimg"), zstbi_dep.module("root"), glob_dep.module("glob"));

    // Create the main executable module
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    addPdfzigDeps(exe_mod, zigimg_dep.module("zigimg"), zstbi_dep.module("root"), glob_dep.module("glob"));
    exe_mod.addImport("pdfzig", pdfzig_mod);

    // Build the executable
    const exe = b.addExecutable(.{
        .name = "pdfzig",
        .root_module = exe_mod,
    });

    const install_exe = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_exe.step);

    // Download PDFium for native target if enabled
    if (download_helper) |helper| {
        const resolved = target.result;
        const download_run = b.addRunArtifact(helper);
        download_run.addArg(@tagName(resolved.cpu.arch));
        download_run.addArg(@tagName(resolved.os.tag));
        download_run.addArg(b.fmt("{s}/bin", .{b.install_path}));
        download_run.step.dependOn(&install_exe.step);
        b.getInstallStep().dependOn(&download_run.step);
    }

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
    addPdfzigDeps(test_mod, zigimg_dep.module("zigimg"), zstbi_dep.module("root"), glob_dep.module("glob"));
    test_mod.addImport("pdfzig", pdfzig_mod);

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Golden file generation step
    const golden_files_clean = b.option(bool, "clean", "Delete existing golden files before regenerating") orelse false;

    const golden_files_helper_mod = b.createModule(.{
        .root_source_file = b.path("src/build_golden_files_helper.zig"),
        .target = b.graph.host,
    });
    addPdfzigDeps(golden_files_helper_mod, zigimg_dep.module("zigimg"), zstbi_dep.module("root"), glob_dep.module("glob"));

    const golden_files_helper = b.addExecutable(.{
        .name = "build_golden_files_helper",
        .root_module = golden_files_helper_mod,
    });

    const golden_files_run = b.addRunArtifact(golden_files_helper);
    if (golden_files_clean) {
        golden_files_run.addArg("--clean");
    }

    const golden_files_step = b.step("generate-golden-files", "Generate golden test files");
    golden_files_step.dependOn(&golden_files_run.step);

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

    const cross_targets: []const std.Target.Query = &.{
        .{ .cpu_arch = .x86_64, .os_tag = .macos },
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .arm, .os_tag = .linux, .abi = .gnueabihf },
        .{ .cpu_arch = .x86_64, .os_tag = .windows },
        .{ .cpu_arch = .x86, .os_tag = .windows },
        .{ .cpu_arch = .aarch64, .os_tag = .windows },
    };

    for (cross_targets) |t| {
        const cross_target = b.resolveTargetQuery(t);

        const cross_zigimg = b.dependency("zigimg", .{
            .target = cross_target,
            .optimize = optimize,
        });

        const cross_zstbi = b.dependency("zstbi", .{
            .target = cross_target,
            .optimize = optimize,
        });

        const cross_glob = b.dependency("glob", .{
            .target = cross_target,
            .optimize = optimize,
        });

        const cross_pdfzig_mod = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = cross_target,
            .optimize = optimize,
        });
        addPdfzigDeps(cross_pdfzig_mod, cross_zigimg.module("zigimg"), cross_zstbi.module("root"), cross_glob.module("glob"));

        const cross_mod = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = cross_target,
            .optimize = optimize,
        });
        addPdfzigDeps(cross_mod, cross_zigimg.module("zigimg"), cross_zstbi.module("root"), cross_glob.module("glob"));
        cross_mod.addImport("pdfzig", cross_pdfzig_mod);

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
