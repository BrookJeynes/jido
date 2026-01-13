const std = @import("std");
const builtin = @import("builtin");

///Must match the `version` in `build.zig.zon`.
const version = std.SemanticVersion{ .major = 1, .minor = 4, .patch = 0 };

const targets: []const std.Target.Query = &.{
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .aarch64, .os_tag = .linux },
    .{ .cpu_arch = .x86_64, .os_tag = .linux },
    .{ .cpu_arch = .x86_64, .os_tag = .macos },
};

fn createExe(
    b: *std.Build,
    exe_name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    build_options: *std.Build.Module,
) !*std.Build.Step.Compile {
    const libvaxis = b.dependency("vaxis", .{ .target = target, .optimize = optimize }).module("vaxis");
    const fuzzig = b.dependency("fuzzig", .{ .target = target, .optimize = optimize }).module("fuzzig");
    const zeit = b.dependency("zeit", .{ .target = target, .optimize = optimize }).module("zeit");
    const zuid = b.dependency("zuid", .{ .target = target, .optimize = optimize }).module("zuid");

    const exe = b.addExecutable(.{
        .name = exe_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addImport("options", build_options);
    exe.root_module.addImport("vaxis", libvaxis);
    exe.root_module.addImport("fuzzig", fuzzig);
    exe.root_module.addImport("zeit", zeit);
    exe.root_module.addImport("zuid", zuid);

    return exe;
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_options = b.addOptions();
    build_options.step.name = "build options";
    build_options.addOption(std.SemanticVersion, "version", version);
    const build_options_module = build_options.createModule();

    const build_all = b.option(bool, "all-targets", "Build all targets in ReleaseSafe mode.") orelse false;
    if (build_all) {
        try buildTargets(b, build_options_module);
        return;
    }

    const exe = try createExe(b, "jido", target, optimize, build_options_module);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const libvaxis = b.dependency("vaxis", .{ .target = target, .optimize = optimize }).module("vaxis");
    const fuzzig = b.dependency("fuzzig", .{ .target = target, .optimize = optimize }).module("fuzzig");
    const zuid = b.dependency("zuid", .{ .target = target, .optimize = optimize }).module("zuid");
    const zeit = b.dependency("zeit", .{ .target = target, .optimize = optimize }).module("zeit");
    const test_step = b.step("test", "Run unit tests");
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    unit_tests.root_module.addImport("options", build_options_module);
    unit_tests.root_module.addImport("vaxis", libvaxis);
    unit_tests.root_module.addImport("fuzzig", fuzzig);
    unit_tests.root_module.addImport("zeit", zeit);
    unit_tests.root_module.addImport("zuid", zuid);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    const integration_tests = &[_][]const u8{
        "src/test_navigation.zig",
        "src/test_file_operations.zig",
    };

    for (integration_tests) |test_file| {
        const test_exe = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(test_file),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_exe.root_module.addImport("vaxis", libvaxis);
        test_exe.root_module.addImport("fuzzig", fuzzig);
        test_exe.root_module.addImport("zuid", zuid);
        test_exe.root_module.addImport("zeit", zeit);
        test_exe.root_module.addImport("options", build_options_module);

        const run_test = b.addRunArtifact(test_exe);
        test_step.dependOn(&run_test.step);
    }
}

fn buildTargets(b: *std.Build, build_options: *std.Build.Module) !void {
    for (targets) |t| {
        const target = b.resolveTargetQuery(t);

        const exe = try createExe(b, "jido", target, .ReleaseSafe, build_options);
        b.installArtifact(exe);

        const target_output = b.addInstallArtifact(exe, .{
            .dest_dir = .{
                .override = .{
                    .custom = try t.zigTriple(b.allocator),
                },
            },
        });

        b.getInstallStep().dependOn(&target_output.step);
    }
}
