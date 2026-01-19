const std = @import("std");

const BinaryUtils = @import("BinaryUtils");
const Writer = BinaryUtils.BinaryWriter;
const Reader = BinaryUtils.BinaryReader;

const ID = @import("../id.zig").ID;

pub const ConnectedPong = struct {
    timestamp: i64,
    pongTimestamp: i64,

    pub fn init(timestamp: i64, pongTimestamp: i64) ConnectedPong {
        return .{
            .timestamp = timestamp,
            .pongTimestamp = pongTimestamp,
        };
    }

    pub fn serialize(self: *ConnectedPong, writer: *Writer) ![]u8 {
        try writer.writeU8(@intFromEnum(ID.ConnectedPingPong));
        try writer.writeI64BE(self.timestamp);
        try writer.writeI64BE(self.pongTimestamp);

        return writer.buf[0..writer.pos];
    }

    pub fn deserialize(buffer: []const u8) !ConnectedPong {
        var reader = Reader.init(buffer);

        _ = try reader.readU8();

        const timestamp = try reader.readI64BE();
        const pongTimestamp = try reader.readI64BE();

        return .{
            .timestamp = timestamp,
            .pongTimestamp = pongTimestamp,
        };
    }
};
