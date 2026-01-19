const std = @import("std");

const BinaryUtils = @import("BinaryUtils");
const Writer = BinaryUtils.BinaryWriter;

const Magic = @import("../magic.zig").Magic;
const ID = @import("../id.zig").ID;

pub const ConnectionReply1 = struct {
    serverGUID: u64,
    serverHasSecurity: bool,
    cookie: u32,
    mtuSize: u16,

    pub fn init(serverGUID: u64, serverHasSecurity: bool, cookie: u32, mtuSize: u16) ConnectionReply1 {
        return .{
            .serverGUID = serverGUID,
            .serverHasSecurity = serverHasSecurity,
            .cookie = cookie,
            .mtuSize = mtuSize,
        };
    }

    pub fn serialize(self: *ConnectionReply1) ![]const u8 {
        var data: [1500]u8 = undefined;
        var writer = Writer.init(data[0..]);

        try writer.writeU8(@intFromEnum(ID.OpenConnectionReply1));
        try Magic.write(&writer);
        try writer.writeU64BE(self.serverGUID);
        try writer.writeBool(self.serverHasSecurity);
        try writer.writeU16BE(self.mtuSize);

        return writer.buf[0..writer.pos];
    }
};
