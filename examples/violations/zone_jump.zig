//! MUST NOT COMPILE: the frontend dials the database directly.
//!
//! Zero-trust as a compile error. There is no code review to skip and no
//! runbook to ignore; the link does not survive the build.

const ananke = @import("ananke");

const topology: ananke.Topology = .{
    .name = "zone-jump",
    .source = "examples/violations/zone_jump.zig",
    .services = &.{
        .{ .name = "web", .zone = .dmz, .ports = &.{
            .{ .name = "http", .number = 8080, .proto = .http },
        } },
        .{ .name = "db", .zone = .restricted, .ports = &.{
            .{ .name = "sql", .number = 5432, .proto = .postgres },
        } },
    },
    .links = &.{
        .{ .from = "web", .to = "db", .port = "sql" },
    },
};

test {
    _ = ananke.Plan(topology, .{});
}
