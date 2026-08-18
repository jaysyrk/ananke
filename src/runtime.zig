//! The run-time phase: the only code in this project that ends up in the
//! binary.
//!
//! It is deliberately thin. Every port number here is a compile-time constant
//! that survived the policy pass, so there is nothing left to validate -- no
//! config parsing, no environment lookups, no "port must be between 1 and
//! 65535" check at startup. The checks already happened, in the compiler.

const std = @import("std");
const schema = @import("schema.zig");

const Io = std.Io;
const net = std.Io.net;
const Topology = schema.Topology;
const Port = schema.Port;

/// A set of listening sockets for one service's published, connection-oriented
/// ports. UDP ports are skipped: they are bound rather than listened on, and
/// pretending otherwise would hide the difference.
///
/// The array is exactly as long as that set, decided while compiling. There is
/// no growth, no allocator and no failure mode where the program listens on a
/// port nobody verified.
pub fn Listeners(comptime t: Topology, comptime service_name: []const u8) type {
    const svc = comptime t.find(service_name) orelse @compileError(
        "ananke: '" ++ service_name ++ "' is not a service in topology '" ++ t.name ++ "'",
    );

    const bindable = comptime blk: {
        var out: []const Port = &.{};
        for (svc.ports) |p| {
            if (p.isPublished() and p.proto != .udp) out = out ++ [_]Port{p};
        }
        break :blk out;
    };

    return struct {
        const Self = @This();

        servers: [bindable.len]net.Server,

        /// The ports this type binds, in the order `servers` holds them.
        pub const ports: []const Port = bindable;
        pub const service = svc;

        pub const OpenError = net.IpAddress.ListenError;

        /// Bind every published port of the service on `address`'s host part.
        ///
        /// On failure, sockets already opened are closed before returning, so
        /// a partially bound service is not a state this can leave you in.
        pub fn open(io: Io, host: [4]u8) OpenError!Self {
            var self: Self = .{ .servers = undefined };
            var opened: usize = 0;
            errdefer for (self.servers[0..opened]) |*s| s.deinit(io);

            inline for (bindable, 0..) |p, i| {
                const addr: net.IpAddress = .{ .ip4 = .{ .bytes = host, .port = p.number } };
                self.servers[i] = try addr.listen(io, .{ .reuse_address = true });
                opened += 1;
            }
            return self;
        }

        pub fn close(self: *Self, io: Io) void {
            for (&self.servers) |*s| s.deinit(io);
        }

        /// The socket bound to a named port. Naming a port the service does
        /// not publish is a compile error.
        pub fn get(self: *Self, comptime port_name: []const u8) *net.Server {
            const index = comptime blk: {
                for (bindable, 0..) |p, i| {
                    if (std.mem.eql(u8, p.name, port_name)) break :blk i;
                }
                @compileError(
                    "ananke: '" ++ service_name ++ "' publishes no port named '" ++ port_name ++ "'",
                );
            };
            return &self.servers[index];
        }
    };
}
