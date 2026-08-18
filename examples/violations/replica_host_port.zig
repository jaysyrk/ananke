//! MUST NOT COMPILE: four replicas, one host port.
//!
//! Works perfectly at one replica, which is the only configuration anyone
//! tested.

const ananke = @import("ananke");

const topology: ananke.Topology = .{
    .name = "scaled",
    .source = "examples/violations/replica_host_port.zig",
    .services = &.{
        .{
            .name = "api",
            .zone = .internal,
            .replicas = 4,
            .ports = &.{
                .{ .name = "http", .number = 8080, .proto = .http, .expose = .host },
            },
        },
    },
};

test {
    _ = ananke.Plan(topology, .{});
}
