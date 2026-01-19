const std = @import("std");

const BinaryUtils = @import("BinaryUtils");
const Writer = BinaryUtils.BinaryWriter;
const Reader = BinaryUtils.BinaryReader;

const Magic = @import("../magic.zig").Magic;

const ID = @import("../id.zig").ID;

pub const UnconnectedPing = struct {
    timestamp: i64,
    guid: u64,

    pub fn init(timestamp: i64, guid: u64) UnconnectedPing {
        return .{
            .timestamp = timestamp,
            .guid = guid,
        };
    }

    pub fn serialize(self: *UnconnectedPing, writer: *Writer) ![]u8 {
        try writer.writeU8(@intFromEnum(ID.UnconnectedPing));
        try writer.writeI64BE(self.timestamp);
        try Magic.write(writer);
        try writer.writeU64BE(self.guid);

        return writer.buf[0..writer.pos];
    }

    pub fn deserialize(buffer: []const u8) !UnconnectedPing {
        var reader = Reader.init(buffer);

        _ = try reader.readU8();
        const timestamp = try reader.readI64BE();
        try Magic.read(&reader);
        const guid = try reader.readU64BE();

        return .{
            .timestamp = timestamp,
            .guid = guid,
        };
    }
};
