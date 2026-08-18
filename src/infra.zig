//! The topology this repository's demo binary is built from.
//!
//! This file is the single source of truth for the example stack. There is no
//! docker-compose.yaml in the repository to keep in sync with it, because the
//! compose file is generated from this and overwritten on every build.
//!
//! Try breaking it. Point `web` straight at `db`, give two services the same
//! host port, put a literal password in an env var -- the build stops and
//! tells you exactly which line to look at.

const ananke = @import("ananke");

pub const topology: ananke.Topology = .{
    .name = "ananke-demo",
    .source = "src/infra.zig",
    .services = &.{
        .{
            .name = "edge",
            .zone = .public,
            .image = "nginx:1.27-alpine",
            .note = "TLS termination and the only thing the internet can reach",
            .ports = &.{
                .{ .name = "https", .number = 443, .proto = .https, .expose = .public },
            },
            .health = .{ .port = "https", .path = "/healthz" },
            .env = &.{
                ananke.Env.literal("NGINX_ENTRYPOINT_QUIET_LOGS", "1"),
            },
        },
        .{
            .name = "gateway",
            .zone = .dmz,
            .note = "request routing, auth, rate limiting",
            .ports = &.{
                .{ .name = "http", .number = 8080, .proto = .http },
                .{ .name = "metrics", .number = 9100, .proto = .http, .expose = .host },
            },
            .health = .{ .port = "http", .path = "/healthz", .interval_s = 5, .timeout_s = 2 },
            .env = &.{
                ananke.Env.literal("LOG_LEVEL", "info"),
                ananke.Env.secret("SESSION_SIGNING_SECRET", "GATEWAY_SESSION_SECRET"),
            },
        },
        .{
            .name = "api",
            .zone = .internal,
            .replicas = 3,
            .note = "stateless; scaled horizontally, so it publishes nothing",
            .ports = &.{
                .{ .name = "http", .number = 8081, .proto = .http },
            },
            .health = .{ .port = "http", .path = "/healthz" },
            .env = &.{
                ananke.Env.literal("LOG_LEVEL", "info"),
                ananke.Env.secret("DATABASE_PASSWORD", "POSTGRES_PASSWORD"),
            },
        },
        .{
            .name = "worker",
            .zone = .internal,
            .replicas = 2,
            .note = "consumes the queue; nothing dials it, so it has no ports",
        },
        .{
            .name = "db",
            .zone = .restricted,
            .image = "postgres:16-alpine",
            .ports = &.{
                .{ .name = "sql", .number = 5432, .proto = .postgres },
            },
            .health = .{ .port = "sql", .interval_s = 10, .timeout_s = 3 },
            .env = &.{
                ananke.Env.secret("POSTGRES_PASSWORD", "POSTGRES_PASSWORD"),
            },
        },
        .{
            .name = "cache",
            .zone = .restricted,
            .image = "redis:7-alpine",
            .ports = &.{
                .{ .name = "redis", .number = 6379, .proto = .redis },
            },
        },
        .{
            .name = "queue",
            .zone = .restricted,
            .image = "rabbitmq:3-alpine",
            .ports = &.{
                .{ .name = "amqp", .number = 5672, .proto = .amqp },
            },
        },
    },
    .links = &.{
        .{ .from = "edge", .to = "gateway", .port = "http", .note = "everything the public sees" },
        .{ .from = "gateway", .to = "api", .port = "http", .note = "authenticated requests" },
        .{ .from = "api", .to = "db", .port = "sql" },
        .{ .from = "api", .to = "cache", .port = "redis" },
        .{ .from = "api", .to = "queue", .port = "amqp", .note = "enqueues background jobs" },
        .{ .from = "worker", .to = "db", .port = "sql" },
        .{ .from = "worker", .to = "queue", .port = "amqp", .note = "consumes background jobs" },
        // There is deliberately no `gateway -> db` link. Adding one is a
        // compile error: the DMZ is two trust tiers away from the datastores.
    },
};

/// Verification happens here, while this declaration's type is constructed.
/// Nothing below this line in the program can run unless it succeeded.
pub const plan = ananke.Plan(topology, .{});
