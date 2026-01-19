const std = @import("std");
const Thread = std.Thread;
const Mutex = Thread.Mutex;

const Socket = @import("../socket/mod.zig").Socket;
const Protocol = @import("../protocol/mod.zig");
const ID = Protocol.ID;
const Messages = Protocol.Messages;

const Connection = @import("connection.zig").Connection;

pub const Options = struct {
    address: []const u8 = "0.0.0.0",
    port: u16 = 19132,
    tickRate: u16 = 20,
    maxConnections: i64 = 20,
};

pub const Server = struct {
    options: Options,
    socket: Socket,
    guid: u64,
    running: bool,
    tickThread: ?Thread,
    connections: std.AutoHashMap(u64, Connection),
    connectionsMutex: Mutex,
    allocator: std.mem.Allocator,
    connectCb: ?*const fn (*Connection) void = null,
    disconnectCb: ?*const fn (*Connection) void = null,
    packetCb: ?*const fn (*Connection, []const u8) void = null,

    pub fn init(options: Options, allocator: std.mem.Allocator) !Server {
        return .{
            .options = options,
            .socket = try Socket.init(options.address, options.port),
            .running = false,
            .guid = 0x123456789,
            .tickThread = null,
            .connections = std.AutoHashMap(u64, Connection).init(allocator),
            .connectionsMutex = Mutex{},
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
        while (self.running) {
            self.connectionsMutex.lock();

            var toRemove = self.allocator.alloc(u64, @intCast(self.options.maxConnections)) catch |err| {
                std.debug.print("Error allocating toRemove: {any}\n", .{err});
                continue;
            };
            defer self.allocator.free(toRemove);

            var removeCount: usize = 0;

            {
                var iter = self.connections.iterator();
                while (iter.next()) |entry| {
                    if (entry.value_ptr.active) {
                        entry.value_ptr.tick();
                    } else if (removeCount < toRemove.len) {
                        toRemove[removeCount] = @intCast(entry.key_ptr.*);
                        removeCount += 1;
                    }
                }
            }

            for (toRemove[0..removeCount]) |key| {
                if (self.connections.getPtr(key)) |conn| {
                    conn.deinit();
                    _ = self.connections.remove(key);
                }
            }

            self.connectionsMutex.unlock();

            std.Thread.sleep(std.time.ns_per_s / @as(u64, self.options.tickRate));
        }
    }

    pub fn start(self: *Server) !void {
        self.running = true;
        self.tickThread = try Thread.spawn(.{}, tick, .{self});
    }

    fn processIncomingPackets(self: *Server, buffer: []u8) !void {
        while (true) {
            const recvOpt = self.socket.receiveFrom(buffer) catch break;
            if (recvOpt == null) break;

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

            switch (packetId) {
                ID.OpenConnectionRequest1 => {
                    var reply = Messages.ConnectionReply1.init(self.guid, false, 0, 1492);

                    const replyData = reply.serialize() catch |err| {
                        std.debug.print("Error trying to serialize connection reply 1: {any}", .{err});
                        return;
                    };

                    self.send(replyData, recvResult.addr);
                },
                ID.OpenConnectionRequest2 => {
                    const request = Messages.ConnectionRequest2.deserialize(packetData) catch |err| {
                        std.debug.print("Error trying to deserializing connection request 2: {any}", .{err});
                        return;
                    };

                    const address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);

                    var reply = Messages.ConnectionReply2.init(self.guid, address, request.mtuSize, false);

                    const replyData = reply.serialize() catch |err| {
                        std.debug.print("Error trying to serialize connection reply 2: {any}", .{err});
                        return;
                    };

                    self.send(replyData, recvResult.addr);

                    self.connectionsMutex.lock();
                    defer self.connectionsMutex.unlock();

                    if (self.connections.contains(addrKey)) {
                        std.debug.print("Connection already made\n", .{});
                        return;
                    }

                    const connection = Connection.init(self, recvResult.addr, request.mtuSize, request.clientGUID) catch |err| {
                        std.debug.print("Error creating connection: {any}\n", .{err});
                        return;
                    };

                    try self.connections.put(addrKey, connection);
                },
                ID.FrameSet => {
                    self.connectionsMutex.lock();
                    defer self.connectionsMutex.unlock();

                    if (self.connections.getPtr(addrKey)) |conn| {
                        conn.handleFrameSet(packetData) catch |err| {
                            std.debug.print("Error handling frameset: {any}\n", .{err});
                            return;
                        };
                    }
                },
                ID.ACK => {
                    self.connectionsMutex.lock();
                    defer self.connectionsMutex.unlock();

                    if (self.connections.getPtr(addrKey)) |conn| {
                        conn.handleAck(packetData) catch |err| {
                            std.debug.print("Error handling ack: {any}\n", .{err});
                            return;
                        };
                    }
                },
                else => {
                    std.debug.print("Unhandled packet: {any}\n", .{packetId});
                },
            }
        }
    }

    pub fn listen(self: *Server) !void {
        var buffer: [1500]u8 = undefined;
        while (true) {
            self.processIncomingPackets(buffer[0..]) catch |err| {
                std.debug.print("Caught error while trying to process packets {any}.", .{err});
                continue;
            };
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

    pub fn onConnect(self: *Server, cb: *const fn (*Connection) void) void {
        self.connectCb = cb;
    }

    pub fn onDisconnect(self: *Server, cb: *const fn (*Connection) void) void {
        self.disconnectCb = cb;
    }

    pub fn onPacket(self: *Server, cb: *const fn (*Connection, []const u8) void) void {
        self.packetCb = cb;
    }
};
