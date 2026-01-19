const std = @import("std");

const BinaryUtils = @import("BinaryUtils");
const Writer = BinaryUtils.BinaryWriter;
const Reader = BinaryUtils.BinaryReader;

const ID = @import("../id.zig").ID;

pub const ConnectedPing = struct {
    timestamp: i64,

    pub fn init(timestamp: i64) ConnectedPing {
        return .{
            .timestamp = timestamp,
        };
    }

    pub fn serialize(self: *ConnectedPing, writer: *Writer) ![]u8 {
        try writer.writeU8(@intFromEnum(ID.ConnectedPingPong));
        try writer.writeI64BE(self.timestamp);

        return writer.buf[0..writer.pos];
    }

    pub fn deserialize(buffer: []const u8) !ConnectedPing {
        var reader = Reader.init(buffer);

        _ = try reader.readU8();
        const timestamp = try reader.readI64BE();

        return .{
            .timestamp = timestamp,
        };
    }
};
