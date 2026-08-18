//! MUST NOT COMPILE: two services publish the same host port.
//!
//! The kind of mistake that survives code review, survives CI, and is found
//! by whichever container loses the race at 3am.

const ananke = @import("ananke");

const topology: ananke.Topology = .{
    .name = "collision",
    .source = "examples/violations/port_collision.zig",
    .services = &.{
        .{ .name = "web", .zone = .dmz, .ports = &.{
            .{ .name = "http", .number = 8080, .proto = .http, .expose = .host },
        } },
        .{ .name = "admin", .zone = .dmz, .ports = &.{
            .{ .name = "http", .number = 8080, .proto = .http, .expose = .host },
        } },
    },
};

test {
    _ = ananke.Plan(topology, .{});
}
