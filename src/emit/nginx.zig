//! nginx generator.
//!
//! Routes are not configured here; they are read out of the link graph. A
//! `location` block exists if and only if a link exists, which means the
//! reverse proxy cannot be talked into forwarding somewhere the policies
//! refused to allow.

const std = @import("std");
const schema = @import("../schema.zig");
const text = @import("text.zig");

const Topology = schema.Topology;
const Service = schema.Service;
const Port = schema.Port;

pub fn render(comptime t: Topology) []const u8 {
    @setEvalBranchQuota(200_000);
    comptime var out: []const u8 = text.banner("#", t.name, t.source) ++ "\n";

    const edges = comptime edgeServices(t);
    if (edges.len == 0) {
        return out ++ "# This topology has no internet-facing HTTP listener, so there is\n" ++
            "# nothing for nginx to do.\n";
    }

    // An upstream exists only where a link points at it. A port nobody is
    // allowed to reach does not get a name in the proxy's config.
    inline for (t.services) |s| {
        inline for (s.ports) |p| {
            if (!p.proto.isHttpish()) continue;
            if (!isLinkTarget(t, s, p)) continue;
            out = out ++ "upstream " ++ upstreamName(s, p) ++ " {\n" ++
                std.fmt.comptimePrint("    server {s}:{d};\n", .{ s.name, p.number }) ++
                "}\n\n";
        }
    }

    inline for (edges) |edge| {
        inline for (edge.ports) |p| {
            if (p.expose != .public or !p.proto.isHttpish()) continue;
            out = out ++ server(t, edge, p);
        }
    }
    return out;
}

fn server(comptime t: Topology, comptime edge: Service, comptime p: Port) []const u8 {
    comptime var out: []const u8 = "server {\n" ++
        std.fmt.comptimePrint("    listen {d}{s};\n", .{ p.number, if (p.isEncrypted()) " ssl" else "" }) ++
        "    server_name _;\n";

    if (p.isEncrypted()) {
        out = out ++ "    ssl_certificate     /etc/ssl/certs/" ++ edge.name ++ ".crt;\n" ++
            "    ssl_certificate_key /etc/ssl/private/" ++ edge.name ++ ".key;\n" ++
            "    ssl_protocols       TLSv1.2 TLSv1.3;\n";
    }
    out = out ++ "\n";

    comptime var routes = 0;
    inline for (t.links) |l| {
        if (!std.mem.eql(u8, l.from, edge.name)) continue;
        const target = t.find(l.to) orelse continue;
        const tp = target.port(l.port) orelse continue;
        if (!tp.proto.isHttpish()) continue;
        routes += 1;
        if (l.note.len != 0) out = out ++ "    # " ++ l.note ++ "\n";
        out = out ++ "    location /" ++ target.name ++ "/ {\n" ++
            "        proxy_pass http://" ++ upstreamName(target, tp) ++ "/;\n" ++
            "        proxy_set_header Host              $host;\n" ++
            "        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;\n" ++
            "        proxy_set_header X-Forwarded-Proto $scheme;\n" ++
            "    }\n\n";
    }

    if (routes == 0) {
        out = out ++ "    # No links leave this service, so it proxies nowhere.\n";
    }
    out = out ++ "    location / {\n        return 404;\n    }\n";
    return out ++ "}\n\n";
}

fn upstreamName(comptime s: Service, comptime p: Port) []const u8 {
    comptime var out: []const u8 = "";
    inline for (s.name) |c| out = out ++ [_]u8{if (c == '-') '_' else c};
    out = out ++ "_";
    inline for (p.name) |c| out = out ++ [_]u8{if (c == '-') '_' else c};
    return out;
}

fn isLinkTarget(comptime t: Topology, comptime s: Service, comptime p: schema.Port) bool {
    inline for (t.links) |l| {
        if (std.mem.eql(u8, l.to, s.name) and std.mem.eql(u8, l.port, p.name)) return true;
    }
    return false;
}

fn edgeServices(comptime t: Topology) []const Service {
    comptime var out: []const Service = &.{};
    inline for (t.services) |s| {
        inline for (s.ports) |p| {
            if (p.expose == .public and p.proto.isHttpish()) {
                out = out ++ [_]Service{s};
                break;
            }
        }
    }
    return out;
}
