//! The policy interface.
//!
//! A policy is a namespace -- any struct type -- exposing three declarations:
//!
//!     pub const id    = "no-clown-ports";
//!     pub const title = "Ports may not be funny numbers";
//!     pub fn check(comptime t: Topology) []const Finding { ... }
//!
//! Namespaces rather than function pointers, deliberately: a `check` needs its
//! topology as a `comptime` parameter so it can build its result with `++`,
//! and a function with a comptime parameter has no runtime address to store.
//! Passing policies as `[]const type` keeps every check in the comptime world
//! where it belongs.

const std = @import("std");
const schema = @import("schema.zig");
const Topology = schema.Topology;

/// How badly a finding should ruin your day.
pub const Severity = enum {
    /// Halts the build. Nothing is generated, no binary is produced.
    deny,
    /// Survives the build and is carried into the binary, where `ananke plan`
    /// prints it. Compile time has no way to print without failing, so this is
    /// the honest place for advice you are allowed to ignore.
    warn,
};

/// One thing a policy objects to.
pub const Finding = struct {
    /// What the finding is about: a service name, a link, a port.
    subject: []const u8,
    /// What is wrong, in one line, in plain words.
    message: []const u8,
    /// What to do about it. Worth writing; it is the whole difference between
    /// a compiler that blocks you and one that unblocks you.
    fix: []const u8 = "",
    severity: Severity = .deny,
};

/// A finding plus the policy that raised it.
pub const Report = struct {
    policy: []const u8,
    title: []const u8,
    finding: Finding,
};

/// Compile-time sanity check that `P` looks like a policy. Produces a clear
/// error at the point of use instead of a confusing one inside the engine.
pub fn assertIsPolicy(comptime P: type) void {
    if (!@hasDecl(P, "id")) @compileError(@typeName(P) ++ " is not a policy: missing `pub const id`");
    if (!@hasDecl(P, "title")) @compileError(@typeName(P) ++ " is not a policy: missing `pub const title`");
    if (!@hasDecl(P, "check")) @compileError(@typeName(P) ++ " is not a policy: missing `pub fn check(comptime Topology) []const Finding`");
}

/// Run one policy and tag its findings with the policy's identity.
pub fn run(comptime P: type, comptime t: Topology) []const Report {
    comptime assertIsPolicy(P);
    comptime var out: []const Report = &.{};
    inline for (P.check(t)) |f| {
        out = out ++ [_]Report{.{ .policy = P.id, .title = P.title, .finding = f }};
    }
    return out;
}

/// Run every policy in `policies` against `t`.
pub fn audit(comptime t: Topology, comptime policies: []const type) []const Report {
    @setEvalBranchQuota(200_000);
    comptime var out: []const Report = &.{};
    inline for (policies) |P| {
        out = out ++ run(P, t);
    }
    return out;
}

/// Split an audit by severity.
pub fn filter(comptime reports: []const Report, comptime severity: Severity) []const Report {
    comptime var out: []const Report = &.{};
    inline for (reports) |r| {
        if (r.finding.severity == severity) out = out ++ [_]Report{r};
    }
    return out;
}
