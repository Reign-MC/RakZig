const std = @import("std");

const BinaryUtils = @import("BinaryUtils");
const Writer = BinaryUtils.BinaryWriter;
const Reader = BinaryUtils.BinaryReader;

const ID = @import("../id.zig").ID;
const Frame = @import("../frame.zig").Frame;

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

        _ = try reader.readU8();
        const sequenceNumber = try reader.readU24LE();

        var frames = std.ArrayList(Frame).initBuffer(&[_]Frame{});

        while (reader.pos < reader.buf.len) {
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
        var idx: usize = 0;
        while (idx < out_len) : (idx += 1) {
            out_buf[idx] = frames.items[idx];
        }
        frames.deinit(allocator);

        return .{
            .sequenceNumber = sequenceNumber,
            .frames = out_buf[0..out_len],
        };
    }
};
