const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zirkon",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const no_llvm = b.option(bool, "no-llvm", "Don't use LLVM backend to build the project") orelse false;
    exe.use_llvm = !no_llvm;

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_source_file = .{ .path = "src/Autodoc.zig" },
        .target = target,
        .optimize = optimize,
    });
    tests.addAnonymousModule("zig", .{
        .source_file = .{ .cwd_relative = "../zig/src/Autodoc.zig" },
    });
    const tests_run = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&tests_run.step);
}
