const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const firmware_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("main/main.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const run_firmware_tests = b.addRunArtifact(firmware_tests);
    const test_step = b.step("test", "Run firmware unit tests");
    test_step.dependOn(&run_firmware_tests.step);

    const target = b.resolveTargetQuery(.{
        .cpu_arch = .xtensa,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_model = .{ .explicit = &std.Target.xtensa.cpu.esp32 },
    });
    const application = b.addObject(.{
        .name = "radar_zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const install_application = b.addInstallArtifact(application, .{
        .dest_dir = .{ .override = .prefix },
        .dest_sub_path = "radar_zig.o",
    });
    b.getInstallStep().dependOn(&install_application.step);
}
