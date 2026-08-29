const std = @import("std");

fn environment(b: *std.Build, name: []const u8) []const u8 {
    b.graph.poisonCache();
    return b.graph.environ_map.get(name) orelse "";
}

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const server_port_text = environment(b, "ESP_SERVER_PORT");
    const server_port = std.fmt.parseInt(u16, server_port_text, 10) catch 0;
    const firmware_options = b.addOptions();
    firmware_options.addOption([]const u8, "network_name", environment(b, "ESP_NETWORK_NAME"));
    firmware_options.addOption([]const u8, "network_secret", environment(b, "ESP_NETWORK_SECRET"));
    firmware_options.addOption([]const u8, "server_host", environment(b, "ESP_SERVER_HOST"));
    firmware_options.addOption(u16, "server_port", server_port);

    const test_module = b.createModule(.{
        .root_source_file = b.path("main/main.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    test_module.addOptions("firmware_options", firmware_options);
    const firmware_tests = b.addTest(.{ .root_module = test_module });
    const run_firmware_tests = b.addRunArtifact(firmware_tests);
    const test_step = b.step("test", "Run firmware unit tests");
    test_step.dependOn(&run_firmware_tests.step);

    const target = b.resolveTargetQuery(.{
        .cpu_arch = .xtensa,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_model = .{ .explicit = &std.Target.xtensa.cpu.esp32 },
    });
    const application_module = b.createModule(.{
        .root_source_file = b.path("main/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    application_module.addOptions("firmware_options", firmware_options);
    const application = b.addObject(.{
        .name = "radar_zig",
        .root_module = application_module,
    });
    const install_application = b.addInstallArtifact(application, .{
        .dest_dir = .{ .override = .prefix },
        .dest_sub_path = "radar_zig.o",
    });
    b.getInstallStep().dependOn(&install_application.step);
}
