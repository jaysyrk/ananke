//! ananke -- compiler-enforced infrastructure.
//!
//! Your network layout is a value in your source code. The compiler reads it,
//! checks it against a set of policies, and either refuses to produce a binary
//! or generates the deployment config for you. There is no separate YAML file
//! to drift out of sync, because the YAML is an output of the build.
//!
//! The whole surface, in one example:
//!
//! ```zig
//! const ananke = @import("ananke");
//!
//! const topology: ananke.Topology = .{
//!     .name = "hello",
//!     .services = &.{
//!         .{ .name = "web", .zone = .dmz, .ports = &.{
//!             .{ .name = "http", .number = 8080, .proto = .http, .expose = .host },
//!         } },
//!         .{ .name = "db", .zone = .restricted, .ports = &.{
//!             .{ .name = "sql", .number = 5432, .proto = .postgres },
//!         } },
//!     },
//!     // Uncomment to watch the build fail: dmz cannot reach restricted.
//!     // .links = &.{ .{ .from = "web", .to = "db", .port = "sql" } },
//! };
//!
//! const plan = ananke.Plan(topology, .{});
//! ```
//!
//! Named after the Greek personification of necessity: the constraint nobody,
//! not even a god, gets to argue with.

const schema = @import("schema.zig");
const plan_mod = @import("plan.zig");

// The vocabulary you write your topology in.
pub const Topology = schema.Topology;
pub const Service = schema.Service;
pub const Port = schema.Port;
pub const Link = schema.Link;
pub const Env = schema.Env;
pub const Health = schema.Health;
pub const Zone = schema.Zone;
pub const Protocol = schema.Protocol;
pub const Exposure = schema.Exposure;

// The door every topology has to walk through.
pub const Plan = plan_mod.Plan;
pub const Options = plan_mod.Options;
pub const Artifact = plan_mod.Artifact;
pub const Endpoint = plan_mod.Endpoint;

// Writing your own policies.
pub const policy = @import("policy.zig");
pub const Finding = policy.Finding;
pub const Report = policy.Report;
pub const Severity = policy.Severity;

/// The policies that ship with ananke, individually addressable so you can
/// build a set out of the ones you agree with.
pub const policies = @import("policies.zig");

/// Verification on its own, for tools that want to report rather than enforce.
pub const verify = @import("verify.zig");

/// The generators, if you want to render one without building a whole `Plan`.
pub const emit = struct {
    pub const compose = @import("emit/compose.zig");
    pub const nginx = @import("emit/nginx.zig");
    pub const dot = @import("emit/dot.zig");
    pub const markdown = @import("emit/markdown.zig");
};

/// Socket helpers for the run-time phase.
pub const runtime = @import("runtime.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("test_policies.zig");
}
