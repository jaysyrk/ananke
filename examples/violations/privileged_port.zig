//! MUST NOT COMPILE: an application container asks for port 80.
//!
//! Which means asking to run as root, which is a decision worth making on
//! purpose rather than by default.

const ananke = @import("ananke");

const topology: ananke.Topology = .{
    .name = "privileged",
    .source = "examples/violations/privileged_port.zig",
    .services = &.{
        .{ .name = "api", .zone = .internal, .ports = &.{
            .{ .name = "http", .number = 80, .proto = .http },
        } },
    },
};

test {
    _ = ananke.Plan(topology, .{});
}
