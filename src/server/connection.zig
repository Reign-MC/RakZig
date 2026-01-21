const std = @import("std");

const BinaryUtils = @import("BinaryUtils");
const Writer = BinaryUtils.BinaryWriter;
const Reader = BinaryUtils.BinaryReader;

const Server = @import("server.zig").Server;

const Protocol = @import("../protocol/mod.zig");
const Messages = Protocol.Messages;
const Frame = Protocol.Frame;
const ID = Protocol.ID;
const Constants = Protocol.Constants;
const Priority = Protocol.Priority;

pub const Connection = struct {
    server: *Server,
    address: std.net.Address,
    key: u64,
    mtuSize: u16,
    guid: u64,
    connected: bool,
    active: bool,
    state: ConnectionState,
    lastReceive: i64,
    gamePacketCb: ?*const fn (*Connection, []const u8, ?*anyopaque) void = null,
    gamePacketCtx: ?*anyopaque = null,
    lastPing: u64 = 0,
    pingInterval: u64 = 5000,

    pub fn init(server: *Server, address: std.net.Address, mtuSize: u16, guid: u64) !Connection {
        return .{
            .server = server,
            .address = address,
            .key = Server.hashAddress(address),
            .mtuSize = mtuSize,
            .guid = guid,
            .state = try ConnectionState.init(server.allocator),
            .connected = false,
            .active = true,
            .lastReceive = std.time.milliTimestamp(),
        };
    }

    pub fn deinit(self: *Connection) void {
        self.state.deinit(self.server.allocator);
    }

    pub fn tick(self: *Connection) void {
        if (!self.active) return;

        if (self.lastReceive + self.server.options.timeout < std.time.milliTimestamp()) {
            self.active = false;

            if (self.server.disconnectCb) |callback| {
                callback(self, self.server.disconnectCtx);
            }
            return;
        }

        while (self.state.outputFrameQueue.items.len > 0) {
            const queueLen = self.state.outputFrameQueue.items.len;
            const beforeLen = queueLen;

            self.sendQueuedFrames(queueLen);
            if (self.state.outputFrameQueue.items.len >= beforeLen) break;
        }

        if (self.state.receivedSequences.count() > 0) {
            var sequences = std.ArrayList(u24).initBuffer(&[_]u24{});
            defer sequences.deinit(self.server.allocator);

            var iter = self.state.receivedSequences.keyIterator();
            while (iter.next()) |key| {
                sequences.append(self.server.allocator, key.*) catch continue;
            }
            self.state.receivedSequences.clearRetainingCapacity();
            if (sequences.items.len == 0) return;

            var ack = Messages.Ack.init(sequences.items);

            var buffer: [1024]u8 = undefined;
            var writer = Writer.init(buffer[0..]);

            const serialized = ack.serialize(&writer) catch {
                return;
            };
            self.send(serialized);
        }

        if (self.state.lostSequences.count() > 0) {
            var sequences = std.ArrayList(u24).initBuffer(&[_]u24{});
            defer sequences.deinit(self.server.allocator);

            var iter = self.state.lostSequences.keyIterator();
            while (iter.next()) |key| {
                sequences.append(self.server.allocator, key.*) catch continue;
            }
            self.state.lostSequences.clearRetainingCapacity();
            if (sequences.items.len == 0) return;

            var nack = Messages.Ack.init(sequences.items);

            var buffer: [1024]u8 = undefined;
            var writer = Writer.init(buffer[0..]);

            // Should work if not change to .dupe
            buffer[0] = @intFromEnum(ID.NACK);

            const serialized = nack.serialize(&writer) catch {
                return;
            };
            self.send(serialized);
        }

        if (self.connected) {
            const currentTime = std.time.milliTimestamp();

            if (currentTime - @as(i64, @intCast(self.lastPing)) >= self.pingInterval) {
                self.sendPing();
                self.lastPing = @intCast(currentTime);
            }
        }
    }

    pub fn handlePacket(self: *Connection, payload: []const u8) !void {
        if (payload.len == 0) {
            return;
        }

        const packetId: ID = ID.fromU8(payload[0]) orelse return;
        self.lastReceive = std.time.milliTimestamp();

        switch (packetId) {
            ID.ConnectedPing => {
                const ping = try Messages.ConnectedPing.deserialize(payload);

                var buffer = try self.server.allocator.alloc(u8, 128);
                defer self.server.allocator.free(buffer);

                var writer = Writer.init(buffer[0..]);
                var pong = Messages.ConnectedPong.init(ping.timestamp, std.time.milliTimestamp());
                const serialized = try pong.serialize(&writer);

                const frame = self.frameFromPayloadWithReliability(serialized, .Unreliable) catch |err| {
                    std.debug.print("Failed to alloc frame payload: {any}\n", .{err});
                    return;
                };
                self.sendFrame(frame, .Normal);
            },
            ID.ConnectedPong => {},
            ID.ConnectionRequest => {
                var buffer = try self.server.allocator.alloc(u8, 512);
                defer self.server.allocator.free(buffer);

                const request = try Messages.ConnectionRequest.deserialize(payload);
                const empty = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, self.server.options.port);

                var reply = Messages.ConnectionRequestAccepted.init(self.address, 0, empty, request.timestamp, std.time.milliTimestamp());
                const serialized = try reply.serialize(buffer[0..]);

                const frame = self.frameFromPayloadWithReliability(serialized, .Unreliable) catch |err| {
                    std.debug.print("Failed to alloc frame payload: {any}\n", .{err});
                    return;
                };
                self.sendFrame(frame, .Immediate);
            },
            ID.NewIncomingConnection => {
                self.connected = true;
                if (self.server.connectCb) |callback| {
                    callback(self, self.server.connectCtx);
                }
            },
            ID.GamePacket => {
                if (self.gamePacketCb) |callback| {
                    callback(self, payload, self.gamePacketCtx);
                }
            },
            ID.DisconnectNotification => {
                self.active = false;
                self.connected = false;

                if (self.server.disconnectCb) |callback| {
                    callback(self, self.server.disconnectCtx);
                }
            },
            else => {
                std.debug.print("Unhandled packet: {any}\n", .{packetId});
            },
        }
    }

    pub fn handleAck(self: *Connection, payload: []const u8) !void {
        if (!self.active) return;

        // Use allocator-backed parsing so we handle arbitrarily large ACKs.
        var ack = try Messages.Ack.deserializeAlloc(payload, self.server.allocator);
        defer ack.deinit(self.server.allocator);

        var i: usize = 0;
        while (i < ack.sequences.len) : (i += 1) {
            const sequence = ack.sequences[i];
            const key = @as(u24, @intCast(sequence));
            if (self.state.outputBackup.contains(key)) {
                if (self.state.outputBackup.get(key)) |*frames_ptr| {
                    const frames = frames_ptr.*;
                    var idx: usize = 0;
                    while (idx < frames.len) : (idx += 1) {
                        const fptr = &frames[idx];
                        if (fptr.shouldFree) fptr.deinit(self.server.allocator);
                    }
                    _ = self.state.outputBackup.remove(key);
                    self.server.allocator.free(frames);
                }
            }
        }
    }

    pub fn handleNack(self: *Connection, payload: []const u8) !void {
        if (!self.active) return;

        var nack = try Messages.Ack.deserializeAlloc(payload, self.server.allocator);
        defer nack.deinit(self.server.allocator);

        var buffer: [1500]u8 = undefined;

        for (nack.sequences) |seq| {
            const frames = self.state.outputBackup.get(seq);
            if (frames) |f| {
                var writer = Writer.init(buffer[0..]);

                var frameset = Messages.FrameSet.init(seq, f);
                const serialized = frameset.serialize(&writer) catch continue;
                self.send(serialized);
                frameset.deinit(self.server.allocator);
            }
        }
    }

    pub fn handleFrameSet(self: *Connection, payload: []const u8) !void {
        if (!self.active) return;

        self.lastReceive = std.time.milliTimestamp();

        var set = try Messages.FrameSet.deserialize(payload, self.server.allocator);
        defer set.deinit(self.server.allocator);

        const sequence = set.sequenceNumber;

        {
            const lastSeq = self.state.lastInputSequence;
            const receivedSeqs = self.state.receivedSequences;

            const isOldSequence = lastSeq != -1 and sequence <= @as(u24, @intCast(@max(0, lastSeq)));
            const alreadyReceived = receivedSeqs.contains(sequence);

            const isDuplicate = isOldSequence or alreadyReceived;
            if (isDuplicate) {
                return;
            }
        }

        self.state.receivedSequences.put(sequence, {}) catch {
            return;
        };
        _ = self.state.lostSequences.remove(sequence);

        const lastSeq = self.state.lastInputSequence;
        if (sequence > lastSeq + 1) {
            var i: i32 = lastSeq + 1;
            while (i < sequence) : (i += 1) {
                self.state.lostSequences.put(@intCast(i), {}) catch {};
            }
        }

        self.state.lastInputSequence = @intCast(sequence);
        for (set.frames) |*frameConst| {
            var frame: *Frame = @constCast(frameConst); // make it mutable
            if (frame.isSplit()) {
                frame.shouldFree = false;
            }
            try self.handleFrame(frame.*);
        }

        self.sendAck(sequence);
    }

    pub fn handleFrame(self: *Connection, frame: Frame) anyerror!void {
        if (!self.active) return;

        if (frame.payload.len == 0) {
            return;
        }

        const reliability = frame.reliability;

        if (frame.isSplit()) {
            try self.handleSplitFrame(frame);
        } else if (reliability.isSequenced()) {
            self.handleSequencedFrame(frame);
        } else if (reliability.isOrdered()) {
            self.handleOrderedFrame(frame);
        } else {
            try self.handlePacket(frame.payload);
        }
    }

    pub fn handleSequencedFrame(self: *Connection, frame: Frame) void {
        if (!self.active) return;

        const channel = frame.orderChannel orelse return;
        const frameIndex = frame.sequenceFrameIndex orelse return;
        const orderIndex = frame.orderedFrameIndex orelse return;

        const highest = self.state.inputHighestSequenceIndex[channel];
        if (frameIndex >= highest and orderIndex >= self.state.inputOrderIndex[channel]) {
            self.state.inputHighestSequenceIndex[channel] = frameIndex + 1;

            self.handlePacket(frame.payload) catch |err| {
                std.debug.print("Failed to handle packet: {any}\n", .{err});
                return;
            };
        }
    }

    pub fn handleOrderedFrame(self: *Connection, frame: Frame) void {
        if (!self.active) return;

        const channel = frame.orderChannel orelse return;
        const frameIndex = frame.orderedFrameIndex orelse return;

        if (frameIndex == self.state.inputOrderIndex[channel]) {
            self.state.inputHighestSequenceIndex[channel] = 0;
            self.state.inputOrderIndex[channel] = frameIndex + 1;

            self.handlePacket(frame.payload) catch {
                return;
            };

            var index = self.state.inputOrderIndex[channel];

            const outOfOrderQueuePtr = self.state.inputOrderingQueue.getPtr(channel);
            if (outOfOrderQueuePtr) |outOfOrderQueue| {
                while (true) {
                    const queuedFrame = outOfOrderQueue.get(index);
                    if (queuedFrame == null) break;

                    self.handlePacket(queuedFrame.?.payload) catch |err| {
                        std.debug.print("Error handling packet: {any}\n", .{err});
                        break;
                    };

                    _ = outOfOrderQueue.remove(index);
                    index += 1;
                }
            }

            self.state.inputOrderIndex[channel] = index;
        } else if (frameIndex > self.state.inputOrderIndex[channel]) {
            if (self.state.inputOrderingQueue.getPtr(channel)) |map| {
                map.put(frameIndex, frame) catch |err| {
                    std.debug.print("Failed to queue frame in ordering queue: {any}\n", .{err});
                };
            }
        } else {
            self.handlePacket(frame.payload) catch |err| {
                std.debug.print("Error handling packet: {any}\n", .{err});
            };
        }
    }

    pub fn handleSplitFrame(self: *Connection, frame: Frame) !void {
        const split = frame.splitInfo orelse {
            std.debug.print("Split frame missing split info\n", .{});
            return;
        };

        const splitID: u16 = split.id;
        const index: u16 = @intCast(split.frameIndex);
        const total: u16 = @intCast(split.size);

        const map_ptr = blk: {
            if (self.state.fragmentsQueue.getPtr(splitID)) |existing| {
                break :blk existing;
            }
            //
            const new_map = std.AutoHashMap(u16, Frame).init(self.server.allocator);
            try self.state.fragmentsQueue.put(splitID, new_map);
            break :blk self.state.fragmentsQueue.getPtr(splitID).?;
        };

        if (map_ptr.contains(index)) {
            return;
        }

        var owned = frame;
        owned.shouldFree = true;
        try map_ptr.put(index, owned);

        if (map_ptr.count() < total - 1) {
            return;
        }

        var merged_len: usize = 0;
        var i: u16 = 0;
        while (i < total) : (i += 1) {
            const frag = map_ptr.get(i) orelse {
                return;
            };
            merged_len += frag.payload.len;
        }

        var merged = try self.server.allocator.alloc(u8, merged_len);
        var pos: usize = 0;

        i = 0;
        while (i < total) : (i += 1) {
            const frag = map_ptr.get(i).?;
            std.mem.copyForwards(
                u8,
                merged[pos .. pos + frag.payload.len],
                frag.payload,
            );
            pos += frag.payload.len;

            // frag.deinit(self.server.allocator);
        }

        map_ptr.deinit();
        _ = self.state.fragmentsQueue.remove(splitID);

        try self.handleFrame(Frame{
            .payload = merged,
            .sequenceFrameIndex = frame.sequenceFrameIndex,
            .reliability = frame.reliability,
            .reliableFrameIndex = frame.reliableFrameIndex,
            .orderedFrameIndex = frame.orderedFrameIndex,
            .orderChannel = frame.orderChannel,
            .splitInfo = null,
            .shouldFree = true,
        });
    }

    pub fn frameFromPayload(self: *Connection, payload: []const u8) !Frame {
        const len = payload.len;
        const owned = try self.server.allocator.alloc(u8, len);
        std.mem.copyForwards(u8, owned, payload);
        return Frame.init(.ReliableOrdered, owned, 0, null, null, null, null, true);
    }

    pub fn frameFromPayloadWithReliability(self: *Connection, payload: []const u8, reliability: Protocol.Reliability) !Frame {
        const len = payload.len;
        const owned = try self.server.allocator.alloc(u8, len);
        std.mem.copyForwards(u8, owned, payload);
        return Frame.init(reliability, owned, 0, null, null, null, null, true);
    }

    pub fn sendFrame(self: *Connection, frame: Frame, priority: Priority) void {
        if (!self.active) {
            return;
        }

        const channelIndex = frame.orderChannel orelse 0;
        const channel = @as(usize, channelIndex);
        var mutableFrame = frame;

        const reliability = mutableFrame.reliability;

        if (reliability.isSequenced()) {
            mutableFrame.orderedFrameIndex = self.state.outputOrderIndex[channel];
            mutableFrame.sequenceFrameIndex = self.state.outputSequenceIndex[channel];
            self.state.outputSequenceIndex[channel] += 1;
        } else if (reliability.isOrdered()) {
            mutableFrame.orderedFrameIndex = self.state.outputOrderIndex[channel];
            self.state.outputOrderIndex[channel] += 1;
            self.state.outputSequenceIndex[channel] = 0;
        }

        const payloadSize = mutableFrame.payload.len;
        const maxSize = self.mtuSize - 36;

        if (payloadSize <= maxSize) {
            if (reliability.isReliable()) {
                mutableFrame.reliableFrameIndex = self.state.outputReliableIndex;
                self.state.outputReliableIndex += 1;
            }
            self.enqueueFrame(&mutableFrame, priority);

            return;
        } else {
            const splitSize = (payloadSize + maxSize - 1) / maxSize;
            self.handleLargePayload(&mutableFrame, maxSize, splitSize, priority);
        }
    }

    pub fn handleLargePayload(self: *Connection, frame: *Frame, maxSize: usize, splitSize: usize, priority: Priority) void {
        const splitID = self.state.outputSplitIndex;
        self.state.outputSplitIndex = (self.state.outputSplitIndex +% 1);

        const originalPayload = frame.payload;

        var i: usize = 0;
        while (i < originalPayload.len) {
            const end = @min(i + maxSize, originalPayload.len);
            const fragmentPayload = originalPayload[i..end];

            const copy = fragmentPayload;

            var newFrame: Frame = undefined;
            if (frame.shouldFree) {
                const frag_len = fragmentPayload.len;
                const owned_frag = self.server.allocator.alloc(u8, frag_len) catch {
                    return;
                };
                std.mem.copyForwards(u8, owned_frag, fragmentPayload);
                newFrame = Frame.init(frame.reliability, owned_frag, frame.orderChannel, frame.reliableFrameIndex, frame.sequenceFrameIndex, frame.orderedFrameIndex, .{
                    .id = splitID,
                    .size = @as(u32, @intCast(splitSize)),
                    .frameIndex = @as(u32, @intCast(i / maxSize)),
                }, true);
            } else {
                newFrame = Frame.init(frame.reliability, copy, frame.orderChannel, frame.reliableFrameIndex, frame.sequenceFrameIndex, frame.orderedFrameIndex, .{
                    .id = splitID,
                    .size = @as(u32, @intCast(splitSize)),
                    .frameIndex = @as(u32, @intCast(i / maxSize)),
                }, false);
            }

            if (i != 0 and newFrame.reliability.isReliable()) {
                newFrame.reliableFrameIndex = self.state.outputReliableIndex;
                self.state.outputReliableIndex += 1;
            } else if (i == 0 and newFrame.reliability.isReliable()) {
                newFrame.reliableFrameIndex = self.state.outputReliableIndex;
                self.state.outputReliableIndex += 1;
            }

            self.enqueueFrame(&newFrame, priority);
            i += maxSize;
        }
    }

    pub fn enqueueFrame(self: *Connection, frame: *Frame, priority: Priority) void {
        if (!self.active) {
            frame.deinit(self.server.allocator);
            return;
        }

        self.state.outputFrameQueue.append(self.server.allocator, frame.*) catch {
            frame.deinit(self.server.allocator);
            return;
        };

        const shouldSendImmediately = priority == Priority.Immediate;
        const queueLen = self.state.outputFrameQueue.items.len;
        if (shouldSendImmediately) {
            self.sendQueuedFrames(queueLen);
        }
    }

    pub fn sendQueuedFrames(self: *Connection, amount: usize) void {
        if (self.state.outputFrameQueue.items.len == 0) return;

        const maxFragmentSize = self.mtuSize - Constants.UDP_HEADER_SIZE;
        var currentSize: usize = 4;
        var framesToSend: usize = 0;

        const queueLen = self.state.outputFrameQueue.items.len;
        const maxFrames = @min(amount, queueLen);

        for (self.state.outputFrameQueue.items[0..maxFrames]) |frame| {
            const frameSize = Constants.UDP_HEADER_SIZE + frame.payload.len;
            if (currentSize + frameSize > maxFragmentSize and framesToSend > 0) {
                break;
            }
            currentSize += frameSize;
            framesToSend += 1;
        }

        if (framesToSend == 0) {
            framesToSend = 1;
        }

        const frames = self.state.outputFrameQueue.items[0..framesToSend];

        const sequence = @as(u24, @truncate(self.state.outputSequence));
        self.state.outputSequence += 1;

        _ = self.state.outputBackup.remove(sequence);

        var backup_buf = self.server.allocator.alloc(Frame, frames.len) catch {
            std.debug.print("Failed to alloc backup buffer\n", .{});
            return;
        };

        var i: usize = 0;
        while (i < frames.len) : (i += 1) {
            backup_buf[i] = frames[i];
        }
        const backup_slice = backup_buf[0..frames.len];

        self.state.outputBackup.put(sequence, backup_slice) catch {
            self.server.allocator.free(backup_slice);
            std.debug.print("Failed to put output backup\n", .{});
            return;
        };

        var t: usize = 0;
        while (t < framesToSend) : (t += 1) {
            self.state.outputFrameQueue.items[t].shouldFree = false;
        }

        var buffer = self.server.allocator.alloc(u8, 1492) catch {
            return;
        };
        defer self.server.allocator.free(buffer);
        var writer = Writer.init(buffer[0..]);

        var frameset = Messages.FrameSet.init(sequence, frames);
        const serialized = frameset.serialize(&writer) catch |err| {
            std.debug.print("Error serializing frame: {any}\n", .{err});

            _ = self.state.outputBackup.remove(sequence);
            for (backup_slice) |*frame| {
                if (frame.shouldFree) frame.deinit(self.server.allocator);
            }
            self.server.allocator.free(backup_slice);
            return;
        };

        self.cleanupSentFrames(framesToSend);
        self.send(serialized);
    }

    fn cleanupSentFrames(self: *Connection, amount: usize) void {
        const queue = &self.state.outputFrameQueue;
        const toRemove = @min(amount, queue.items.len);
        if (toRemove == 0) return;

        for (queue.items[0..toRemove]) |frame| {
            if (frame.shouldFree) {
                self.server.allocator.free(frame.payload);
            }
        }

        queue.replaceRange(self.server.allocator, 0, toRemove, &[_]Frame{}) catch |err| {
            std.debug.print("Error cleaning frame queue: {any}\n", .{err});
            return;
        };
    }

    pub fn send(self: *Connection, data: []const u8) void {
        self.server.send(data, self.address);
    }

    fn sendAck(self: *Connection, sequence: u24) void {
        var buffer = self.server.allocator.alloc(u8, 32) catch {
            return;
        };
        defer self.server.allocator.free(buffer);
        var writer = Writer.init(buffer[0..]);

        var seq: [1]u24 = .{sequence};
        var ack = Messages.Ack.init(seq[0..]);
        const serialized = ack.serialize(&writer) catch return;
        self.send(serialized);
    }

    pub fn sendPing(self: *Connection) void {
        var ping = Messages.ConnectedPing.init(std.time.milliTimestamp());

        var buffer = self.server.allocator.alloc(u8, 500) catch {
            return;
        };
        defer self.server.allocator.free(buffer);
        var writer = Writer.init(buffer[0..]);

        const serialized = ping.serialize(&writer) catch |err| {
            std.debug.print("Error trying to serialize ConnectedPing: {any}\n", .{err});
            return;
        };

        const frame = frameFromPayload(self, serialized) catch |err| {
            std.debug.print("Failed to alloc frame payload: {any}\n", .{err});
            return;
        };
        self.sendFrame(frame, .Normal);
    }

    pub fn onGamePacket(self: *Connection, cb: *const fn (*Connection, []const u8, ?*anyopaque) void, ctx: ?*anyopaque) void {
        self.gamePacketCb = cb;
        self.gamePacketCtx = ctx;
    }
};

pub const ConnectionState = struct {
    outputReliableIndex: u32,
    outputSequence: u32,
    outputSplitIndex: u16,

    outputFrameQueue: std.ArrayList(Frame),
    outputBackup: std.AutoHashMap(u24, []Frame),

    outputOrderIndex: [Constants.MAX_ACTIVE_FRAGMENTATIONS]u32,
    outputSequenceIndex: [Constants.MAX_ACTIVE_FRAGMENTATIONS]u32,

    lastInputSequence: i32 = -1,
    receivedSequences: std.AutoHashMap(u24, void),
    lostSequences: std.AutoHashMap(u24, void),

    inputHighestSequenceIndex: [Constants.MAX_ACTIVE_FRAGMENTATIONS]u32,
    inputOrderIndex: [Constants.MAX_ACTIVE_FRAGMENTATIONS]u32,
    inputOrderingQueue: std.AutoHashMap(u32, std.AutoHashMap(u32, Frame)),

    fragmentsQueue: std.AutoHashMap(u16, std.AutoHashMap(u16, Frame)),
    packetFragments: std.AutoHashMap(u16, std.ArrayList([]const u8)),

    pub fn init(allocator: std.mem.Allocator) !ConnectionState {
        return ConnectionState{
            .outputReliableIndex = 0,
            .outputSequence = 0,
            .outputSplitIndex = 0,
            .outputFrameQueue = std.ArrayList(Frame){
                .items = &[_]Frame{},
                .capacity = 0,
            },
            .outputBackup = std.AutoHashMap(u24, []Frame).init(allocator),
            .outputOrderIndex = undefined,
            .outputSequenceIndex = undefined,
            .lastInputSequence = -1,
            .receivedSequences = std.AutoHashMap(u24, void).init(allocator),
            .lostSequences = std.AutoHashMap(u24, void).init(allocator),
            .inputHighestSequenceIndex = undefined,
            .inputOrderIndex = undefined,
            .inputOrderingQueue = std.AutoHashMap(u32, std.AutoHashMap(u32, Frame)).init(allocator),
            .fragmentsQueue = std.AutoHashMap(u16, std.AutoHashMap(u16, Frame)).init(allocator),
            .packetFragments = std.AutoHashMap(u16, std.ArrayList([]const u8)).init(allocator),
        };
    }

    pub fn deinit(self: *ConnectionState, allocator: std.mem.Allocator) void {
        self.receivedSequences.deinit();
        self.lostSequences.deinit();

        for (self.outputFrameQueue.items) |*frame| {
            frame.deinit(allocator);
        }
        self.outputFrameQueue.clearAndFree(allocator);
        self.outputFrameQueue.deinit(allocator);

        var outerIter = self.inputOrderingQueue.iterator();
        while (outerIter.next()) |outerEntry| {
            var innerMap = outerEntry.value_ptr;
            var innerIter = innerMap.iterator();
            while (innerIter.next()) |entry| {
                if (entry.value_ptr.shouldFree) {
                    allocator.free(entry.value_ptr.payload);
                }
            }
            outerEntry.value_ptr.deinit();
        }
        self.inputOrderingQueue.deinit();

        var backupIter = self.outputBackup.iterator();
        while (backupIter.next()) |entry| {
            const frames = entry.value_ptr.*;
            for (frames) |frame| {
                if (frame.shouldFree) {
                    allocator.free(frame.payload);
                }
            }
            allocator.free(frames);
        }
        self.outputBackup.deinit();

        var fragmentsIter = self.fragmentsQueue.iterator();
        while (fragmentsIter.next()) |outerEntry| {
            var innerMap = outerEntry.value_ptr;
            var innerIter = innerMap.iterator();
            while (innerIter.next()) |entry| {
                if (entry.value_ptr.shouldFree) {
                    allocator.free(entry.value_ptr.payload);
                }
            }
            outerEntry.value_ptr.deinit();
        }
        self.fragmentsQueue.deinit();

        var packetIter = self.packetFragments.iterator();
        while (packetIter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        self.packetFragments.deinit();
    }
};
