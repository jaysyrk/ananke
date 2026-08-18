//! MUST NOT COMPILE: the topology is fine, but the *code* opens a connection
//! the topology never permitted.
//!
//! This is the half that config-file linters cannot reach. The link graph is
//! not documentation about what the program does; it is the only way the
//! program can obtain an address to dial.

const ananke = @import("ananke");

const topology: ananke.Topology = .{
    .name = "unlinked",
    .source = "examples/violations/unlinked_dial.zig",
    .services = &.{
        .{ .name = "gateway", .zone = .dmz, .ports = &.{
            .{ .name = "http", .number = 8080, .proto = .http },
        } },
        .{ .name = "api", .zone = .internal, .ports = &.{
            .{ .name = "http", .number = 8081, .proto = .http },
        } },
        .{ .name = "db", .zone = .restricted, .ports = &.{
            .{ .name = "sql", .number = 5432, .proto = .postgres },
        } },
    },
    .links = &.{
        .{ .from = "gateway", .to = "api", .port = "http" },
        .{ .from = "api", .to = "db", .port = "sql" },
    },
};

const plan = ananke.Plan(topology, .{});

test {
    // The gateway has no link to the database. Asking for the address is the
    // error; there is no way to get one without a link.
    _ = plan.endpoint("gateway", "db", "sql");
}
