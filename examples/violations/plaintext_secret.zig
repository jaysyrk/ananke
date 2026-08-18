//! MUST NOT COMPILE: a password is written into the source that generates the
//! deployment config, and therefore into the repository.

const ananke = @import("ananke");

const topology: ananke.Topology = .{
    .name = "leaky",
    .source = "examples/violations/plaintext_secret.zig",
    .services = &.{
        .{
            .name = "api",
            .zone = .internal,
            .ports = &.{.{ .name = "http", .number = 8080, .proto = .http }},
            .env = &.{
                ananke.Env.literal("DATABASE_PASSWORD", "hunter2"),
            },
        },
    },
};

test {
    _ = ananke.Plan(topology, .{});
}
