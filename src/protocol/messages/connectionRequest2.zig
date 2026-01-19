const std = @import("std");

const BinaryUtils = @import("BinaryUtils");
const Reader = BinaryUtils.BinaryReader;

const Magic = @import("../magic.zig").Magic;
const ID = @import("../id.zig").ID;
const Server = @import("../../server/server.zig").Server;
const Constants = @import("../constants.zig");
const Address = @import("../address.zig").Address;

pub const ConnectionRequest2 = struct {
    serverAddress: std.net.Address,
    mtuSize: u16,
    clientGUID: u64,
    serverHasSecurity: bool,
    cookie: u32,

    pub fn init(serverAddress: std.net.Address, mtuSize: u16, clientGUID: u64, serverHasSecurity: bool, cookie: u32) ConnectionRequest2 {
        return .{
            .serverAddress = serverAddress,
            .mtuSize = mtuSize,
            .clientGUID = clientGUID,
            .serverHasSecurity = serverHasSecurity,
            .cookie = cookie,
        };
    }

    pub fn deserialize(data: []const u8) !ConnectionRequest2 {
        var reader = Reader.init(data);

        _ = try reader.readU8();
        try Magic.read(&reader);

        const address = try Address.read(&reader);
        const mtuSize = try reader.readU16BE();
        const clientGUID = try reader.readU64BE();

        return .{
            .serverAddress = address,
            .mtuSize = @intCast(mtuSize),
            .clientGUID = clientGUID,
            .serverHasSecurity = false,
            .cookie = 0,
        };
    }
};
