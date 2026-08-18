//! The verification phase, and the error message it prints when it fails.
//!
//! There is exactly one interesting line in this file -- the `@compileError`
//! near the bottom. Everything above it exists to make that error worth
//! reading.

const std = @import("std");
const schema = @import("schema.zig");
const policy = @import("policy.zig");
const policies = @import("policies.zig");

const Topology = schema.Topology;
const Report = policy.Report;

/// Run `policy_set` against `t` and halt the build if anything is denied.
///
/// Returns the warnings, which cannot be printed from compile time -- a
/// compiler has no stdout, only the ability to stop -- so they are handed back
/// for the program to print at run time.
pub fn verify(comptime t: Topology, comptime policy_set: []const type) []const Report {
    @setEvalBranchQuota(200_000);
    const reports = comptime policy.audit(t, policy_set);
    const denials = comptime policy.filter(reports, .deny);
    const warnings = comptime policy.filter(reports, .warn);

    if (denials.len != 0) {
        @compileError(render(t, denials, warnings.len));
    }
    return warnings;
}

/// The message a developer actually sees. Every finding gets three lines:
/// where it is, what is wrong, and what to do about it.
fn render(
    comptime t: Topology,
    comptime denials: []const Report,
    comptime warning_count: usize,
) []const u8 {
    comptime var msg: []const u8 =
        "\n" ++
        "ANANKE: infrastructure rejected, nothing was built\n" ++
        "\n" ++
        "  topology  " ++ t.name ++ "\n" ++
        "  source    " ++ t.source ++ "\n" ++
        std.fmt.comptimePrint(
            "  verdict   {d} violation{s}{s}\n\n",
            .{
                denials.len,
                if (denials.len == 1) "" else "s",
                if (warning_count == 0)
                    ""
                else
                    std.fmt.comptimePrint(", {d} warning(s) not shown", .{warning_count}),
            },
        );

    inline for (denials, 0..) |r, i| {
        msg = msg ++ std.fmt.comptimePrint("  [{d}/{d}] ", .{ i + 1, denials.len }) ++
            r.policy ++ "\n" ++
            "        rule   " ++ r.title ++ "\n" ++
            "        where  " ++ r.finding.subject ++ "\n" ++
            "        what   " ++ r.finding.message ++ "\n";
        if (r.finding.fix.len != 0) {
            msg = msg ++ "        fix    " ++ r.finding.fix ++ "\n";
        }
        msg = msg ++ "\n";
    }

    return msg ++
        "  No binary was produced and no config was generated.\n" ++
        "  Fix the topology above and the build turns green.\n";
}

/// Verification without the halt: hand back every report for a tool that wants
/// to display them rather than enforce them.
pub fn audit(comptime t: Topology, comptime policy_set: []const type) []const Report {
    return policy.audit(t, policy_set);
}

/// The default policy set, re-exported so callers of `verify` need only this
/// one import.
pub const default_policies = policies.defaults;
