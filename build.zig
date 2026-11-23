const std = @import("std");

const version = "0.2.0";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const use_scenefx = b.option(bool, "scenefx", "Build with SceneFX effects (blur, shadows, rounded corners)") orelse true;

    const build_options = b.addOptions();
    build_options.addOption(bool, "scenefx", use_scenefx);
    build_options.addOption([]const u8, "version", version);

    const ipc_protocol = b.createModule(.{
        .root_source_file = b.path("src/ipc/protocol.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addOptions("build_options", build_options);
    mod.addImport("ipc_protocol", ipc_protocol);
    configureWlroots(b, mod, use_scenefx);

    // Zig 0.15's bundled linker cannot process the SFrame relocations emitted
    // by GCC 16's crt1.o, so compile Zig to an object and let the system C
    // driver perform the final link. This also makes the build use the exact
    // same libc and dynamic loader as the host.
    const kairo_obj = b.addObject(.{
        .name = "kairo",
        .root_module = mod,
    });
    kairo_obj.bundle_compiler_rt = true;

    const link_cmd = b.addSystemCommand(&.{ "cc", "-o" });
    const linked = link_cmd.addOutputFileArg("kairo");
    link_cmd.addFileArg(kairo_obj.getEmittedBin());
    if (use_scenefx) link_cmd.addArg("-lscenefx-0.5");
    link_cmd.addArgs(&.{
        "-lwlroots-0.20",
        "-lwayland-server",
        "-lxkbcommon",
        "-lpixman-1",
        "-linput",
        "-lm",
        "-ldl",
        "-lpthread",
    });
    const install_kairo = b.addInstallFileWithDir(linked, .bin, "kairo");
    b.getInstallStep().dependOn(&install_kairo.step);

    const run_cmd = b.addSystemCommand(&.{"zig-out/bin/kairo"});
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run Kairo");
    run_step.dependOn(&run_cmd.step);

    const ctl_mod = b.createModule(.{
        .root_source_file = b.path("cmd/kairoctl.zig"),
        .target = target,
        .optimize = optimize,
    });
    ctl_mod.addImport("ipc_protocol", ipc_protocol);
    ctl_mod.addOptions("build_options", build_options);
    const ctl = b.addExecutable(.{
        .name = "kairoctl",
        .root_module = ctl_mod,
    });
    b.installArtifact(ctl);

    const ctl_step = b.step("kairoctl", "Build kairoctl only");
    ctl_step.dependOn(&ctl.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

fn configureWlroots(b: *std.Build, mod: *std.Build.Module, use_scenefx: bool) void {
    mod.addCMacro("WLR_USE_UNSTABLE", "1");
    mod.addCMacro("_GNU_SOURCE", "1");
    // wlroots headers are installed outside the compiler's default search path
    // on most distributions (e.g. /usr/include/wlroots-0.20). pkg-config
    // supplies the correct paths for the installed wlroots/SceneFX versions.
    mod.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
    mod.addSystemIncludePath(.{ .cwd_relative = "/usr/local/include" });
    mod.addIncludePath(b.path("protocols/generated"));

    if (use_scenefx) {
        // SceneFX must be linked before wlroots: it provides the extended
        // scene graph implementation and overrides the base symbols.
        mod.linkSystemLibrary("scenefx-0.5", .{ .needed = true });
    }
    mod.linkSystemLibrary("wlroots-0.20", .{ .needed = true });
    mod.linkSystemLibrary("wayland-server", .{ .needed = true });
    mod.linkSystemLibrary("xkbcommon", .{ .needed = true });
    mod.linkSystemLibrary("pixman-1", .{ .needed = true });
    mod.linkSystemLibrary("input", .{ .needed = true });
    mod.linkSystemLibrary("m", .{});
}
