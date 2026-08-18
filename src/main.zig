//! The demo binary.
//!
//! Everything it prints was decided while it was being compiled. `emit` does
//! not render config, it copies string constants to disk; `serve` does not
//! read a port from anywhere, it binds a number the policy pass approved.

const std = @import("std");
const ananke = @import("ananke");
const infra = @import("infra.zig");

const Io = std.Io;
const plan = infra.plan;

const usage =
    \\ananke -- compiler-enforced infrastructure
    \\
    \\usage: ananke <command> [args]
    \\
    \\  plan             show the verified topology and any warnings
    \\  emit [dir]       write the generated config (default: generated/)
    \\  show <artifact>  print one artifact: compose | nginx | dot | doc
    \\  serve [--once]   bind this service's verified ports and answer HTTP
    \\  help             this text
    \\
    \\Every command is a view onto one value: the topology in src/infra.zig.
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_file: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file.interface;

    const args = try init.minimal.args.toSlice(arena);
    const command = if (args.len > 1) args[1] else "plan";
    const rest = if (args.len > 2) args[2..] else &[_][:0]u8{};

    if (eq(command, "plan")) {
        try showPlan(out);
    } else if (eq(command, "emit")) {
        try emit(io, out, arena, if (rest.len > 0) rest[0] else "generated");
    } else if (eq(command, "show")) {
        if (rest.len == 0) {
            try out.writeAll("show what? one of: compose | nginx | dot | doc\n");
        } else {
            try show(out, rest[0]);
        }
    } else if (eq(command, "serve")) {
        try out.flush();
        try serve(io, out, arena, rest.len > 0 and eq(rest[0], "--once"));
    } else if (eq(command, "help") or eq(command, "-h") or eq(command, "--help")) {
        try out.writeAll(usage);
    } else {
        try out.print("unknown command '{s}'\n\n{s}", .{ command, usage });
    }

    try out.flush();
}

fn showPlan(out: *Io.Writer) !void {
    try out.writeAll("\n" ++ plan.summary);
    try out.print("\n  {d} artifact(s) the compiler is ready to write:\n", .{plan.artifacts.len});
    for (plan.artifacts) |a| {
        try out.print("    {s: <22} {d: >6} bytes  {s}\n", .{ a.path, a.contents.len, a.description });
    }

    if (plan.warnings.len == 0) {
        try out.writeAll("\n  No warnings. Everything the policies had to say, they said at compile time.\n");
    } else {
        try out.print("\n  {d} warning(s) -- not enough to stop the build, worth a look:\n\n", .{plan.warnings.len});
        for (plan.warnings) |w| {
            try out.print("    {s}\n      where  {s}\n      what   {s}\n", .{
                w.policy,
                w.finding.subject,
                w.finding.message,
            });
            if (w.finding.fix.len != 0) try out.print("      fix    {s}\n", .{w.finding.fix});
            try out.writeAll("\n");
        }
    }

    // These would not compile if the link had been removed from the topology.
    const db = plan.endpoint("api", "db", "sql");
    const queue = plan.endpoint("api", "queue", "amqp");
    try out.print(
        "  Connections 'api' is allowed to open, resolved at compile time:\n" ++
            "    {s}:{d} ({s})\n    {s}:{d} ({s})\n",
        .{ db.host, db.port, @tagName(db.proto), queue.host, queue.port, @tagName(queue.proto) },
    );
    try out.writeAll(
        \\
        \\  Try `plan.endpoint("gateway", "db", "sql")` in src/main.zig: there is no
        \\  such link, so it is a compile error rather than a runtime surprise.
        \\
    );
}

fn emit(io: Io, out: *Io.Writer, arena: std.mem.Allocator, dir_path: []const u8) !void {
    const cwd: std.Io.Dir = .cwd();
    try cwd.createDirPath(io, dir_path);

    try out.print("writing {d} artifact(s) to {s}/\n", .{ plan.artifacts.len, dir_path });
    for (plan.artifacts) |a| {
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, a.path });
        try cwd.writeFile(io, .{ .sub_path = path, .data = a.contents });
        try out.print("  {s: <34} {d: >6} bytes\n", .{ path, a.contents.len });
    }
    try out.writeAll(
        \\
        \\Nothing was rendered just now: these bytes were assembled while this
        \\binary was compiled, and this command copied them to disk.
        \\
    );
}

fn show(out: *Io.Writer, what: []const u8) !void {
    if (eq(what, "compose")) return out.writeAll(plan.compose_yaml);
    if (eq(what, "nginx")) return out.writeAll(plan.nginx_conf);
    if (eq(what, "dot")) return out.writeAll(plan.graph_dot);
    if (eq(what, "doc")) return out.writeAll(plan.doc_md);
    try out.print("unknown artifact '{s}'; try: compose | nginx | dot | doc\n", .{what});
}

/// Bind the ports the compiler approved for this service.
///
/// Note what is missing: no config file is read, no port is parsed, no range
/// is validated. `Listeners` is sized and numbered from the topology.
fn serve(io: Io, out: *Io.Writer, arena: std.mem.Allocator, once: bool) !void {
    const Gateway = plan.Listeners("gateway");

    var listeners = try Gateway.open(io, .{ 127, 0, 0, 1 });
    defer listeners.close(io);

    for (Gateway.ports) |p| {
        try out.print("listening on 127.0.0.1:{d}  ({s}, {s})\n", .{ p.number, p.name, @tagName(p.proto) });
    }
    try out.writeAll("press ctrl-c to stop\n");
    try out.flush();

    const body = try std.fmt.allocPrint(arena, "{s}\n{s}", .{ plan.summary, plan.doc_md });
    const response = try std.fmt.allocPrint(
        arena,
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\n" ++
            "Content-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ body.len, body },
    );

    const server = listeners.get("metrics");
    while (true) {
        var stream = try server.accept(io);
        defer stream.close(io);

        var write_buffer: [4096]u8 = undefined;
        var stream_writer = stream.writer(io, &write_buffer);
        stream_writer.interface.writeAll(response) catch {};
        stream_writer.interface.flush() catch {};

        try out.writeAll("served one request\n");
        try out.flush();
        if (once) break;
    }
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test "the demo topology passes its own policies" {
    // Reaching this line at all means verification succeeded: `plan` cannot
    // exist otherwise.
    try std.testing.expect(plan.topology.services.len == 7);
    try std.testing.expect(plan.compose_yaml.len > 0);
    try std.testing.expectEqual(@as(u16, 5432), plan.port("db", "sql"));
}

test "endpoints resolve to the linked service" {
    const e = plan.endpoint("api", "cache", "redis");
    try std.testing.expectEqualStrings("cache", e.host);
    try std.testing.expectEqual(@as(u16, 6379), e.port);
}
