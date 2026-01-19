const std = @import("std");
const BinaryUtils = @import("BinaryUtils");
const Writer = BinaryUtils.BinaryWriter;
const Reader = BinaryUtils.BinaryReader;

pub const AddressError = error{
    UnsupportedAddressFamily,
};

pub const Address = struct {
    value: std.net.Address,

    pub fn init(addr: std.net.Address) Address {
        return .{ .value = addr };
    }

    pub fn write(self: Address, writer: *Writer) !void {
        switch (self.value.any.family) {
            std.posix.AF.INET => {
                // IPv4
                try writer.writeU8(4);

                const ip = self.value.in.sa.addr;
                const port = self.value.in.sa.port;

                const bytes = std.mem.asBytes(&ip);
                try writer.writeU8(~bytes[0]);
                try writer.writeU8(~bytes[1]);
                try writer.writeU8(~bytes[2]);
                try writer.writeU8(~bytes[3]);

                try writer.writeU16BE(port);
            },

            std.posix.AF.INET6 => {
                try writer.writeU8(6);

                try writer.writeU16BE(~@as(u16, 23));
                try writer.writeU16BE(self.value.in6.sa.port);
                try writer.writeU32BE(0);

                for (0..8) |i| {
                    const word = std.mem.readInt(
                        u16,
                        self.value.in6.sa.addr[i * 2 ..][0..2],
                        .big,
                    );
                    try writer.writeU16BE(word ^ 0xffff);
                }

                try writer.writeU32BE(0);
            },

            else => return AddressError.UnsupportedAddressFamily,
        }
    }

    pub fn read(reader: *Reader) !std.net.Address {
        const version = try reader.readU8();

        switch (version) {
            4 => {
                var ip: [4]u8 = undefined;
                for (0..4) |i| {
                    ip[i] = ~try reader.readU8();
                }

                const port = try reader.readU16BE();

                return std.net.Address.initIp4(ip, port);
            },

            6 => {
                const flowinfo = try reader.readU16BE();
                const port = try reader.readU16BE();
                const scopeID = try reader.readU32BE();

                var ip: [16]u8 = undefined;
                for (0..8) |i| {
                    const word = try reader.readU16BE() ^ 0xffff;
                    std.mem.writeInt(u16, ip[i * 2 ..][0..2], word, .big);
                }

                _ = try reader.readU32BE();

                return std.net.Address.initIp6(ip, port, flowinfo, scopeID);
            },
            else => return AddressError.UnsupportedAddressFamily,
        }
    }
};
