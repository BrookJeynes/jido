const std = @import("std");
const builtin = @import("builtin");

const targets: []const std.Target.Query = &.{
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .aarch64, .os_tag = .linux },
    .{ .cpu_arch = .x86_64, .os_tag = .linux },
    .{ .cpu_arch = .x86_64, .os_tag = .macos },
};

fn createExe(b: *std.Build, exe_name: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) !*std.Build.Step.Compile {
    const libvaxis = b.dependency("vaxis", .{ .target = target }).module("vaxis");
    const fuzzig = b.dependency("fuzzig", .{ .target = target }).module("fuzzig");
    const zuid = b.dependency("zuid", .{ .target = target }).module("zuid");
    const zeit = b.dependency("zeit", .{ .target = target }).module("zeit");

    const exe = b.addExecutable(.{
        .name = exe_name,
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("vaxis", libvaxis);
    exe.root_module.addImport("fuzzig", fuzzig);
    exe.root_module.addImport("zuid", zuid);
    exe.root_module.addImport("zeit", zeit);

    return exe;
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Building targets for release.
    const build_all = b.option(bool, "all-targets", "Build all targets in ReleaseSafe mode.") orelse false;
    if (build_all) {
        try buildTargets(b);
        return;
    }

    const exe = try createExe(b, "jido", target, optimize);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}

fn buildTargets(b: *std.Build) !void {
    for (targets) |t| {
        const target = b.resolveTargetQuery(t);

        const exe = try createExe(b, "jido", target, .ReleaseSafe);
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
