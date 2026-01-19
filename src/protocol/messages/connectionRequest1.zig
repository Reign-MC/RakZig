const std = @import("std");

const BinaryUtils = @import("BinaryUtils");
const Reader = BinaryUtils.BinaryReader;

const Magic = @import("../magic.zig").Magic;
const ID = @import("../id.zig").ID;
const Server = @import("../../server/server.zig").Server;
const Constants = @import("../constants.zig");

pub const ConnectionRequest1 = struct {
    protocol: u8,
    mtu: u16,

    pub fn init(protocol: u8, mtu: u16) ConnectionRequest1 {
        return .{
            .protocol = protocol,
            .mtu = mtu,
        };
    }

    pub fn deserialize(data: []const u8) !ConnectionRequest1 {
        var reader = Reader.init(data);

        _ = try reader.readU8();
        try Magic.read(&reader);
        const protocol = try reader.readU8();

        var mtuSize: u16 = @intCast(reader.buf.len - reader.pos);
        if (mtuSize + Constants.UDP_HEADER_SIZE <= Constants.MAX_MTU_SIZE) {
            mtuSize = mtuSize + Constants.UDP_HEADER_SIZE;
        } else {
            mtuSize = Constants.MAX_MTU_SIZE;
        }

        return .{
            .protocol = protocol,
            .mtu = mtuSize,
        };
    }
};
