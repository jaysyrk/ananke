//! MUST NOT COMPILE: an internet-facing port speaks plain HTTP.

const ananke = @import("ananke");

const topology: ananke.Topology = .{
    .name = "cleartext",
    .source = "examples/violations/plaintext_edge.zig",
    .services = &.{
        .{ .name = "edge", .zone = .public, .ports = &.{
            .{ .name = "http", .number = 8080, .proto = .http, .expose = .public },
        } },
    },
};

test {
    _ = ananke.Plan(topology, .{});
}
