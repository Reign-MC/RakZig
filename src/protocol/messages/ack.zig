const std = @import("std");

const BinaryUtils = @import("BinaryUtils");
const Writer = BinaryUtils.BinaryWriter;
const Reader = BinaryUtils.BinaryReader;

const ID = @import("../id.zig").ID;

const emptyU24Slice: []u24 = &[_]u24{};

pub const Ack = struct {
    sequences: []u24,

    pub fn init(sequences: []u24) Ack {
        return .{
            .sequences = sequences,
        };
    }

    pub fn deserialize(
        data: []const u8,
        out: []u24,
    ) !Ack {
        var reader = Reader.init(data[0..]);

        _ = try reader.readU8();
        const recordCount = try reader.readU16BE();

        var count: usize = 0;
        var records_read: usize = 0;

        while (records_read < recordCount) : (records_read += 1) {
            const recordType = try reader.readU8();
            if (recordType == 1) {
                const seq = try reader.readU24LE();
                if (count < out.len) {
                    out[count] = seq;
                    count += 1;
                }
            } else {
                const start = try reader.readU24LE();
                const end = try reader.readU24LE();
                var cur: u32 = start;
                while (cur <= end) : (cur += 1) {
                    if (count < out.len) {
                        out[count] = cur;
                        count += 1;
                    }
                }
            }
        }

        return Ack{ .sequences = out[0..count] };
    }

    pub fn deserializeAlloc(data: []const u8, allocator: std.mem.Allocator) !Ack {
        var reader = Reader.init(data[0..]);

        _ = try reader.readU8();
        const recordCount = try reader.readU16BE();

        var count_reader = Reader.init(data[3..]);
        var records_read: usize = 0;
        var total: usize = 0;
        while (records_read < recordCount) : (records_read += 1) {
            const recordType = try count_reader.readU8();
            if (recordType == 1) {
                _ = try count_reader.readU24LE();
                total += 1;
            } else {
                const start = try count_reader.readU24LE();
                const end = try count_reader.readU24LE();
                if (end < start) return error.FrameBiggerThenReader;
                const range_len = @as(usize, end - start) + 1;
                total += range_len;
            }
            if (total > 1_000_000) return error.FrameBiggerThenReader;
        }

        if (total == 0) {
            return Ack{ .sequences = emptyU24Slice };
        }

        var out_buf = try allocator.alloc(u24, total);

        var fill_reader = Reader.init(data[3..]);
        var out_idx: usize = 0;
        records_read = 0;
        while (records_read < recordCount) : (records_read += 1) {
            const recordType = try fill_reader.readU8();
            if (recordType == 1) {
                const seq = try fill_reader.readU24LE();
                out_buf[out_idx] = seq;
                out_idx += 1;
            } else {
                const start = try fill_reader.readU24LE();
                const end = try fill_reader.readU24LE();
                var cur: u32 = start;
                while (cur <= end) : (cur += 1) {
                    out_buf[out_idx] = @intCast(cur);
                    out_idx += 1;
                }
            }
        }

        return Ack{ .sequences = out_buf[0..out_idx] };
    }

    pub fn deinit(self: *Ack, allocator: std.mem.Allocator) void {
        if (self.sequences.len != 0) allocator.free(self.sequences);
    }

    pub fn serialize(self: *Ack, writer: *Writer) ![]const u8 {
        try writer.writeU8(@intFromEnum(ID.ACK));

        const count = self.sequences.len;

        if (count == 0) {
            try writer.writeI16BE(0);
            return writer.buf[0..writer.pos];
        }

        var i: usize = 0;
        var records: u16 = 0;

        var start = self.sequences[0];
        var last = self.sequences[0];

        const recordPos = writer.pos;
        try writer.writeU16BE(0);

        while (i < count) {
            const cur = self.sequences[i];
            i += 1;

            if (cur == last + 1) {
                last = cur;
                continue;
            }

            try writeRecord(writer, start, last);
            records += 1;
            start = cur;
            last = cur;
        }

        try writeRecord(writer, start, last);
        records += 1;

        const endPos = writer.pos;
        writer.pos = recordPos;
        try writer.writeU16BE(@intCast(records));
        writer.pos = endPos;
        return writer.buf[0..endPos];
    }

    fn writeRecord(writer: *Writer, start: u32, end: u32) !void {
        if (start == end) {
            try writer.writeU8(1);
            try writer.writeU24LE(@intCast(start));
        } else {
            try writer.writeU8(0);
            try writer.writeU24LE(@intCast(start));
            try writer.writeU24LE(@intCast(end));
        }
    }
};
