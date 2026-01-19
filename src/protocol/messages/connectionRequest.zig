const std = @import("std");

const BinaryUtils = @import("BinaryUtils");
const Reader = BinaryUtils.BinaryReader;

const ID = @import("../id.zig").ID;

pub const ConnectionRequest = struct {
    guid: i64,
    timestamp: i64,
    useSecurity: bool,

    pub fn init(guid: u64, timestamp: i64, useSecurity: bool) ConnectionRequest {
        return .{
            .guid = guid,
            .timestamp = timestamp,
            .useSecurity = useSecurity,
        };
    }

    pub fn deserialize(data: []const u8) !ConnectionRequest {
        var reader = Reader.init(data);

        _ = try reader.readU8();
        const guid = try reader.readI64BE();
        const timestamp = try reader.readI64BE();
        const useSecurity = try reader.readBool();

        return .{
            .guid = guid,
            .timestamp = timestamp,
            .useSecurity = useSecurity,
        };
    }
};
