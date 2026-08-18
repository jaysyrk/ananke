//! MUST NOT COMPILE: the database is published on the host.
//!
//! Someone needed to run a migration from their laptop once.

const ananke = @import("ananke");

const topology: ananke.Topology = .{
    .name = "exposed",
    .source = "examples/violations/published_datastore.zig",
    .services = &.{
        .{ .name = "db", .zone = .restricted, .ports = &.{
            .{ .name = "sql", .number = 5432, .proto = .postgres, .expose = .host },
        } },
    },
};

test {
    _ = ananke.Plan(topology, .{});
}
