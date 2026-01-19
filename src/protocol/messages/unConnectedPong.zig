const std = @import("std");

const BinaryUtils = @import("BinaryUtils");
const Writer = BinaryUtils.BinaryWriter;
const Reader = BinaryUtils.BinaryReader;

const Magic = @import("../magic.zig").Magic;
const ID = @import("../id.zig").ID;

pub const UnconnectedPong = struct {
    timestamp: i64,
    guid: u64,
    message: []const u8,

    pub fn init(timestamp: i64, guid: u64, message: []const u8) UnconnectedPong {
        return .{
            .timestamp = timestamp,
            .guid = guid,
            .message = message,
        };
    }

    pub fn serialize(self: *UnconnectedPong, writer: *Writer) ![]u8 {
        try writer.writeU8(@intFromEnum(ID.UnconnectedPong));
        try writer.writeI64BE(self.timestamp);
        try writer.writeU64BE(self.guid);
        try Magic.write(writer);
        try writer.writeString16BE(self.message);
        return writer.buf[0..writer.pos];
    }

    pub fn deserialize(buffer: []const u8) !UnconnectedPong {
        var reader = Reader.init(buffer);

        _ = try reader.readU8();

        const timestamp = try reader.readI64BE();
        const guid = try reader.readU64BE();
        try Magic.read(&reader);
        const message = try reader.readString16BE();

        return .{
            .timestamp = timestamp,
            .guid = guid,
            .message = message,
        };
    }
};
