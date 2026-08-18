//! The policies that ship with Ananke.
//!
//! Every one of these is an ordinary namespace you could have written
//! yourself, and every one of them can be dropped from your policy set if you
//! disagree with it. `defaults` is a suggestion, not a law.

const std = @import("std");
const schema = @import("schema.zig");
const policy = @import("policy.zig");

const Topology = schema.Topology;
const Finding = policy.Finding;

/// The policy set applied when you do not name one yourself.
pub const defaults: []const type = &.{
    ServiceNames,
    UniquePorts,
    ValidLinks,
    ZoneBoundaries,
    NoPublishedDatastores,
    EncryptedEdges,
    PrivilegedPorts,
    ReplicaSanity,
    NoPlaintextSecrets,
    NoDependencyCycles,
    HealthChecks,
    NoOrphans,
};

/// Everything in `defaults` that can never be a false positive: naming,
/// collisions, dangling references, cycles. Useful as a starting point when
/// adopting Ananke on an existing system whose security posture is, let us
/// say, aspirational.
pub const structural_only: []const type = &.{
    ServiceNames,
    UniquePorts,
    ValidLinks,
    ReplicaSanity,
    NoDependencyCycles,
};

// ---------------------------------------------------------------------------

/// Service names must be unique and usable as DNS labels, because they become
/// hostnames in the generated compose file and upstream names in the
/// generated nginx config.
pub const ServiceNames = struct {
    pub const id = "service-names";
    pub const title = "Service names must be unique, lowercase DNS labels";

    pub fn check(comptime t: Topology) []const Finding {
        comptime var out: []const Finding = &.{};

        inline for (t.services, 0..) |s, i| {
            if (s.name.len == 0) {
                out = out ++ [_]Finding{.{
                    .subject = std.fmt.comptimePrint("services[{d}]", .{i}),
                    .message = "service has an empty name",
                    .fix = "give it a name; it becomes a hostname in the generated config",
                }};
                continue;
            }
            if (!isDnsLabel(s.name)) {
                out = out ++ [_]Finding{.{
                    .subject = s.name,
                    .message = "not a valid DNS label",
                    .fix = "use lowercase letters, digits and '-', starting and ending with a letter or digit",
                }};
            }
            inline for (t.services[i + 1 ..]) |other| {
                if (std.mem.eql(u8, s.name, other.name)) {
                    out = out ++ [_]Finding{.{
                        .subject = s.name,
                        .message = "two services share this name",
                        .fix = "rename one of them; generated config addresses services by name",
                    }};
                }
            }
        }
        return out;
    }

    fn isDnsLabel(comptime name: []const u8) bool {
        if (name.len == 0 or name.len > 63) return false;
        for (name, 0..) |c, i| {
            const edge = i == 0 or i == name.len - 1;
            const alnum = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9');
            if (alnum) continue;
            if (c == '-' and !edge) continue;
            return false;
        }
        return true;
    }
};

/// The classic. Two services cannot publish the same port on the same host,
/// and one service cannot declare the same port twice.
pub const UniquePorts = struct {
    pub const id = "unique-ports";
    pub const title = "No two published ports may collide";

    pub fn check(comptime t: Topology) []const Finding {
        comptime var out: []const Finding = &.{};

        // Collisions within a single service: same number twice, or same
        // handle twice.
        inline for (t.services) |s| {
            inline for (s.ports, 0..) |p, i| {
                inline for (s.ports[i + 1 ..]) |q| {
                    if (p.number == q.number) {
                        out = out ++ [_]Finding{.{
                            .subject = s.name ++ ":" ++ p.name ++ " / " ++ s.name ++ ":" ++ q.name,
                            .message = std.fmt.comptimePrint("one service declares port {d} twice", .{p.number}),
                            .fix = "drop one of the two port entries",
                        }};
                    }
                    if (std.mem.eql(u8, p.name, q.name)) {
                        out = out ++ [_]Finding{.{
                            .subject = s.name ++ ":" ++ p.name,
                            .message = "two ports on this service share a handle",
                            .fix = "handles are how links address ports; make them unique",
                        }};
                    }
                }
            }
        }

        // Collisions between services, on ports that leave the private
        // network and therefore actually contend for a host's port space.
        inline for (t.services, 0..) |a, i| {
            inline for (a.ports) |ap| {
                if (!ap.isPublished()) continue;
                inline for (t.services[i + 1 ..]) |b| {
                    inline for (b.ports) |bp| {
                        if (!bp.isPublished()) continue;
                        if (ap.number != bp.number) continue;
                        out = out ++ [_]Finding{.{
                            .subject = a.name ++ ":" ++ ap.name ++ " / " ++ b.name ++ ":" ++ bp.name,
                            .message = std.fmt.comptimePrint(
                                "both publish port {d}; only one of them would ever bind",
                                .{ap.number},
                            ),
                            .fix = "move one to a different port, or set `.expose = .cluster` if it does not need publishing",
                        }};
                    }
                }
            }
        }
        return out;
    }
};

/// Links must point at something that exists. A link naming a service that was
/// renamed, or a port that was deleted, is a production incident that has not
/// happened yet.
pub const ValidLinks = struct {
    pub const id = "valid-links";
    pub const title = "Links must resolve to a real service and a real port";

    pub fn check(comptime t: Topology) []const Finding {
        comptime var out: []const Finding = &.{};

        inline for (t.links, 0..) |l, i| {
            const label = l.from ++ " -> " ++ l.to ++ ":" ++ l.port;

            if (!t.has(l.from)) {
                out = out ++ [_]Finding{.{
                    .subject = label,
                    .message = "source service '" ++ l.from ++ "' does not exist",
                    .fix = "check for a typo, or add the service to the topology",
                }};
                continue;
            }
            const target = t.find(l.to) orelse {
                out = out ++ [_]Finding{.{
                    .subject = label,
                    .message = "target service '" ++ l.to ++ "' does not exist",
                    .fix = "check for a typo, or add the service to the topology",
                }};
                continue;
            };
            if (std.mem.eql(u8, l.from, l.to)) {
                out = out ++ [_]Finding{.{
                    .subject = label,
                    .message = "a service links to itself",
                    .fix = "delete the link; a service does not need permission to talk to itself",
                }};
                continue;
            }
            if (target.port(l.port) == null) {
                out = out ++ [_]Finding{.{
                    .subject = label,
                    .message = "'" ++ l.to ++ "' has no port named '" ++ l.port ++ "'",
                    .fix = "links address ports by handle; check what '" ++ l.to ++ "' actually declares",
                }};
                continue;
            }
            inline for (t.links[i + 1 ..]) |other| {
                if (std.mem.eql(u8, l.from, other.from) and
                    std.mem.eql(u8, l.to, other.to) and
                    std.mem.eql(u8, l.port, other.port))
                {
                    out = out ++ [_]Finding{.{
                        .subject = label,
                        .message = "this link is declared twice",
                        .fix = "delete the duplicate",
                        .severity = .warn,
                    }};
                }
            }
        }
        return out;
    }
};

/// Zero trust, mechanically. Connections flow inward, one tier at a time. The
/// frontend cannot reach the database because there is no way to express it
/// that survives compilation.
pub const ZoneBoundaries = struct {
    pub const id = "zone-boundaries";
    pub const title = "A service may reach its own trust tier or exactly one tier deeper";

    pub fn check(comptime t: Topology) []const Finding {
        comptime var out: []const Finding = &.{};

        inline for (t.links) |l| {
            const from = t.find(l.from) orelse continue; // valid-links reports this
            const to = t.find(l.to) orelse continue;
            const label = l.from ++ " (" ++ from.zone.tag() ++ ") -> " ++ l.to ++ " (" ++ to.zone.tag() ++ ")";

            const a = from.zone.depth();
            const b = to.zone.depth();

            if (b < a) {
                out = out ++ [_]Finding{.{
                    .subject = label,
                    .message = "connection flows outward, from a more trusted tier to a less trusted one",
                    .fix = "invert the link, or move '" ++ l.to ++ "' inward",
                }};
            } else if (b > a + 1) {
                out = out ++ [_]Finding{.{
                    .subject = label,
                    .message = std.fmt.comptimePrint(
                        "connection crosses {d} trust tiers in one hop",
                        .{b - a},
                    ),
                    .fix = "route it through a service in the tier between them",
                }};
            }
        }
        return out;
    }
};

/// Nothing in the innermost tier gets a published port. Not for debugging, not
/// temporarily, not just this once.
pub const NoPublishedDatastores = struct {
    pub const id = "no-published-datastores";
    pub const title = "Restricted-tier services may not publish ports";

    pub fn check(comptime t: Topology) []const Finding {
        comptime var out: []const Finding = &.{};
        inline for (t.services) |s| {
            if (s.zone != .restricted) continue;
            inline for (s.ports) |p| {
                if (!p.isPublished()) continue;
                out = out ++ [_]Finding{.{
                    .subject = s.name ++ ":" ++ p.name,
                    .message = std.fmt.comptimePrint(
                        "a restricted-tier service publishes port {d} as '{s}'",
                        .{ p.number, p.expose.tag() },
                    ),
                    .fix = "set `.expose = .cluster`; reach it through a service in the internal tier",
                }};
            }
        }
        return out;
    }
};

/// Anything the internet can dial must be encrypted.
pub const EncryptedEdges = struct {
    pub const id = "encrypted-edges";
    pub const title = "Internet-facing ports must carry transport encryption";

    pub fn check(comptime t: Topology) []const Finding {
        comptime var out: []const Finding = &.{};
        inline for (t.services) |s| {
            inline for (s.ports) |p| {
                if (p.expose != .public) continue;
                if (p.isEncrypted()) continue;
                out = out ++ [_]Finding{.{
                    .subject = s.name ++ ":" ++ p.name,
                    .message = std.fmt.comptimePrint(
                        "port {d} is public but speaks plaintext {s}",
                        .{ p.number, p.proto.tag() },
                    ),
                    .fix = "set `.tls = true`, or use `.proto = .https`, or drop it to `.expose = .host`",
                }};
            }
        }
        return out;
    }
};

/// Privileged ports belong to the edge, where something with the right
/// capabilities is listening on purpose. An application container asking for
/// port 80 is asking to run as root.
pub const PrivilegedPorts = struct {
    pub const id = "privileged-ports";
    pub const title = "Ports below 1024 are reserved for internet-facing listeners";

    pub fn check(comptime t: Topology) []const Finding {
        comptime var out: []const Finding = &.{};
        inline for (t.services) |s| {
            inline for (s.ports) |p| {
                if (p.number == 0) {
                    out = out ++ [_]Finding{.{
                        .subject = s.name ++ ":" ++ p.name,
                        .message = "port 0 means 'pick one at random', which cannot be written into config",
                        .fix = "choose a real port number",
                    }};
                    continue;
                }
                if (p.number >= 1024) continue;
                if (p.expose == .public) continue;
                out = out ++ [_]Finding{.{
                    .subject = s.name ++ ":" ++ p.name,
                    .message = std.fmt.comptimePrint(
                        "port {d} is privileged but only exposed as '{s}'",
                        .{ p.number, p.expose.tag() },
                    ),
                    .fix = "use a port at or above 1024; only the public edge has business below it",
                }};
            }
        }
        return out;
    }
};

/// A replicated service cannot bind a fixed host port -- the second replica
/// would lose the race. This is the bug that only shows up when you scale up.
pub const ReplicaSanity = struct {
    pub const id = "replica-sanity";
    pub const title = "Replica counts must be consistent with published ports";

    pub fn check(comptime t: Topology) []const Finding {
        comptime var out: []const Finding = &.{};
        inline for (t.services) |s| {
            if (s.replicas == 0) {
                out = out ++ [_]Finding{.{
                    .subject = s.name,
                    .message = "declared with zero replicas, so it will never run",
                    .fix = "set `.replicas` to at least 1, or delete the service",
                }};
                continue;
            }
            if (s.replicas == 1) continue;
            inline for (s.ports) |p| {
                if (p.expose != .host) continue;
                out = out ++ [_]Finding{.{
                    .subject = s.name ++ ":" ++ p.name,
                    .message = std.fmt.comptimePrint(
                        "{d} replicas cannot all bind host port {d}",
                        .{ s.replicas, p.number },
                    ),
                    .fix = "put it behind a load balancer and set `.expose = .cluster`, or run a single replica",
                }};
            }
        }
        return out;
    }
};

/// Credentials do not go in the source file that generates your config, since
/// that config lands in your repository.
pub const NoPlaintextSecrets = struct {
    pub const id = "no-plaintext-secrets";
    pub const title = "Credential-shaped environment variables must come from secrets";

    const needles = [_][]const u8{
        "PASSWORD", "PASSWD", "SECRET", "TOKEN", "CREDENTIAL", "PRIVATE_KEY", "API_KEY", "ACCESS_KEY",
    };

    pub fn check(comptime t: Topology) []const Finding {
        comptime var out: []const Finding = &.{};
        inline for (t.services) |s| {
            inline for (s.env) |e| {
                if (e.value != .literal) continue;
                if (!looksLikeCredential(e.key)) continue;
                out = out ++ [_]Finding{.{
                    .subject = s.name ++ "." ++ e.key,
                    .message = "a credential-shaped variable holds a literal value",
                    .fix = "use `.secret(\"" ++ e.key ++ "\", \"" ++ e.key ++ "\")` so the value is resolved at deploy time",
                }};
            }
        }
        return out;
    }

    fn looksLikeCredential(comptime key: []const u8) bool {
        if (std.mem.indexOf(u8, key, "PUBLIC") != null) return false;
        for (needles) |n| {
            if (std.mem.indexOf(u8, key, n) != null) return true;
        }
        return false;
    }
};

/// Startup order has to be a DAG or nothing can ever come up cleanly.
/// Kahn's algorithm, run inside the compiler.
pub const NoDependencyCycles = struct {
    pub const id = "no-dependency-cycles";
    pub const title = "The link graph must be acyclic";

    pub fn check(comptime t: Topology) []const Finding {
        const n = t.services.len;
        if (n == 0) return &.{};

        comptime var indegree: [n]usize = @splat(0);
        comptime var settled: [n]bool = @splat(false);

        inline for (t.links) |l| {
            const to = t.indexOf(l.to) orelse continue;
            if (t.indexOf(l.from) == null) continue;
            indegree[to] += 1;
        }

        // At most `n` rounds are needed: every round that makes progress
        // settles at least one service.
        comptime var remaining = n;
        inline for (0..n) |_| {
            comptime var progressed = false;
            inline for (t.services, 0..) |_, i| {
                if (settled[i] or indegree[i] != 0) continue;
                settled[i] = true;
                remaining -= 1;
                progressed = true;
                inline for (t.links) |l| {
                    const from = t.indexOf(l.from) orelse continue;
                    if (from != i) continue;
                    const to = t.indexOf(l.to) orelse continue;
                    if (!settled[to]) indegree[to] -= 1;
                }
            }
            if (!progressed) break;
        }

        if (remaining == 0) return &.{};

        comptime var members: []const u8 = "";
        inline for (t.services, 0..) |s, i| {
            if (settled[i]) continue;
            members = members ++ (if (members.len == 0) "" else ", ") ++ s.name;
        }
        return &.{.{
            .subject = members,
            .message = "these services form a dependency cycle, so no start order exists",
            .fix = "break the loop: one of these links should be an event or a retry, not a startup dependency",
        }};
    }
};

/// A service nobody can probe is a service that fails silently.
pub const HealthChecks = struct {
    pub const id = "health-checks";
    pub const title = "Health checks must point at a port the service declares";

    pub fn check(comptime t: Topology) []const Finding {
        comptime var out: []const Finding = &.{};
        inline for (t.services) |s| {
            const h = s.health orelse {
                if (s.ports.len != 0) {
                    out = out ++ [_]Finding{.{
                        .subject = s.name,
                        .message = "listens on a port but declares no health check",
                        .fix = "add `.health = .{ .port = \"" ++ s.ports[0].name ++ "\" }`",
                        .severity = .warn,
                    }};
                }
                continue;
            };
            if (s.port(h.port) == null) {
                out = out ++ [_]Finding{.{
                    .subject = s.name ++ ".health",
                    .message = "health check probes port '" ++ h.port ++ "', which this service does not declare",
                    .fix = "point it at one of the service's own ports",
                }};
            }
            if (h.timeout_s >= h.interval_s) {
                out = out ++ [_]Finding{.{
                    .subject = s.name ++ ".health",
                    .message = std.fmt.comptimePrint(
                        "timeout ({d}s) is not shorter than interval ({d}s), so probes overlap",
                        .{ h.timeout_s, h.interval_s },
                    ),
                    .fix = "raise the interval or lower the timeout",
                    .severity = .warn,
                }};
            }
        }
        return out;
    }
};

/// A service with no links in, no links out and no published port is either
/// dead code or a missing link. Both are worth a second look, neither is worth
/// stopping the build.
pub const NoOrphans = struct {
    pub const id = "no-orphans";
    pub const title = "Every service should be reachable from something";

    pub fn check(comptime t: Topology) []const Finding {
        comptime var out: []const Finding = &.{};
        inline for (t.services) |s| {
            if (s.hasPublishedPort()) continue;
            if (t.inbound(s.name).len != 0) continue;
            if (t.outbound(s.name).len != 0) continue;
            out = out ++ [_]Finding{.{
                .subject = s.name,
                .message = "nothing links to it, it links to nothing, and it publishes nothing",
                .fix = "add the link you meant to add, or delete the service",
                .severity = .warn,
            }};
        }
        return out;
    }
};
