//! MUST NOT COMPILE: a link names a port that was renamed away.
//!
//! Renaming a port in one place and forgetting the other is a class of bug
//! that config files cannot detect and this can.

const ananke = @import("ananke");

const topology: ananke.Topology = .{
    .name = "dangling",
    .source = "examples/violations/dangling_link.zig",
    .services = &.{
        .{ .name = "api", .zone = .internal, .ports = &.{
            .{ .name = "http", .number = 8080, .proto = .http },
        } },
        .{
            .name = "db",
            .zone = .restricted,
            .ports = &.{
                // Renamed from "sql" to "postgres" -- the link below never noticed.
                .{ .name = "postgres", .number = 5432, .proto = .postgres },
            },
        },
    },
    .links = &.{
        .{ .from = "api", .to = "db", .port = "sql" },
    },
};

test {
    _ = ananke.Plan(topology, .{});
}
