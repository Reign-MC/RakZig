const std = @import("std");
const Thread = std.Thread;
const Mutex = Thread.Mutex;

const BinaryUtils = @import("BinaryUtils");
const Writer = BinaryUtils.BinaryWriter;

const Socket = @import("../socket/mod.zig").Socket;
const Protocol = @import("../protocol/mod.zig");
const ID = Protocol.ID;
const Messages = Protocol.Messages;

const Connection = @import("connection.zig").Connection;

pub const Options = struct {
    protocolVersion: u8 = 11,
    address: []const u8 = "0.0.0.0",
    port: u16 = 19132,
    tickRate: u16 = 20,
    advertisement: []const u8 = "",
    timeout: i64 = 10_000,
    maxConnections: usize = 20,
};

pub const Server = struct {
    options: Options,
    socket: Socket,
    guid: u64,
    running: bool,
    // tickThread: ?Thread,
    connections: std.AutoHashMap(u64, Connection),
    // connectionsMutex: Mutex,
    allocator: std.mem.Allocator,
    connectCb: ?*const fn (*Connection, ?*anyopaque) void = null,
    connectCtx: ?*anyopaque = null,
    disconnectCb: ?*const fn (*Connection, ?*anyopaque) void = null,
    disconnectCtx: ?*anyopaque = null,

    pub fn init(options: Options, allocator: std.mem.Allocator) !Server {
        return .{
            .options = options,
            .socket = try Socket.init(options.address, options.port),
            .running = false,
            .guid = 0x123456789,
            // .tickThread = null,
            .connections = std.AutoHashMap(u64, Connection).init(allocator),
            // .connectionsMutex = Mutex{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Server) void {
        var iter = self.connections.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.connections.deinit();
    }

    fn tick(self: *Server) void {
        // while (self.running) {
        // const startTime = std.time.nanotime();
        var conns = self.allocator.alloc(*Connection, self.options.maxConnections) catch |err| {
            std.debug.print("Error ticking server: {any}\n", .{err});
            return;
        };
        defer self.allocator.free(conns);
        var count: usize = 0;
        var toRemove = self.allocator.alloc(u64, self.options.maxConnections) catch |err| {
            std.debug.print("Error ticking server: {any}\n", .{err});
            return;
        };
        defer self.allocator.free(toRemove);
        var removeCount: usize = 0;

        // self.connectionsMutex.lock();
        var iter = self.connections.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.*.active) {
                if (count < conns.len) {
                    conns[count] = entry.value_ptr;
                    count += 1;
                }
            } else {
                toRemove[removeCount] = entry.key_ptr.*;
                removeCount += 1;
            }
        }
        // self.connectionsMutex.unlock();

        for (conns[0..count]) |conn| {
            conn.tick();
        }

        // self.connectionsMutex.lock();
        for (toRemove[0..removeCount]) |key| {
            if (self.connections.getPtr(key)) |conn| {
                conn.deinit();
                _ = self.connections.remove(key);
            }
        }
        // self.connectionsMutex.unlock();

        // const elapsed = std.time.nanotime() - startTime;
        // if (elapsed < tickNs) {
        // std.Thread.sleep(tickNs - elapsed);
        // }
        // }
    }

    pub fn start(self: *Server) !void {
        self.running = true;
        // Not needed anymore
        // self.tickThread = try Thread.spawn(.{}, tick, .{self});
    }

    fn processIncomingPackets(self: *Server, buffer: []u8) !bool {
        var hasRead = false;

        while (true) {
            const recvOpt = self.socket.receiveFrom(buffer) catch break;
            if (recvOpt == null) break;

            hasRead = true;

            const recvResult = recvOpt.?;
            const packetData = buffer[0..recvResult.len];
            const addrKey = hashAddress(recvResult.addr);

            var rawId: u8 = packetData[0];
            if (rawId & 0xF0 == 0x80) rawId = 0x80;

            const tempId = ID.fromU8(rawId);
            if (tempId == null) {
                std.debug.print("Unknown packetId: {d}", .{rawId});
                continue;
            }

            const packetId = tempId.?;

            var connPtr: ?*Connection = null;
            // self.connectionsMutex.lock();
            connPtr = self.connections.getPtr(addrKey);
            // self.connectionsMutex.unlock();

            switch (packetId) {
                ID.UnconnectedPing => {
                    var buf: [1500]u8 = undefined;
                    var writer = Writer.init(buf[0..]);

                    var pong = Messages.UnconnectedPong.init(std.time.milliTimestamp(), self.guid, self.options.advertisement);
                    const pongData = pong.serialize(&writer) catch |err| {
                        std.debug.print("Serialize error: {any}\n", .{err});
                        continue;
                    };

                    self.send(pongData, recvResult.addr);
                },
                ID.OpenConnectionRequest1 => {
                    var buf: [1500]u8 = undefined;
                    const request = Messages.ConnectionRequest1.deserialize(packetData) catch {
                        return hasRead;
                    };

                    if (request.protocol != self.options.protocolVersion) {
                        std.debug.print("Protocol mismatch: {d} != {d}\n", .{ request.protocol, self.options.protocolVersion });
                        var writer = Writer.init(buf[0..]);

                        var incompatible = Messages.IncompatibleProtocolVersion.init(self.options.protocolVersion, self.guid);
                        const incompatibleData = incompatible.serialize(&writer) catch {
                            return hasRead;
                        };

                        self.send(incompatibleData, recvResult.addr);
                        return hasRead;
                    }

                    var reply = Messages.ConnectionReply1.init(self.guid, false, 0, 1492);
                    const replyData = reply.serialize() catch |err| {
                        std.debug.print("Serialize error: {any}\n", .{err});
                        continue;
                    };
                    self.send(replyData, recvResult.addr);
                },
                ID.OpenConnectionRequest2 => {
                    const request = Messages.ConnectionRequest2.deserialize(packetData) catch |err| {
                        std.debug.print("Deserialize error: {any}\n", .{err});
                        continue;
                    };

                    const address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
                    var reply = Messages.ConnectionReply2.init(self.guid, address, request.mtuSize, false);
                    const replyData = reply.serialize() catch |err| {
                        std.debug.print("Serialize error: {any}\n", .{err});
                        continue;
                    };
                    self.send(replyData, recvResult.addr);

                    if (connPtr == null) {
                        // self.connectionsMutex.lock();
                        if (!self.connections.contains(addrKey)) {
                            const connection = Connection.init(self, recvResult.addr, request.mtuSize, request.clientGUID) catch |err| {
                                std.debug.print("Connection init error: {any}\n", .{err});
                                self.connectionsMutex.unlock();
                                continue;
                            };
                            try self.connections.put(addrKey, connection);
                        }
                        // self.connectionsMutex.unlock();
                    }
                },
                ID.FrameSet => {
                    if (connPtr) |conn| {
                        conn.handleFrameSet(packetData) catch |err| {
                            std.debug.print("FrameSet error: {any}\n", .{err});
                        };
                    }
                },
                ID.ACK => {
                    if (connPtr) |conn| {
                        conn.handleAck(packetData) catch |err| {
                            std.debug.print("ACK error: {any}\n", .{err});
                        };
                    }
                },
                ID.NACK => {
                    if (connPtr) |conn| {
                        conn.handleNack(packetData) catch |err| {
                            std.debug.print("ACK error: {any}\n", .{err});
                        };
                    }
                },
                else => {
                    std.debug.print("Unhandled packet: {any}\n", .{packetId});
                },
            }
        }

        return hasRead;
    }

    pub fn listen(self: *Server) !void {
        // Could be smaller but just incase of weird large fragmented packets
        var buffer: [4096]u8 = undefined;

        const tickNs = @as(u64, std.time.ns_per_s) / @as(u64, self.options.tickRate);
        while (true) {
            const startTime = std.time.nanoTimestamp();

            const hadPackets = self.processIncomingPackets(buffer[0..]) catch false;
            if (!hadPackets) {
                // not needed unless we do multi threading
                // std.Thread.sleep(1 * std.time.ns_per_ms);
            }

            self.tick();

            const elapsed = std.time.nanoTimestamp() - startTime;
            if (elapsed < @as(i128, tickNs)) {
                std.Thread.sleep(tickNs - @as(u64, @intCast(elapsed)));
            }
        }
    }

    pub fn send(self: *Server, payload: []const u8, addr: std.net.Address) void {
        self.socket.sendTo(payload, addr) catch |err| {
            std.debug.print("Failed to send: {any}", .{err});
            return;
        };
    }

    pub fn hashAddress(address: std.net.Address) u64 {
        return switch (address.any.family) {
            std.posix.AF.INET => {
                const ip = @as(u32, address.in.sa.addr);
                const port = @as(u32, address.in.sa.port);
                return (@as(u64, port) << 32) | @as(u64, ip);
            },
            std.posix.AF.INET6 => {
                var hash: u64 = 0xcbf29ce484222325;
                for (address.in6.sa.addr) |b| {
                    hash ^= @as(u64, b);
                    hash *= 0x100000001b3;
                }
                hash ^= @as(u64, address.in6.sa.port);
                hash *= 0x100000001b3;
                return hash;
            },
            else => 0,
        };
    }

    pub fn onConnect(self: *Server, cb: *const fn (*Connection, ?*anyopaque) void, ctx: ?*anyopaque) void {
        self.connectCb = cb;
        self.connectCtx = ctx;
    }

    pub fn onDisconnect(self: *Server, cb: *const fn (*Connection, ?*anyopaque) void, ctx: ?*anyopaque) void {
        self.disconnectCb = cb;
        self.disconnectCtx = ctx;
    }
};
