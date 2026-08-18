//! `Plan` is the load-bearing type of the whole library.
//!
//! You cannot obtain one without verification having run, because verification
//! runs while the type is being constructed. Every generated file, every port
//! number and every socket the program later opens hangs off a `Plan`, so
//! there is no path from a topology to a running process that skips the
//! checks. That is the entire trick: "if it compiles, your server is built"
//! is enforced by making the compiler's type constructor the only door in.

const std = @import("std");
const schema = @import("schema.zig");
const policy = @import("policy.zig");
const policies = @import("policies.zig");
const verify = @import("verify.zig");
const compose = @import("emit/compose.zig");
const nginx = @import("emit/nginx.zig");
const dot = @import("emit/dot.zig");
const markdown = @import("emit/markdown.zig");
const runtime = @import("runtime.zig");

const Topology = schema.Topology;
const Service = schema.Service;

pub const Options = struct {
    /// The policies to enforce. Replace it to disagree with the defaults.
    policies: []const type = policies.defaults,
    /// Policies of your own, run alongside `policies`.
    extra: []const type = &.{},
};

/// A file the compiler decided the contents of.
pub const Artifact = struct {
    path: []const u8,
    contents: []const u8,
    description: []const u8,
};

/// One endpoint of a permitted connection.
pub const Endpoint = struct {
    host: []const u8,
    port: u16,
    proto: schema.Protocol,
};

/// Verify `t`, then hand back everything that follows from it.
pub fn Plan(comptime t: Topology, comptime opts: Options) type {
    @setEvalBranchQuota(1_000_000);

    const policy_set = opts.policies ++ opts.extra;

    // This is the whole verification phase. If any policy denies anything,
    // compilation stops on the next line and nothing below exists.
    const warns = verify.verify(t, policy_set);

    return struct {
        const Self = @This();

        /// The topology, exactly as written.
        pub const topology = t;

        /// Findings that did not justify stopping the build. Compile time
        /// cannot print, so they ride along in the binary and `ananke plan`
        /// shows them.
        pub const warnings: []const policy.Report = warns;

        /// Generated config, produced during compilation and baked into the
        /// binary as string constants. Writing them out at run time is just a
        /// `write` call; the decisions were all made by the compiler.
        pub const compose_yaml: []const u8 = compose.render(t);
        pub const nginx_conf: []const u8 = nginx.render(t);
        pub const graph_dot: []const u8 = dot.render(t);
        pub const doc_md: []const u8 = markdown.render(t);

        pub const artifacts: []const Artifact = &.{
            .{ .path = "docker-compose.yaml", .contents = compose_yaml, .description = "one network per trust tier, links become routes" },
            .{ .path = "nginx.conf", .contents = nginx_conf, .description = "reverse proxy derived from the link graph" },
            .{ .path = "topology.dot", .contents = graph_dot, .description = "graphviz source; render with `dot -Tsvg`" },
            .{ .path = "INFRASTRUCTURE.md", .contents = doc_md, .description = "human-readable summary with a mermaid diagram" },
        };

        /// Look up a service. Naming one that does not exist is a compile
        /// error, not a null check.
        pub fn service(comptime name: []const u8) Service {
            return comptime t.find(name) orelse @compileError(
                "ananke: '" ++ name ++ "' is not a service in topology '" ++ t.name ++ "'",
            );
        }

        /// The number behind a port handle. Renaming a port breaks the build
        /// rather than the deployment.
        pub fn port(comptime service_name: []const u8, comptime port_name: []const u8) u16 {
            const s = comptime service(service_name);
            const p = comptime s.port(port_name) orelse @compileError(
                "ananke: service '" ++ service_name ++ "' has no port named '" ++ port_name ++ "'",
            );
            return p.number;
        }

        /// Where `from` should dial to reach `to`.
        ///
        /// Compiles only if the topology contains that link, so a service
        /// cannot open a connection the policies never approved. Deleting a
        /// link breaks every call site that relied on it.
        pub fn endpoint(
            comptime from: []const u8,
            comptime to: []const u8,
            comptime port_name: []const u8,
        ) Endpoint {
            return comptime found: {
                _ = service(from);
                const target = service(to);
                for (t.links) |l| {
                    if (!std.mem.eql(u8, l.from, from)) continue;
                    if (!std.mem.eql(u8, l.to, to)) continue;
                    if (!std.mem.eql(u8, l.port, port_name)) continue;
                    const p = target.port(port_name).?;
                    break :found .{ .host = to, .port = p.number, .proto = p.proto };
                }
                @compileError(
                    "ananke: '" ++ from ++ "' has no link to '" ++ to ++ ":" ++ port_name ++
                        "', so it is not allowed to connect there.\n" ++
                        "  Add `.{ .from = \"" ++ from ++ "\", .to = \"" ++ to ++ "\", .port = \"" ++ port_name ++ "\" }` " ++
                        "to the topology's links -- if the trust tiers allow it.",
                );
            };
        }

        /// Sockets for every published port of `service_name`, sized and
        /// numbered at compile time.
        pub fn Listeners(comptime service_name: []const u8) type {
            return runtime.Listeners(t, service_name);
        }

        /// A short description of the verified plan, rendered at compile time.
        pub const summary: []const u8 = renderSummary();

        fn renderSummary() []const u8 {
            comptime var out: []const u8 = "topology " ++ t.name ++ "\n" ++
                "  source     " ++ t.source ++ "\n" ++
                std.fmt.comptimePrint(
                    "  verified   {d} service(s), {d} link(s), {d} polic(y|ies)\n",
                    .{ t.services.len, t.links.len, policy_set.len },
                );
            inline for (t.services) |s| {
                out = out ++ "  " ++ padded(s.name, 10) ++ " " ++ padded(s.zone.tag(), 11);
                inline for (s.ports, 0..) |p, i| {
                    out = out ++ (if (i == 0) "" else " ") ++
                        std.fmt.comptimePrint("{s}:{d}/{s}", .{ p.name, p.number, p.expose.tag() });
                }
                out = out ++ "\n";
            }
            return out;
        }

        fn padded(comptime s: []const u8, comptime width: usize) []const u8 {
            if (s.len >= width) return s;
            return s ++ " " ** (width - s.len);
        }

        comptime {
            // Force the generators to run during compilation rather than
            // lazily, so a bug in a generator is a build failure too.
            _ = compose_yaml;
            _ = nginx_conf;
            _ = graph_dot;
            _ = doc_md;
            _ = Self;
        }
    };
}
