const std = @import("std");
const BinaryUtils = @import("BinaryUtils");
const Reader = BinaryUtils.BinaryReader;
const Writer = BinaryUtils.BinaryWriter;

const Reliability = @import("reliability.zig").Reliability;
const Flags = @import("reliability.zig").Flags;

pub const Frame = struct {
    payload: []const u8,
    splitInfo: ?SplitInfo,
    reliableFrameIndex: ?u32,
    sequenceFrameIndex: ?u32,
    orderedFrameIndex: ?u32,
    orderChannel: ?u8,
    reliability: Reliability,
    shouldFree: bool = false,

    pub const SplitInfo = struct {
        id: u16,
        size: u32,
        frameIndex: u32,
    };

    pub fn init(
        reliability: Reliability,
        payload: []const u8,
        orderChannel: ?u8,
        reliableFrameIndex: ?u32,
        sequenceFrameIndex: ?u32,
        orderedFrameIndex: ?u32,
        splitInfo: ?SplitInfo,
        shouldFree: bool,
    ) Frame {
        return .{
            .reliability = reliability,
            .payload = payload,
            .orderChannel = orderChannel,
            .reliableFrameIndex = reliableFrameIndex,
            .sequenceFrameIndex = sequenceFrameIndex,
            .orderedFrameIndex = orderedFrameIndex,
            .splitInfo = splitInfo,
            .shouldFree = shouldFree,
        };
    }

    pub fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        if (self.shouldFree) {
            allocator.free(self.payload);
        }
    }

    pub fn isSplit(self: *const Frame) bool {
        return self.splitInfo != null;
    }

    pub fn getLength(self: *const Frame) usize {
        var len: usize = 3 + self.payload.len;
        if (self.reliability.isReliable()) len += 3;
        if (self.reliability.isSequenced()) len += 3;
        if (self.reliability.isOrdered()) len += 4;
        if (self.isSplit()) len += 10;
        return len;
    }

    pub fn read(reader: *Reader) !Frame {
        const rawFlags = try reader.readU8();
        const reliability: Reliability = @as(Reliability, @enumFromInt((rawFlags & 0b1110_0000) >> 5));
        const flags = Flags.fromU8(rawFlags);

        const lengthBits = try reader.readU16BE();
        const payloadLength = (lengthBits + 7) / 8;

        if (payloadLength == 0) {
            return error.InvalidFrameLength;
        }
        // if (payloadLength + reader.pos > reader.buf.len) {
        //     std.debug.print("Frame size = {d}, Reader size = {d}", .{ payloadLength + reader.pos, reader.buf.len });
        //     return error.FrameBiggerThenReader;
        // }

        var orderChannel: ?u8 = null;
        var reliableFrameIndex: ?u32 = null;
        var sequenceFrameIndex: ?u32 = null;
        var orderedFrameIndex: ?u32 = null;
        var splitInfo: ?Frame.SplitInfo = null;

        if (reliability.isReliable()) {
            reliableFrameIndex = try reader.readU24LE();
        }
        if (reliability.isSequenced()) {
            sequenceFrameIndex = try reader.readU24LE();
        }
        if (reliability.isOrdered()) {
            orderedFrameIndex = try reader.readU24LE();
            orderChannel = try reader.readU8();
        }

        if (flags) |flag| {
            if (flag.isSplit()) {
                splitInfo = Frame.SplitInfo{
                    .size = try reader.readU32BE(),
                    .id = try reader.readU16BE(),
                    .frameIndex = try reader.readU32BE(),
                };
            }
        }

        const payload = try reader.read(reader.buf.len - reader.pos);
        return Frame.init(reliability, payload, orderChannel, reliableFrameIndex, sequenceFrameIndex, orderedFrameIndex, splitInfo, false);
    }

    fn buildFlags(self: *const Frame) u8 {
        var flags: u8 = @as(u8, @intFromEnum(self.reliability)) << 5;
        if (self.isSplit()) flags |= @intFromEnum(Flags.Split);
        return flags;
    }

    pub fn write(self: *const Frame, writer: *Writer) !void {
        const lengthBits: u16 = @as(u16, @intCast(self.payload.len)) * 8;

        try writer.writeU8(self.buildFlags());
        try writer.writeU16BE(lengthBits);

        if (self.reliability.isReliable()) {
            if (self.reliableFrameIndex == null) return error.MissingReliableIndex;
            try writer.writeU24LE(@as(u24, @intCast(self.reliableFrameIndex.?)));
        }
        if (self.reliability.isSequenced()) {
            if (self.sequenceFrameIndex == null) return error.MissingSequenceIndex;
            try writer.writeU24LE(@as(u24, @intCast(self.sequenceFrameIndex.?)));
        }
        if (self.reliability.isOrdered()) {
            if (self.orderedFrameIndex == null) return error.MissingOrderedIndex;
            if (self.orderChannel == null) return error.MissingOrderChannel;
            // Wrap to avoid int overflow
            const index24: u24 = @intCast(self.orderedFrameIndex.? % 0x1000000);
            try writer.writeU24LE(index24);
            try writer.writeU8(self.orderChannel.?);
        }
        if (self.isSplit()) {
            const split = self.splitInfo.?;
            try writer.writeU32BE(split.size);
            try writer.writeU16BE(split.id);
            try writer.writeU32BE(split.frameIndex);
        }

        try writer.write(self.payload);
    }
};
