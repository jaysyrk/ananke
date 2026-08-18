//! The vocabulary of an Ananke topology.
//!
//! Everything in this file is plain data: structs, enums and slices that you
//! write as ordinary Zig literals in your own source. Nothing here allocates,
//! nothing here runs at runtime. The whole point is that a `Topology` is a
//! value the *compiler* can look at while it is compiling your program.

const std = @import("std");

/// Trust tiers, ordered from the hostile outside world inwards.
///
/// The ordering is the load-bearing part: `zone_boundaries` uses it to decide
/// which links are legal. A service may talk to its own tier or exactly one
/// tier deeper, never further, and never to a tier it has no business knowing
/// exists.
pub const Zone = enum {
    /// The edge. Load balancers and CDNs; reachable from the internet.
    public,
    /// Frontends and API gateways. Reachable from the edge only.
    dmz,
    /// Application services. Reachable from the DMZ only.
    internal,
    /// Datastores, queues, secret stores. Reachable from `internal` only.
    restricted,

    /// How many trust tiers deep this zone sits. `public` is 0.
    pub fn depth(z: Zone) u8 {
        return @intFromEnum(z);
    }

    pub fn tag(z: Zone) []const u8 {
        return @tagName(z);
    }
};

/// What is spoken over a port. Used both for policy decisions (is this
/// encrypted?) and for code generation (what does nginx need to emit?).
pub const Protocol = enum {
    tcp,
    udp,
    http,
    https,
    grpc,
    postgres,
    redis,
    amqp,

    /// True when the protocol carries its own transport encryption, so an
    /// explicit `tls = true` on the port would be redundant.
    pub fn isEncrypted(p: Protocol) bool {
        return switch (p) {
            .https => true,
            .tcp, .udp, .http, .grpc, .postgres, .redis, .amqp => false,
        };
    }

    /// True when nginx can reverse-proxy this as HTTP rather than raw TCP.
    pub fn isHttpish(p: Protocol) bool {
        return switch (p) {
            .http, .https, .grpc => true,
            else => false,
        };
    }

    pub fn tag(p: Protocol) []const u8 {
        return @tagName(p);
    }
};

/// How far a port is reachable.
pub const Exposure = enum {
    /// Only other services on the same private network can dial it.
    cluster,
    /// Published on the host running the container. Two services cannot share
    /// a host port number, and a replicated service cannot publish one at all.
    host,
    /// Published to the internet. Requires transport encryption.
    public,

    pub fn tag(e: Exposure) []const u8 {
        return @tagName(e);
    }
};

/// A single listening port belonging to a service.
pub const Port = struct {
    /// Short handle used by links and by generated config: "http", "metrics".
    name: []const u8,
    number: u16,
    proto: Protocol = .tcp,
    expose: Exposure = .cluster,
    /// Set when the service terminates TLS on this port itself. Ignored for
    /// protocols that are encrypted by definition.
    tls: bool = false,

    pub fn isEncrypted(p: Port) bool {
        return p.tls or p.proto.isEncrypted();
    }

    /// Reachable from outside the private network in any way.
    pub fn isPublished(p: Port) bool {
        return p.expose != .cluster;
    }
};

/// One environment variable handed to a service.
pub const Env = struct {
    key: []const u8,
    value: Value,

    pub const Value = union(enum) {
        /// Baked into the generated config verbatim. Fine for log levels,
        /// fatal for credentials -- see the `no_plaintext_secrets` policy.
        literal: []const u8,
        /// Resolved from the deployment environment at run time. The payload
        /// is the name of the secret, never the secret itself.
        secret: []const u8,
    };

    pub fn literal(key: []const u8, v: []const u8) Env {
        return .{ .key = key, .value = .{ .literal = v } };
    }

    pub fn secret(key: []const u8, name: []const u8) Env {
        return .{ .key = key, .value = .{ .secret = name } };
    }
};

/// A liveness probe. Its `port` must be one the service actually declares.
pub const Health = struct {
    /// Name of one of the service's own ports.
    port: []const u8,
    path: []const u8 = "/healthz",
    interval_s: u16 = 10,
    timeout_s: u16 = 2,
    retries: u8 = 3,
};

/// One deployable unit.
pub const Service = struct {
    name: []const u8,
    zone: Zone,
    /// Container image. Empty means "built from this repository".
    image: []const u8 = "",
    ports: []const Port = &.{},
    env: []const Env = &.{},
    replicas: u16 = 1,
    health: ?Health = null,
    /// Free-form note carried into generated files as a comment.
    note: []const u8 = "",

    /// Look up one of this service's ports by its handle.
    pub fn port(s: Service, name: []const u8) ?Port {
        for (s.ports) |p| {
            if (std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }

    /// Look up one of this service's ports by number.
    pub fn portNumber(s: Service, number: u16) ?Port {
        for (s.ports) |p| {
            if (p.number == number) return p;
        }
        return null;
    }

    pub fn hasPublishedPort(s: Service) bool {
        for (s.ports) |p| {
            if (p.isPublished()) return true;
        }
        return false;
    }
};

/// A permitted connection: `from` dials `to` on one of `to`'s ports.
///
/// The set of links *is* the firewall. A connection that is not written down
/// here is a connection the generated config will not allow, and a connection
/// written down here that breaks a trust boundary is a compile error.
pub const Link = struct {
    from: []const u8,
    /// Name of the target service.
    to: []const u8,
    /// Name of the target service's port -- the handle, not the number, so
    /// that renumbering a port cannot silently repoint a link.
    port: []const u8,
    note: []const u8 = "",
};

/// The whole system, as one value.
pub const Topology = struct {
    name: []const u8,
    services: []const Service,
    links: []const Link = &.{},
    /// Written into every generated file so nobody edits the output by hand.
    source: []const u8 = "your topology source file",

    pub fn find(t: Topology, name: []const u8) ?Service {
        for (t.services) |s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }

    pub fn has(t: Topology, name: []const u8) bool {
        return t.find(name) != null;
    }

    /// Index of a service by name, for the array-based algorithms in policies.
    pub fn indexOf(t: Topology, name: []const u8) ?usize {
        for (t.services, 0..) |s, i| {
            if (std.mem.eql(u8, s.name, name)) return i;
        }
        return null;
    }

    /// Every service `name` is allowed to dial.
    pub fn outbound(comptime t: Topology, comptime name: []const u8) []const Link {
        comptime var out: []const Link = &.{};
        for (t.links) |l| {
            if (std.mem.eql(u8, l.from, name)) out = out ++ [_]Link{l};
        }
        return out;
    }

    /// Every service allowed to dial `name`.
    pub fn inbound(comptime t: Topology, comptime name: []const u8) []const Link {
        comptime var out: []const Link = &.{};
        for (t.links) |l| {
            if (std.mem.eql(u8, l.to, name)) out = out ++ [_]Link{l};
        }
        return out;
    }
};
