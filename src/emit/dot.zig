//! Graphviz generator: the topology as a picture, clustered by trust tier.
//!
//! `zig build emit && dot -Tsvg generated/topology.dot -o topology.svg`

const std = @import("std");
const schema = @import("../schema.zig");
const text = @import("text.zig");

const Topology = schema.Topology;
const Zone = schema.Zone;

const zone_fill = [_][]const u8{ "#fde7e7", "#fff4e0", "#e8f1fd", "#e9f6ec" };

pub fn render(comptime t: Topology) []const u8 {
    @setEvalBranchQuota(200_000);
    comptime var out: []const u8 = text.banner("//", t.name, t.source) ++
        "\ndigraph " ++ identifier(t.name) ++ " {\n" ++
        "    rankdir = TB;\n" ++
        "    node [shape=box style=\"rounded,filled\" fontname=\"Inter,sans-serif\" fillcolor=white];\n" ++
        "    edge [fontname=\"Inter,sans-serif\" fontsize=9];\n\n";

    inline for (@typeInfo(Zone).@"enum".fields) |f| {
        const zone: Zone = @enumFromInt(f.value);
        comptime var body: []const u8 = "";
        inline for (t.services) |s| {
            if (s.zone != zone) continue;
            comptime var label: []const u8 = s.name;
            inline for (s.ports) |p| {
                label = label ++ std.fmt.comptimePrint("\\n{s} {d}/{s}", .{ p.name, p.number, p.proto.tag() });
            }
            body = body ++ "    \"" ++ s.name ++ "\" [label=\"" ++ label ++ "\"];\n";
        }
        if (body.len == 0) continue;
        out = out ++ "    subgraph cluster_" ++ f.name ++ " {\n" ++
            "        label = \"" ++ f.name ++ "\";\n" ++
            "        style = filled;\n" ++
            "        color = \"" ++ zone_fill[f.value] ++ "\";\n" ++
            text.indent(body, 4) ++
            "    }\n\n";
    }

    inline for (t.links) |l| {
        out = out ++ "    \"" ++ l.from ++ "\" -> \"" ++ l.to ++ "\" [label=\"" ++ l.port ++ "\"];\n";
    }
    return out ++ "}\n";
}

fn identifier(comptime s: []const u8) []const u8 {
    comptime var out: []const u8 = "";
    inline for (s) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9');
        out = out ++ [_]u8{if (ok) c else '_'};
    }
    return out;
}
