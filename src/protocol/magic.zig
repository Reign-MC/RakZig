const BinaryUtils = @import("BinaryUtils");
const Reader = BinaryUtils.BinaryReader;
const Writer = BinaryUtils.BinaryWriter;

pub const Magic = struct {
    const bytes: [16]u8 = [16]u8{
        0x00, 0xff, 0xff, 0x00, 0xfe, 0xfe, 0xfe, 0xfe,
        0xfd, 0xfd, 0xfd, 0xfd, 0x12, 0x34, 0x56, 0x78,
    };

    pub fn read(reader: *Reader) !void {
        try reader.skip(bytes.len);
    }

    pub fn write(writer: *Writer) !void {
        try writer.write(bytes[0..]);
    }
};
