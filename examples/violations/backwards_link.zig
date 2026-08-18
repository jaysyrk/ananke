//! MUST NOT COMPILE: a datastore reaches back out to the DMZ.
//!
//! Connections flow inward. A restricted service calling out to a frontend is
//! how a compromised database becomes a compromised network.

const ananke = @import("ananke");

const topology: ananke.Topology = .{
    .name = "backwards",
    .source = "examples/violations/backwards_link.zig",
    .services = &.{
        .{ .name = "web", .zone = .dmz, .ports = &.{
            .{ .name = "http", .number = 8080, .proto = .http },
        } },
        .{ .name = "db", .zone = .restricted, .ports = &.{
            .{ .name = "sql", .number = 5432, .proto = .postgres },
        } },
    },
    .links = &.{
        .{ .from = "db", .to = "web", .port = "http", .note = "webhook callback, allegedly" },
    },
};

test {
    _ = ananke.Plan(topology, .{});
}
