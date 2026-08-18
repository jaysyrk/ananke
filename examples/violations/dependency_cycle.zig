//! MUST NOT COMPILE: three services wait for each other forever.

const ananke = @import("ananke");

const port = ananke.Port{ .name = "http", .number = 8080, .proto = .http };

const topology: ananke.Topology = .{
    .name = "deadlock",
    .source = "examples/violations/dependency_cycle.zig",
    .services = &.{
        .{ .name = "alpha", .zone = .internal, .ports = &.{port} },
        .{ .name = "beta", .zone = .internal, .ports = &.{port} },
        .{ .name = "gamma", .zone = .internal, .ports = &.{port} },
    },
    .links = &.{
        .{ .from = "alpha", .to = "beta", .port = "http" },
        .{ .from = "beta", .to = "gamma", .port = "http" },
        .{ .from = "gamma", .to = "alpha", .port = "http" },
    },
};

test {
    _ = ananke.Plan(topology, .{});
}
