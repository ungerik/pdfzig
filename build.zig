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

    // Get PDFium asset name for the target platform
    const pdfium_asset = getPdfiumAssetName(target) orelse
        @panic("Unsupported target platform for PDFium");

    const pdfium_url = b.fmt(
        "https://github.com/bblanchon/pdfium-binaries/releases/latest/download/{s}",
        .{pdfium_asset},
    );

    // Create a step to download and extract PDFium
    const pdfium_dir = b.cache_root.path orelse ".";
    const pdfium_path = b.pathJoin(&.{ pdfium_dir, "pdfium" });

    const download_pdfium = b.addSystemCommand(&.{
        "sh", "-c",
        b.fmt(
            \\set -e; \
            \\if [ ! -d "{0s}" ]; then \
            \\  mkdir -p "{0s}"; \
            \\  curl -sL "{1s}" | tar xz -C "{0s}"; \
            \\fi
        , .{ pdfium_path, pdfium_url }),
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

    // Add PDFium include and library paths
    exe_mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ pdfium_path, "include" }) });
    exe_mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ pdfium_path, "lib" }) });

    // Add rpath for runtime library loading on Unix systems
    if (target.result.os.tag == .macos) {
        // Use @executable_path so the library is found next to the executable
        exe_mod.addRPath(.{ .cwd_relative = "@executable_path" });
    } else if (target.result.os.tag == .linux) {
        exe_mod.addRPath(.{ .cwd_relative = "$ORIGIN" });
    }

    if (target.result.os.tag == .windows) {
        exe_mod.linkSystemLibrary("pdfium.dll", .{});
    } else {
        exe_mod.linkSystemLibrary("pdfium", .{});
    }

    // Link libc for PDFium C API
    exe_mod.link_libc = true;

    // Build the executable
    const exe = b.addExecutable(.{
        .name = "pdfzig",
        .root_module = exe_mod,
    });

    // Make exe depend on download step
    exe.step.dependOn(&download_pdfium.step);

    b.installArtifact(exe);

    // Install license files
    b.installFile("LICENSE", "LICENSE");
    b.installFile("THIRD_PARTY_NOTICES.md", "THIRD_PARTY_NOTICES.md");

    // Install the PDFium library to the bin directory (alongside the executable)
    const install_pdfium_lib = b.addInstallFileWithDir(
        .{ .cwd_relative = b.pathJoin(&.{ pdfium_path, "lib", getPdfiumLibName(target) }) },
        .bin,
        getPdfiumLibName(target),
    );
    install_pdfium_lib.step.dependOn(&download_pdfium.step);
    b.getInstallStep().dependOn(&install_pdfium_lib.step);

    // On macOS, fix the library's install name so it can be found via rpath
    if (target.result.os.tag == .macos) {
        const fix_lib_id = b.addSystemCommand(&.{
            "install_name_tool", "-id", "@rpath/libpdfium.dylib",
            b.pathJoin(&.{ pdfium_path, "lib", "libpdfium.dylib" }),
        });
        fix_lib_id.step.dependOn(&download_pdfium.step);
        // Make sure library is fixed before compilation starts
        exe.step.dependOn(&fix_lib_id.step);
    }

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
    test_mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ pdfium_path, "include" }) });
    test_mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ pdfium_path, "lib" }) });

    if (target.result.os.tag == .macos) {
        test_mod.addRPath(.{ .cwd_relative = "@executable_path" });
    } else if (target.result.os.tag == .linux) {
        test_mod.addRPath(.{ .cwd_relative = "$ORIGIN" });
    }

    if (target.result.os.tag == .windows) {
        test_mod.linkSystemLibrary("pdfium.dll", .{});
    } else {
        test_mod.linkSystemLibrary("pdfium", .{});
    }
    test_mod.link_libc = true;

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    unit_tests.step.dependOn(&download_pdfium.step);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

fn getPdfiumAssetName(target: std.Build.ResolvedTarget) ?[]const u8 {
    const arch = target.result.cpu.arch;
    const os = target.result.os.tag;

    return switch (os) {
        .macos => switch (arch) {
            .aarch64 => "pdfium-mac-arm64.tgz",
            .x86_64 => "pdfium-mac-x64.tgz",
            else => null,
        },
        .linux => switch (arch) {
            .aarch64 => "pdfium-linux-arm64.tgz",
            .x86_64 => "pdfium-linux-x64.tgz",
            .arm => "pdfium-linux-arm.tgz",
            else => null,
        },
        .windows => switch (arch) {
            .aarch64 => "pdfium-win-arm64.tgz",
            .x86_64 => "pdfium-win-x64.tgz",
            .x86 => "pdfium-win-x86.tgz",
            else => null,
        },
        else => null,
    };
}

fn getPdfiumLibName(target: std.Build.ResolvedTarget) []const u8 {
    return switch (target.result.os.tag) {
        .macos => "libpdfium.dylib",
        .linux => "libpdfium.so",
        .windows => "pdfium.dll",
        else => "libpdfium.so",
    };
}
