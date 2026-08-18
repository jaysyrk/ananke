//! MUST NOT COMPILE: a service name that cannot be a hostname.
//!
//! It would have generated a compose file that fails to parse, several minutes
//! and one context switch later.

const ananke = @import("ananke");

const topology: ananke.Topology = .{
    .name = "naming",
    .source = "examples/violations/bad_service_name.zig",
    .services = &.{
        .{ .name = "Auth Service", .zone = .internal, .ports = &.{
            .{ .name = "http", .number = 8080, .proto = .http },
        } },
    },
};

test {
    _ = ananke.Plan(topology, .{});
}
