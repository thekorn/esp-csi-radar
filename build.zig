const std = @import("std");

fn environment(b: *std.Build, name: []const u8) []const u8 {
    b.graph.poisonCache();
    return b.graph.environ_map.get(name) orelse "";
}

fn instrumentCoverage(tests: *std.Build.Step.Compile, runtime_path: ?[]const u8) void {
    tests.use_llvm = true;
    tests.root_module.fuzz = true;
    tests.root_module.link_libc = true;
    if (runtime_path) |path| tests.root_module.addObjectFile(.{ .cwd_relative = path });
}

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const coverage = b.option(bool, "coverage", "Enable zig-cov") orelse false;
    const coverage_runtime = b.option([]const u8, "coverage-rt", "Path to zig-cov-rt.o") orelse null;
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
    const firmware_tests = b.addTest(.{
        .root_module = test_module,
        .test_runner = if (coverage) null else .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });
    if (coverage) instrumentCoverage(firmware_tests, coverage_runtime);
    const run_firmware_tests = b.addRunArtifact(firmware_tests);
    const test_step = b.step("test", "Run firmware and host unit tests");
    test_step.dependOn(&run_firmware_tests.step);

    const asset_files = b.addWriteFiles();
    const asset_root = asset_files.addCopyFile(b.path("host-zig/assets.zig"), "assets.zig");
    _ = asset_files.addCopyFile(b.path("web/index.html"), "web/index.html");
    _ = asset_files.addCopyFile(b.path("web/app.js"), "web/app.js");
    _ = asset_files.addCopyFile(b.path("web/styles.css"), "web/styles.css");
    const asset_module = b.createModule(.{
        .root_source_file = asset_root,
        .target = b.graph.host,
        .optimize = optimize,
    });

    const host_module = b.createModule(.{
        .root_source_file = b.path("host-zig/server.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    host_module.addImport("assets", asset_module);
    const host = b.addExecutable(.{
        .name = "esp-csi-radar-host",
        .root_module = host_module,
    });
    const install_host = b.addInstallArtifact(host, .{});
    const host_step = b.step("host", "Build and install the Zig host server");
    host_step.dependOn(&install_host.step);

    const run_host = b.addRunArtifact(host);
    run_host.addPassthruArgs();
    const run_host_step = b.step("run-host", "Run the Zig host server");
    run_host_step.dependOn(&run_host.step);

    const host_test_module = b.createModule(.{
        .root_source_file = b.path("host-zig/tests.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    host_test_module.addImport("assets", asset_module);
    const host_tests = b.addTest(.{
        .root_module = host_test_module,
        .test_runner = if (coverage) null else .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });
    if (coverage) instrumentCoverage(host_tests, coverage_runtime);
    const run_host_tests = b.addRunArtifact(host_tests);
    test_step.dependOn(&run_host_tests.step);

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
