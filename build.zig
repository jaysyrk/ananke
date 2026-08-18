const std = @import("std");

/// Files that must NOT compile, and the phrase each one's error must contain.
///
/// A checker whose failures are untested is a checker that quietly stops
/// failing. `zig build test` compiles each of these and asserts the build
/// breaks for the stated reason.
const violations = [_]Violation{
    .{ .path = "examples/violations/port_collision.zig", .expect = "both publish port 8080; only one of them would ever bind" },
    .{ .path = "examples/violations/zone_jump.zig", .expect = "connection crosses 2 trust tiers in one hop" },
    .{ .path = "examples/violations/backwards_link.zig", .expect = "connection flows outward, from a more trusted tier to a less trusted one" },
    .{ .path = "examples/violations/dangling_link.zig", .expect = "'db' has no port named 'sql'" },
    .{ .path = "examples/violations/plaintext_secret.zig", .expect = "a credential-shaped variable holds a literal value" },
    .{ .path = "examples/violations/plaintext_edge.zig", .expect = "port 8080 is public but speaks plaintext http" },
    .{ .path = "examples/violations/replica_host_port.zig", .expect = "4 replicas cannot all bind host port 8080" },
    .{ .path = "examples/violations/published_datastore.zig", .expect = "a restricted-tier service publishes port 5432 as 'host'" },
    .{ .path = "examples/violations/dependency_cycle.zig", .expect = "these services form a dependency cycle, so no start order exists" },
    .{ .path = "examples/violations/bad_service_name.zig", .expect = "not a valid DNS label" },
    .{ .path = "examples/violations/privileged_port.zig", .expect = "port 80 is privileged but only exposed as 'cluster'" },
    .{ .path = "examples/violations/unlinked_dial.zig", .expect = "so it is not allowed to connect there." },
};

const Violation = struct {
    path: []const u8,
    expect: []const u8,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("ananke", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "ananke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "ananke", .module = mod }},
        }),
    });
    b.installArtifact(exe);

    // zig build run -- [args]
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the demo binary").dependOn(&run_cmd.step);

    // zig build emit -- write the generated config into generated/
    const emit_cmd = b.addRunArtifact(exe);
    emit_cmd.addArgs(&.{ "emit", "generated" });
    emit_cmd.setCwd(b.path("."));
    emit_cmd.has_side_effects = true;
    b.step("emit", "Write the generated config to generated/").dependOn(&emit_cmd.step);

    // zig build test
    const test_step = b.step("test", "Run unit tests and the must-not-compile suite");

    const mod_tests = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    // zig build violations -- the negative half of the test suite
    const violations_step = b.step(
        "violations",
        "Check that every examples/violations/*.zig file refuses to compile",
    );
    for (violations) |v| {
        const case = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(v.path),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "ananke", .module = mod }},
            }),
        });
        case.expect_errors = .{ .contains = v.expect };
        violations_step.dependOn(&case.step);
    }
    test_step.dependOn(violations_step);
}
