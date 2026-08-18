//! docker-compose generator.
//!
//! The interesting part is the network layout: one network per trust tier, and
//! a service is attached to its own tier plus the tiers of the services it is
//! allowed to dial. The trust model the compiler enforced is therefore also
//! enforced by the runtime -- a container that never got a link has no route.

const std = @import("std");
const schema = @import("../schema.zig");
const text = @import("text.zig");

const Topology = schema.Topology;
const Service = schema.Service;
const Zone = schema.Zone;

/// Networks a service must join: its own tier, plus every tier it links into.
pub fn networksFor(comptime t: Topology, comptime s: Service) []const []const u8 {
    comptime var out: []const []const u8 = &.{s.zone.tag()};
    inline for (t.links) |l| {
        if (!std.mem.eql(u8, l.from, s.name)) continue;
        const target = t.find(l.to) orelse continue;
        const name = target.zone.tag();
        comptime var seen = false;
        inline for (out) |o| {
            if (std.mem.eql(u8, o, name)) seen = true;
        }
        if (!seen) out = out ++ [_][]const u8{name};
    }
    return out;
}

/// Every zone that has at least one service in it.
pub fn zonesInUse(comptime t: Topology) []const []const u8 {
    comptime var out: []const []const u8 = &.{};
    inline for (@typeInfo(Zone).@"enum".fields) |f| {
        const zone: Zone = @enumFromInt(f.value);
        inline for (t.services) |s| {
            if (s.zone != zone) continue;
            out = out ++ [_][]const u8{f.name};
            break;
        }
    }
    return out;
}

pub fn render(comptime t: Topology) []const u8 {
    @setEvalBranchQuota(200_000);
    comptime var out: []const u8 = text.banner("#", t.name, t.source) ++
        "\nname: " ++ t.name ++ "\n\nservices:\n";

    inline for (t.services) |s| {
        out = out ++ text.indent(service(t, s), 2);
    }

    out = out ++ "\nnetworks:\n";
    inline for (zonesInUse(t)) |z| {
        out = out ++ "  " ++ z ++ ":\n    driver: bridge\n";
    }
    return out;
}

fn service(comptime t: Topology, comptime s: Service) []const u8 {
    comptime var out: []const u8 = "";
    if (s.note.len != 0) out = out ++ "# " ++ s.note ++ "\n";
    out = out ++ s.name ++ ":\n";

    if (s.image.len != 0) {
        out = out ++ "  image: " ++ s.image ++ "\n";
    } else {
        out = out ++ "  build: .\n";
    }
    out = out ++ "  restart: unless-stopped\n";

    const published = comptime publishedPorts(s);
    if (published.len != 0) {
        out = out ++ "  ports:\n";
        inline for (published) |p| {
            out = out ++ std.fmt.comptimePrint(
                "    - \"{d}:{d}\"  # {s}, {s}{s}\n",
                .{
                    p.number,
                    p.number,
                    p.name,
                    p.proto.tag(),
                    if (p.isEncrypted()) ", encrypted" else "",
                },
            );
        }
    }

    const internal = comptime clusterPorts(s);
    if (internal.len != 0) {
        out = out ++ "  expose:\n";
        inline for (internal) |p| {
            out = out ++ std.fmt.comptimePrint("    - \"{d}\"  # {s}\n", .{ p.number, p.name });
        }
    }

    if (s.env.len != 0) {
        out = out ++ "  environment:\n";
        inline for (s.env) |e| {
            out = out ++ "    " ++ e.key ++ ": " ++ switch (e.value) {
                .literal => |v| text.yamlQuote(v),
                // Compose substitutes this from the deployment environment and
                // refuses to start if it is unset. The secret never enters the
                // repository.
                .secret => |name| "\"${" ++ name ++ ":?required by ananke}\"",
            } ++ "\n";
        }
    }

    const deps = comptime dependencies(t, s);
    if (deps.len != 0) {
        out = out ++ "  depends_on:\n";
        inline for (deps) |d| {
            const target = t.find(d).?;
            out = out ++ "    " ++ d ++ ":\n      condition: " ++
                (if (target.health != null) "service_healthy" else "service_started") ++ "\n";
        }
    }

    if (s.health) |h| {
        const p = s.port(h.port).?;
        out = out ++ "  healthcheck:\n    test: " ++ probe(p, h) ++ "\n" ++
            std.fmt.comptimePrint(
                "    interval: {d}s\n    timeout: {d}s\n    retries: {d}\n",
                .{ h.interval_s, h.timeout_s, h.retries },
            );
    }

    if (s.replicas != 1) {
        out = out ++ std.fmt.comptimePrint("  deploy:\n    replicas: {d}\n", .{s.replicas});
    }

    out = out ++ "  networks: " ++ text.flowSeq(networksFor(t, s)) ++ "\n\n";
    return out;
}

fn publishedPorts(comptime s: Service) []const schema.Port {
    comptime var out: []const schema.Port = &.{};
    inline for (s.ports) |p| {
        if (p.isPublished()) out = out ++ [_]schema.Port{p};
    }
    return out;
}

fn clusterPorts(comptime s: Service) []const schema.Port {
    comptime var out: []const schema.Port = &.{};
    inline for (s.ports) |p| {
        if (!p.isPublished()) out = out ++ [_]schema.Port{p};
    }
    return out;
}

/// Distinct link targets, in declaration order.
fn dependencies(comptime t: Topology, comptime s: Service) []const []const u8 {
    comptime var out: []const []const u8 = &.{};
    inline for (t.links) |l| {
        if (!std.mem.eql(u8, l.from, s.name)) continue;
        if (t.find(l.to) == null) continue;
        comptime var seen = false;
        inline for (out) |o| {
            if (std.mem.eql(u8, o, l.to)) seen = true;
        }
        if (!seen) out = out ++ [_][]const u8{l.to};
    }
    return out;
}

/// The right way to ask a given protocol whether it is alive. Emitting a
/// curl against a Postgres port would generate a config that is syntactically
/// perfect and permanently unhealthy.
fn probe(comptime p: schema.Port, comptime h: schema.Health) []const u8 {
    const scheme = if (p.isEncrypted()) "https" else "http";
    return switch (p.proto) {
        .http, .https, .grpc => std.fmt.comptimePrint(
            "[\"CMD\", \"curl\", \"-fsS\", \"{s}://127.0.0.1:{d}{s}\"]",
            .{ scheme, p.number, h.path },
        ),
        .postgres => std.fmt.comptimePrint(
            "[\"CMD-SHELL\", \"pg_isready -q -h 127.0.0.1 -p {d}\"]",
            .{p.number},
        ),
        .redis => std.fmt.comptimePrint(
            "[\"CMD\", \"redis-cli\", \"-p\", \"{d}\", \"ping\"]",
            .{p.number},
        ),
        .tcp, .udp, .amqp => std.fmt.comptimePrint(
            "[\"CMD-SHELL\", \"timeout 1 bash -c '</dev/tcp/127.0.0.1/{d}'\"]",
            .{p.number},
        ),
    };
}
