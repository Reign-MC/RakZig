const std = @import("std");

const BinaryUtils = @import("BinaryUtils");
const Writer = BinaryUtils.BinaryWriter;

const Magic = @import("../magic.zig").Magic;
const ID = @import("../id.zig").ID;
const Address = @import("../address.zig").Address;

pub const ConnectionReply2 = struct {
    serverGUID: u64,
    address: std.net.Address,
    mtuSize: u16,
    encryptionEnabled: bool,

    pub fn init(serverGUID: u64, address: std.net.Address, mtuSize: u16, encryptionEnabled: bool) ConnectionReply2 {
        return .{
            .serverGUID = serverGUID,
            .address = address,
            .mtuSize = mtuSize,
            .encryptionEnabled = encryptionEnabled,
        };
    }

    pub fn serialize(self: *ConnectionReply2) ![]const u8 {
        var data: [1500]u8 = undefined;
        var writer = Writer.init(data[0..]);

        try writer.writeU8(@intFromEnum(ID.OpenConnectionReply2));
        try Magic.write(&writer);
        try writer.writeU64BE(self.serverGUID);
        try Address.init(self.address).write(&writer);
        try writer.writeU16BE(self.mtuSize);
        try writer.writeBool(self.encryptionEnabled);

        return writer.buf[0..writer.pos];
    }
};
