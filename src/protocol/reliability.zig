pub const Reliability = enum(u3) {
    Unreliable,
    UnreliableSequenced,
    Reliable,
    ReliableOrdered,
    ReliableSequenced,
    UnreliableWithAckReceipt,
    ReliableWithAckReceipt,
    ReliableOrderedWithAckReceipt,

    pub fn isReliable(self: Reliability) bool {
        return switch (self) {
            .Reliable, .ReliableOrdered, .ReliableSequenced, .ReliableWithAckReceipt, .ReliableOrderedWithAckReceipt => true,
            else => false,
        };
    }

    pub fn isSequenced(self: Reliability) bool {
        return switch (self) {
            .ReliableSequenced, .UnreliableSequenced => true,
            else => false,
        };
    }

    pub fn isOrdered(self: Reliability) bool {
        return switch (self) {
            .ReliableOrdered, .ReliableOrderedWithAckReceipt => true,
            else => false,
        };
    }
};
pub const Flags = enum(u8) {
    Split = 0x10,
    Valid = 0x80,
    Ack = 0x40,
    Nack = 0x20,

    pub fn fromU8(value: u8) ?Flags {
        return switch (value) {
            0x10 => Flags.Split,
            0x80 => Flags.Valid,
            0x40 => Flags.Ack,
            0x20 => Flags.Nack,
            else => null,
        };
    }

    pub fn isSplit(self: Flags) bool {
        return self == .Split;
    }
};
