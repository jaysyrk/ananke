//! Tests for the policies and the generators.
//!
//! Policies are exercised through `verify.audit`, which returns findings
//! instead of halting, so a passing check and a failing one can both be
//! asserted from inside a normal test. The other half of the suite lives in
//! `examples/violations/`, where the assertion is that the file does not
//! compile at all -- see `zig build violations`.

const std = @import("std");
const ananke = @import("root.zig");
const verify = @import("verify.zig");
const policies = @import("policies.zig");
const text = @import("emit/text.zig");

const Topology = ananke.Topology;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

/// Number of findings a single policy raises against a topology.
fn count(comptime t: Topology, comptime P: type) usize {
    return comptime verify.audit(t, &.{P}).len;
}

/// The first finding's message, for asserting on the wording.
fn firstMessage(comptime t: Topology, comptime P: type) []const u8 {
    const reports = comptime verify.audit(t, &.{P});
    return reports[0].finding.message;
}

const web: ananke.Service = .{
    .name = "web",
    .zone = .dmz,
    .ports = &.{.{ .name = "http", .number = 8080, .proto = .http }},
};
const api: ananke.Service = .{
    .name = "api",
    .zone = .internal,
    .ports = &.{.{ .name = "http", .number = 8081, .proto = .http }},
};
const db: ananke.Service = .{
    .name = "db",
    .zone = .restricted,
    .ports = &.{.{ .name = "sql", .number = 5432, .proto = .postgres }},
};

// --- service-names ---------------------------------------------------------

test "service-names accepts ordinary names" {
    const t: Topology = .{ .name = "t", .services = &.{ web, api } };
    try expectEqual(0, count(t, policies.ServiceNames));
}

test "service-names rejects duplicates and non-DNS labels" {
    const dup: Topology = .{ .name = "t", .services = &.{ web, web } };
    try expectEqual(1, count(dup, policies.ServiceNames));

    const shouty: Topology = .{ .name = "t", .services = &.{.{ .name = "Web_1", .zone = .dmz }} };
    try expectEqual(1, count(shouty, policies.ServiceNames));

    const trailing: Topology = .{ .name = "t", .services = &.{.{ .name = "web-", .zone = .dmz }} };
    try expectEqual(1, count(trailing, policies.ServiceNames));
}

// --- unique-ports ----------------------------------------------------------

test "unique-ports ignores collisions that stay inside the cluster" {
    // Two cluster-only services on 8080 are fine: they are on different hosts
    // as far as anything that matters is concerned.
    const t: Topology = .{ .name = "t", .services = &.{
        .{ .name = "a", .zone = .internal, .ports = &.{.{ .name = "http", .number = 8080, .proto = .http }} },
        .{ .name = "b", .zone = .internal, .ports = &.{.{ .name = "http", .number = 8080, .proto = .http }} },
    } };
    try expectEqual(0, count(t, policies.UniquePorts));
}

test "unique-ports catches two published services on one port" {
    const t: Topology = .{ .name = "t", .services = &.{
        .{ .name = "a", .zone = .dmz, .ports = &.{.{ .name = "http", .number = 8080, .proto = .http, .expose = .host }} },
        .{ .name = "b", .zone = .dmz, .ports = &.{.{ .name = "http", .number = 8080, .proto = .http, .expose = .host }} },
    } };
    try expectEqual(1, count(t, policies.UniquePorts));
}

test "unique-ports catches one service declaring a port twice" {
    const t: Topology = .{ .name = "t", .services = &.{.{
        .name = "a",
        .zone = .internal,
        .ports = &.{
            .{ .name = "http", .number = 8080, .proto = .http },
            .{ .name = "debug", .number = 8080, .proto = .http },
        },
    }} };
    try expectEqual(1, count(t, policies.UniquePorts));
}

// --- valid-links -----------------------------------------------------------

test "valid-links resolves a good link" {
    const t: Topology = .{
        .name = "t",
        .services = &.{ api, db },
        .links = &.{.{ .from = "api", .to = "db", .port = "sql" }},
    };
    try expectEqual(0, count(t, policies.ValidLinks));
}

test "valid-links catches a renamed port" {
    const t: Topology = .{
        .name = "t",
        .services = &.{ api, db },
        .links = &.{.{ .from = "api", .to = "db", .port = "postgres" }},
    };
    try expectEqual(1, count(t, policies.ValidLinks));
}

test "valid-links catches a missing service and a self-link" {
    const missing: Topology = .{
        .name = "t",
        .services = &.{api},
        .links = &.{.{ .from = "api", .to = "ghost", .port = "http" }},
    };
    try expectEqual(1, count(missing, policies.ValidLinks));

    const selfish: Topology = .{
        .name = "t",
        .services = &.{api},
        .links = &.{.{ .from = "api", .to = "api", .port = "http" }},
    };
    try expectEqual(1, count(selfish, policies.ValidLinks));
}

// --- zone-boundaries -------------------------------------------------------

test "zone-boundaries allows one tier inward" {
    const t: Topology = .{
        .name = "t",
        .services = &.{ web, api, db },
        .links = &.{
            .{ .from = "web", .to = "api", .port = "http" },
            .{ .from = "api", .to = "db", .port = "sql" },
        },
    };
    try expectEqual(0, count(t, policies.ZoneBoundaries));
}

test "zone-boundaries allows same-tier traffic" {
    const peer: ananke.Service = .{
        .name = "search",
        .zone = .internal,
        .ports = &.{.{ .name = "http", .number = 8082, .proto = .http }},
    };
    const t: Topology = .{
        .name = "t",
        .services = &.{ api, peer },
        .links = &.{.{ .from = "api", .to = "search", .port = "http" }},
    };
    try expectEqual(0, count(t, policies.ZoneBoundaries));
}

test "zone-boundaries rejects a two-tier jump" {
    const t: Topology = .{
        .name = "t",
        .services = &.{ web, db },
        .links = &.{.{ .from = "web", .to = "db", .port = "sql" }},
    };
    try expectEqual(1, count(t, policies.ZoneBoundaries));
    try expectEqualStrings(
        "connection crosses 2 trust tiers in one hop",
        firstMessage(t, policies.ZoneBoundaries),
    );
}

test "zone-boundaries rejects a link that flows outward" {
    const t: Topology = .{
        .name = "t",
        .services = &.{ api, db },
        .links = &.{.{ .from = "db", .to = "api", .port = "http" }},
    };
    try expectEqual(1, count(t, policies.ZoneBoundaries));
}

// --- the security policies -------------------------------------------------

test "no-published-datastores keeps the restricted tier off the host" {
    const t: Topology = .{ .name = "t", .services = &.{.{
        .name = "db",
        .zone = .restricted,
        .ports = &.{.{ .name = "sql", .number = 5432, .proto = .postgres, .expose = .host }},
    }} };
    try expectEqual(1, count(t, policies.NoPublishedDatastores));
    try expectEqual(0, count(.{ .name = "t", .services = &.{db} }, policies.NoPublishedDatastores));
}

test "encrypted-edges accepts https and tls, rejects bare http" {
    const bare: Topology = .{ .name = "t", .services = &.{.{
        .name = "edge",
        .zone = .public,
        .ports = &.{.{ .name = "http", .number = 8080, .proto = .http, .expose = .public }},
    }} };
    try expectEqual(1, count(bare, policies.EncryptedEdges));

    const wrapped: Topology = .{ .name = "t", .services = &.{.{
        .name = "edge",
        .zone = .public,
        .ports = &.{.{ .name = "http", .number = 8080, .proto = .http, .expose = .public, .tls = true }},
    }} };
    try expectEqual(0, count(wrapped, policies.EncryptedEdges));
}

test "privileged-ports allows the public edge and nothing else" {
    const edge: Topology = .{ .name = "t", .services = &.{.{
        .name = "edge",
        .zone = .public,
        .ports = &.{.{ .name = "https", .number = 443, .proto = .https, .expose = .public }},
    }} };
    try expectEqual(0, count(edge, policies.PrivilegedPorts));

    const app: Topology = .{ .name = "t", .services = &.{.{
        .name = "api",
        .zone = .internal,
        .ports = &.{.{ .name = "http", .number = 80, .proto = .http }},
    }} };
    try expectEqual(1, count(app, policies.PrivilegedPorts));
}

test "replica-sanity catches replicas fighting over a host port" {
    const t: Topology = .{ .name = "t", .services = &.{.{
        .name = "api",
        .zone = .internal,
        .replicas = 4,
        .ports = &.{.{ .name = "http", .number = 8080, .proto = .http, .expose = .host }},
    }} };
    try expectEqual(1, count(t, policies.ReplicaSanity));

    const none: Topology = .{ .name = "t", .services = &.{.{ .name = "api", .zone = .internal, .replicas = 0 }} };
    try expectEqual(1, count(none, policies.ReplicaSanity));
}

test "no-plaintext-secrets looks at the key, not the value" {
    const leaky: Topology = comptime .{ .name = "t", .services = &.{.{
        .name = "api",
        .zone = .internal,
        .env = &.{ananke.Env.literal("API_KEY", "abc123")},
    }} };
    try expectEqual(1, count(leaky, policies.NoPlaintextSecrets));

    const sealed: Topology = comptime .{ .name = "t", .services = &.{.{
        .name = "api",
        .zone = .internal,
        .env = &.{ananke.Env.secret("API_KEY", "UPSTREAM_API_KEY")},
    }} };
    try expectEqual(0, count(sealed, policies.NoPlaintextSecrets));

    // A public key is not a secret, and neither is a log level.
    const fine: Topology = comptime .{ .name = "t", .services = &.{.{
        .name = "api",
        .zone = .internal,
        .env = &.{
            ananke.Env.literal("JWT_PUBLIC_KEY", "-----BEGIN PUBLIC KEY-----"),
            ananke.Env.literal("LOG_LEVEL", "debug"),
        },
    }} };
    try expectEqual(0, count(fine, policies.NoPlaintextSecrets));
}

// --- graph shape -----------------------------------------------------------

test "no-dependency-cycles accepts a chain" {
    const t: Topology = .{
        .name = "t",
        .services = &.{ web, api, db },
        .links = &.{
            .{ .from = "web", .to = "api", .port = "http" },
            .{ .from = "api", .to = "db", .port = "sql" },
        },
    };
    try expectEqual(0, count(t, policies.NoDependencyCycles));
}

test "no-dependency-cycles accepts a diamond" {
    const t: Topology = .{
        .name = "t",
        .services = &.{
            .{ .name = "top", .zone = .internal, .ports = &.{.{ .name = "http", .number = 8080, .proto = .http }} },
            .{ .name = "left", .zone = .internal, .ports = &.{.{ .name = "http", .number = 8081, .proto = .http }} },
            .{ .name = "right", .zone = .internal, .ports = &.{.{ .name = "http", .number = 8082, .proto = .http }} },
            .{ .name = "bottom", .zone = .internal, .ports = &.{.{ .name = "http", .number = 8083, .proto = .http }} },
        },
        .links = &.{
            .{ .from = "top", .to = "left", .port = "http" },
            .{ .from = "top", .to = "right", .port = "http" },
            .{ .from = "left", .to = "bottom", .port = "http" },
            .{ .from = "right", .to = "bottom", .port = "http" },
        },
    };
    try expectEqual(0, count(t, policies.NoDependencyCycles));
}

test "no-dependency-cycles names everyone in the loop" {
    const t: Topology = .{
        .name = "t",
        .services = &.{
            .{ .name = "a", .zone = .internal, .ports = &.{.{ .name = "http", .number = 8080, .proto = .http }} },
            .{ .name = "b", .zone = .internal, .ports = &.{.{ .name = "http", .number = 8081, .proto = .http }} },
        },
        .links = &.{
            .{ .from = "a", .to = "b", .port = "http" },
            .{ .from = "b", .to = "a", .port = "http" },
        },
    };
    try expectEqual(1, count(t, policies.NoDependencyCycles));
    const reports = comptime verify.audit(t, &.{policies.NoDependencyCycles});
    try expectEqualStrings("a, b", reports[0].finding.subject);
}

// --- warnings --------------------------------------------------------------

test "warnings do not stop a build" {
    const t: Topology = .{ .name = "t", .services = &.{db} };
    const reports = comptime verify.audit(t, &.{policies.HealthChecks});
    try expectEqual(1, reports.len);
    try expectEqual(ananke.Severity.warn, reports[0].finding.severity);

    // A `Plan` exists despite the warning, and carries it into the binary.
    const plan = ananke.Plan(t, .{ .policies = &.{policies.HealthChecks} });
    try expectEqual(1, plan.warnings.len);
}

test "no-orphans notices a service nothing talks to" {
    const t: Topology = .{
        .name = "t",
        .services = &.{ api, db, .{ .name = "forgotten", .zone = .internal } },
        .links = &.{.{ .from = "api", .to = "db", .port = "sql" }},
    };
    // `api` and `db` are wired together; only `forgotten` is unreachable.
    try expectEqual(1, count(t, policies.NoOrphans));
    const reports = comptime verify.audit(t, &.{policies.NoOrphans});
    try expectEqualStrings("forgotten", reports[0].finding.subject);
}

// --- the generators --------------------------------------------------------

const demo: Topology = .{
    .name = "demo",
    .source = "test",
    .services = &.{
        .{
            .name = "edge",
            .zone = .public,
            .image = "nginx:1.27",
            .ports = &.{.{ .name = "https", .number = 443, .proto = .https, .expose = .public }},
            .health = .{ .port = "https" },
        },
        .{
            .name = "api",
            .zone = .internal,
            .ports = &.{.{ .name = "http", .number = 8081, .proto = .http }},
            .env = &.{ananke.Env.secret("DATABASE_PASSWORD", "PG_PASSWORD")},
            .health = .{ .port = "http" },
        },
        .{
            .name = "db",
            .zone = .restricted,
            .image = "postgres:16",
            .ports = &.{.{ .name = "sql", .number = 5432, .proto = .postgres }},
            .health = .{ .port = "sql" },
        },
    },
    .links = &.{
        .{ .from = "edge", .to = "api", .port = "http" },
        .{ .from = "api", .to = "db", .port = "sql" },
    },
};

// `edge` is public and `api` is internal, one tier apart in the wrong
// direction for the default `zone_boundaries`... which is exactly why the
// generator tests use their own policy set: they are testing rendering, not
// enforcement.
const demo_plan = ananke.Plan(demo, .{ .policies = policies.structural_only });

test "compose puts a service on its own tier plus the tiers it dials" {
    const yaml = demo_plan.compose_yaml;
    try expect(std.mem.indexOf(u8, yaml, "networks: [public, internal]") != null);
    try expect(std.mem.indexOf(u8, yaml, "networks: [internal, restricted]") != null);
    // The datastore is on its own tier only. Nothing in `public` can route to it.
    try expect(std.mem.indexOf(u8, yaml, "networks: [restricted]") != null);
}

test "compose never writes a secret into the file" {
    const yaml = demo_plan.compose_yaml;
    try expect(std.mem.indexOf(u8, yaml, "${PG_PASSWORD:?required by ananke}") != null);
}

test "compose picks a health probe that suits the protocol" {
    const yaml = demo_plan.compose_yaml;
    try expect(std.mem.indexOf(u8, yaml, "pg_isready") != null);
    try expect(std.mem.indexOf(u8, yaml, "https://127.0.0.1:443/healthz") != null);
}

test "compose publishes only what is exposed" {
    const yaml = demo_plan.compose_yaml;
    try expect(std.mem.indexOf(u8, yaml, "\"443:443\"") != null);
    try expect(std.mem.indexOf(u8, yaml, "\"5432:5432\"") == null);
}

test "nginx routes exactly the links that exist" {
    const conf = demo_plan.nginx_conf;
    try expect(std.mem.indexOf(u8, conf, "upstream api_http") != null);
    try expect(std.mem.indexOf(u8, conf, "location /api/") != null);
    // No link from the edge to the database, so no route to it.
    try expect(std.mem.indexOf(u8, conf, "location /db/") == null);
    try expect(std.mem.indexOf(u8, conf, "listen 443 ssl") != null);
}

test "the graph and the document mention every service" {
    for ([_][]const u8{ "edge", "api", "db" }) |name| {
        try expect(std.mem.indexOf(u8, demo_plan.graph_dot, name) != null);
        try expect(std.mem.indexOf(u8, demo_plan.doc_md, name) != null);
    }
    try expect(std.mem.indexOf(u8, demo_plan.doc_md, "```mermaid") != null);
}

test "compile-time lookups agree with the topology" {
    try expectEqual(@as(u16, 5432), demo_plan.port("db", "sql"));
    try expectEqualStrings("postgres:16", demo_plan.service("db").image);

    const e = demo_plan.endpoint("api", "db", "sql");
    try expectEqualStrings("db", e.host);
    try expectEqual(@as(u16, 5432), e.port);
    try expectEqual(ananke.Protocol.postgres, e.proto);
}

// --- helpers ---------------------------------------------------------------

test "yaml quoting escapes what it must" {
    try expectEqualStrings("\"a\\\"b\"", comptime text.yamlQuote("a\"b"));
    try expectEqualStrings("\"c:\\\\dir\"", comptime text.yamlQuote("c:\\dir"));
}

test "indent leaves blank lines alone" {
    try expectEqualStrings("  a\n\n  b\n", comptime text.indent("a\n\nb\n", 2));
}

test "custom policies plug in alongside the defaults" {
    const NoRedis = struct {
        pub const id = "no-redis";
        pub const title = "This shop does not run Redis";

        pub fn check(comptime t: Topology) []const ananke.Finding {
            comptime var out: []const ananke.Finding = &.{};
            inline for (t.services) |s| {
                inline for (s.ports) |p| {
                    if (p.proto != .redis) continue;
                    out = out ++ [_]ananke.Finding{.{
                        .subject = s.name,
                        .message = "speaks redis",
                        .fix = "use the database",
                    }};
                }
            }
            return out;
        }
    };

    const t: Topology = .{ .name = "t", .services = &.{.{
        .name = "cache",
        .zone = .restricted,
        .ports = &.{.{ .name = "redis", .number = 6379, .proto = .redis }},
    }} };
    try expectEqual(1, count(t, NoRedis));
}
