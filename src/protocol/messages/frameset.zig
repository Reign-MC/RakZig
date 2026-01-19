const std = @import("std");

const BinaryUtils = @import("BinaryUtils");
const Writer = BinaryUtils.BinaryWriter;
const Reader = BinaryUtils.BinaryReader;

const ID = @import("../id.zig").ID;
const Frame = @import("../frame.zig").Frame;
const Reliability = @import("../reliability.zig").Reliability;

pub const FrameSet = struct {
    sequenceNumber: u24,
    frames: []const Frame,

    pub fn init(sequenceNumber: u24, frames: []const Frame) FrameSet {
        return .{
            .sequenceNumber = sequenceNumber,
            .frames = frames,
        };
    }

    pub fn deinit(self: *FrameSet, allocator: std.mem.Allocator) void {
        var i: usize = 0;
        while (i < self.frames.len) : (i += 1) {
            const fptr: *Frame = @constCast(&self.frames[i]);
            fptr.deinit(allocator);
        }
        if (self.frames.len != 0) allocator.free(self.frames);
    }

    pub fn serialize(self: *FrameSet, writer: *Writer) ![]u8 {
        try writer.writeU8(@intFromEnum(ID.FrameSet));
        try writer.writeU24LE(self.sequenceNumber);

        for (self.frames) |frame| {
            try frame.write(writer);
        }

        return writer.buf[0..writer.pos];
    }

    pub fn deserialize(buffer: []const u8, allocator: std.mem.Allocator) !FrameSet {
        var reader = Reader.init(buffer);

        // Skip first byte (flags or marker)
        _ = try reader.readU8();

        const sequenceNumber = try reader.readU24LE();

        var frames = std.ArrayList(Frame).initBuffer(&[_]Frame{});

        while (reader.pos < reader.buf.len) {
            // Need at least 3 bytes to read flags + length
            if (reader.pos + 3 > reader.buf.len) break;

            const rawFlags: u8 = reader.buf[reader.pos];

            // Cast each byte to u16 before shifting to avoid u3/u8 issues
            const lengthBits: u16 =
                (@as(u16, reader.buf[reader.pos + 1]) << 8) |
                @as(u16, reader.buf[reader.pos + 2]);
            const payloadLength: usize = @as(usize, (lengthBits + 7) / 8);

            const reliability: Reliability =
                @as(Reliability, @enumFromInt((rawFlags & 0b1110_0000) >> 5));

            // Calculate total required bytes for this frame
            var required: usize = 1 + 2 + payloadLength; // flags + length + payload
            if (reliability.isReliable()) required += 3;
            if (reliability.isSequenced()) required += 3;
            if (reliability.isOrdered()) required += 3 + 1;
            if ((rawFlags & 0x10) != 0) required += 10; // split info

            // If the frame would go past the buffer, stop reading
            if (reader.pos + required > reader.buf.len) break;

            const frame = try Frame.read(&reader);
            try frames.append(allocator, frame);
        }

        const out_len = frames.items.len;
        if (out_len == 0) {
            frames.deinit(allocator);
            return .{
                .sequenceNumber = sequenceNumber,
                .frames = &[_]Frame{},
            };
        }

        var out_buf = try allocator.alloc(Frame, out_len);
        var outIndex: u8 = 0;
        for (frames.items) |frame| {
            out_buf[outIndex] = frame;
            outIndex += 1;
        }
        frames.deinit(allocator);

        return .{
            .sequenceNumber = sequenceNumber,
            .frames = out_buf[0..out_len],
        };
    }
};
