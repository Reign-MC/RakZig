const std = @import("std");

const BinaryUtils = @import("BinaryUtils");
const Writer = BinaryUtils.BinaryWriter;
const Reader = BinaryUtils.BinaryReader;

const Magic = @import("../magic.zig").Magic;

const ID = @import("../id.zig").ID;

pub const IncompatibleProtocolVersion = struct {
    protocolVersion: u8,
    guid: u64,

    pub fn init(protocolVersion: u8, guid: u64) IncompatibleProtocolVersion {
        return .{
            .protocolVersion = protocolVersion,
            .guid = guid,
        };
    }

    pub fn serialize(self: *IncompatibleProtocolVersion, writer: *Writer) ![]u8 {
        try writer.writeU8(@intFromEnum(ID.IncompatibleProtocolVersion));
        try writer.writeU8(self.protocolVersion);
        try Magic.write(writer);
        try writer.writeU64BE(self.guid);

        return writer.buf[0..writer.pos];
    }

    pub fn deserialize(buffer: []const u8) !IncompatibleProtocolVersion {
        var reader = Reader.init(buffer);

        _ = try reader.readU8();
        const protocolVersion = try reader.readU8();
        try Magic.read(&reader);
        const guid = try reader.readU64BE();

        return .{
            .protocolVersion = protocolVersion,
            .guid = guid,
        };
    }
};
