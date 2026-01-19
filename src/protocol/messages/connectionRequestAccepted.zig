const std = @import("std");

const BinaryUtils = @import("BinaryUtils");
const Writer = BinaryUtils.BinaryWriter;

const Address = @import("../address.zig").Address;
const ID = @import("../id.zig").ID;

pub const ConnectionRequestAccepted = struct {
    address: std.net.Address,
    systemIndex: u16,
    addresses: std.net.Address,
    requestTimestamp: i64,
    timestamp: i64,

    pub fn init(address: std.net.Address, systemIndex: u16, addresses: std.net.Address, requestTimestamp: i64, timestamp: i64) ConnectionRequestAccepted {
        return .{
            .address = address,
            .systemIndex = systemIndex,
            .addresses = addresses,
            .requestTimestamp = requestTimestamp,
            .timestamp = timestamp,
        };
    }

    pub fn serialize(self: *ConnectionRequestAccepted, buf: []u8) ![]const u8 {
        var writer = Writer.init(buf[0..]);

        try writer.writeU8(@intFromEnum(ID.ConnectionRequestAccepted));
        try Address.init(self.address).write(&writer);
        try writer.writeU16BE(self.systemIndex);

        var i: u8 = 0;
        while (i < 20) : (i += 1) {
            try Address.init(self.addresses).write(&writer);
        }

        try writer.writeLongBE(self.requestTimestamp);
        try writer.writeLongBE(self.timestamp);

        return buf[0..writer.pos];
    }
};
