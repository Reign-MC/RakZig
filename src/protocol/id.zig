pub const ID = enum(u8) {
    ConnectedPing = 0x00,
    UnconnectedPing = 0x01,
    ConnectedPong = 0x03,

    ConnectedPingOpenConnections = 0x02,

    OpenConnectionRequest1 = 0x05,
    OpenConnectionReply1 = 0x06,
    OpenConnectionRequest2 = 0x07,
    OpenConnectionReply2 = 0x08,

    ConnectionRequest = 0x09,
    ConnectionRequestAccepted = 0x10,
    NewIncomingConnection = 0x13,

    DisconnectNotification = 0x15,

    IncompatibleProtocolVersion = 0x19,

    UnconnectedPong = 0x1C,

    FrameSet = 0x80,
    NACK = 0xA0,
    ACK = 0xC0,

    GamePacket = 0xFE,

    pub fn fromU8(value: u8) ?ID {
        return switch (value) {
            0x00 => .ConnectedPing,
            0x01 => .UnconnectedPing,
            0x03 => .ConnectedPong,
            0x1C => .UnconnectedPong,
            0x02 => .ConnectedPingOpenConnections,

            0x05 => .OpenConnectionRequest1,
            0x06 => .OpenConnectionReply1,
            0x07 => .OpenConnectionRequest2,
            0x08 => .OpenConnectionReply2,

            0x09 => .ConnectionRequest,
            0x10 => .ConnectionRequestAccepted,
            0x13 => .NewIncomingConnection,

            0x15 => .DisconnectNotification,

            0x19 => .IncompatibleProtocolVersion,

            0x80 => .FrameSet,
            0xA0 => .NACK,
            0xC0 => .ACK,
            0xFE => .GamePacket,

            else => null,
        };
    }
};
