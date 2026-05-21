const std = @import("std");

/// Resolve a list of pkg-config packages to their include/library directories
/// and linker flags. Falls back to system defaults if pkg-config is unavailable.
const PkgInfo = struct {
    include_paths: std.ArrayList([]const u8),
    library_paths: std.ArrayList([]const u8),
    libs: std.ArrayList([]const u8),

    fn init(allocator: std.mem.Allocator) PkgInfo {
        return .{
            .include_paths = std.ArrayList([]const u8).init(allocator),
            .library_paths = std.ArrayList([]const u8).init(allocator),
            .libs = std.ArrayList([]const u8).init(allocator),
        };
    }
};

fn runPkgConfig(b: *std.Build, args: []const []const u8) ?[]const u8 {
    var argv = std.ArrayList([]const u8).init(b.allocator);
    defer argv.deinit();
    argv.append("pkg-config") catch return null;
    argv.appendSlice(args) catch return null;

    const result = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = argv.items,
    }) catch return null;

    if (result.term != .Exited or result.term.Exited != 0) {
        return null;
    }
    return std.mem.trim(u8, result.stdout, " \r\n\t");
}

fn collectPkgInfo(b: *std.Build, packages: []const []const u8) PkgInfo {
    var info = PkgInfo.init(b.allocator);

    for (packages) |pkg| {
        if (runPkgConfig(b, &.{ "--cflags-only-I", pkg })) |out| {
            var it = std.mem.tokenizeAny(u8, out, " \t");
            while (it.next()) |tok| {
                if (std.mem.startsWith(u8, tok, "-I")) {
                    const path = b.dupe(tok[2..]);
                    info.include_paths.append(path) catch {};
                }
            }
        }
        if (runPkgConfig(b, &.{ "--libs-only-L", pkg })) |out| {
            var it = std.mem.tokenizeAny(u8, out, " \t");
            while (it.next()) |tok| {
                if (std.mem.startsWith(u8, tok, "-L")) {
                    const path = b.dupe(tok[2..]);
                    info.library_paths.append(path) catch {};
                }
            }
        }
        if (runPkgConfig(b, &.{ "--libs-only-l", pkg })) |out| {
            var it = std.mem.tokenizeAny(u8, out, " \t");
            while (it.next()) |tok| {
                if (std.mem.startsWith(u8, tok, "-l")) {
                    const name = b.dupe(tok[2..]);
                    info.libs.append(name) catch {};
                }
            }
        }
    }

    return info;
}

fn addLibs(b: *std.Build, step: *std.Build.Step.Compile) void {
    // Try pkg-config first; this works on Replit (nix), Ubuntu, NixOS, etc.
    const info = collectPkgInfo(b, &.{ "libpq", "hiredis", "openssl", "zlib" });

    for (info.include_paths.items) |p| {
        step.addIncludePath(.{ .cwd_relative = p });
    }
    for (info.library_paths.items) |p| {
        step.addLibraryPath(.{ .cwd_relative = p });
    }

    // Common system locations as a fallback (Ubuntu / Debian).
    const fallback_includes = [_][]const u8{
        "/usr/include/postgresql",
        "/usr/include/hiredis",
    };
    for (fallback_includes) |p| {
        std.fs.cwd().access(p, .{}) catch continue;
        step.addIncludePath(.{ .cwd_relative = p });
    }

    step.linkLibC();

    const linked_libs = [_][]const u8{ "pq", "hiredis", "ssl", "crypto", "z" };
    for (linked_libs) |lib| {
        step.linkSystemLibrary(lib);
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption([]const u8, "version", "0.1.0");
    options.addOption([]const u8, "build_time", "2025-05-11");

    const exe = b.addExecutable(.{
        .name = "search-platform",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addOptions("build_options", options);
    addLibs(b, exe);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the search platform");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run all tests");
    // Single aggregating test root so that tests/ and src/ live in the same
    // module — required by Zig 0.14 for the relative `@import("../src/...")`
    // paths used by individual test files.
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("test_root.zig"),
        .target = target,
        .optimize = .Debug,
    });
    unit_tests.root_module.addOptions("build_options", options);
    addLibs(b, unit_tests);
    const run_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_tests.step);
}
