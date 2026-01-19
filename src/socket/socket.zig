const std = @import("std");
const builtin = @import("builtin");

const win = std.os.windows;
const ws2 = win.ws2_32;
const posix = std.posix;

pub const SocketError = error{
    WinsockInitFailed,
    SocketCreationFailed,
    BindFailed,
    ReceiveFailed,
};

pub const Socket = struct {
    handle: if (builtin.os.tag == .windows) ws2.SOCKET else usize,

    pub const RecvResult = struct {
        len: usize,
        addr: std.net.Address,
    };

    fn parseAddr(host: []const u8) u32 {
        if (host.len == 0 or std.mem.eql(u8, host, "0.0.0.0")) return 0;
        if (builtin.os.tag == .windows) return ws2.inet_addr(host.ptr);
        return posix.inet_addr(host.ptr);
    }

    fn initWin(host: []const u8, port: u16) !ws2.SOCKET {
        var wsa: ws2.WSADATA = undefined;
        if (ws2.WSAStartup(0x0202, &wsa) != 0)
            return SocketError.WinsockInitFailed;

        const sock = ws2.socket(ws2.AF.INET, ws2.SOCK.DGRAM, 0);
        if (sock == ws2.INVALID_SOCKET)
            return SocketError.SocketCreationFailed;

        var mode: win.DWORD = 1;
        _ = ws2.ioctlsocket(sock, ws2.FIONBIO, &mode);

        var addr: ws2.sockaddr.in = std.mem.zeroes(ws2.sockaddr.in);
        addr.family = ws2.AF.INET;
        addr.port = ws2.htons(port);
        addr.addr = parseAddr(host);

        if (ws2.bind(sock, @ptrCast(&addr), @sizeOf(ws2.sockaddr.in)) != 0) {
            _ = ws2.closesocket(sock);
            return SocketError.BindFailed;
        }

        return sock;
    }

    fn initPosix(host: []const u8, port: u16) !usize {
        const sock = try posix.socket(posix.AF.INET, posix.SOCK_DGRAM, 0);
        const flags = try posix.fcntl(sock, posix.F.GETFL, 0);
        _ = try posix.fcntl(sock, posix.F.SETFL, flags | posix.O.NONBLOCK);

        var addr: posix.sockaddr_in = std.mem.zeroes(posix.sockaddr_in);
        addr.sin_family = posix.AF.INET;
        addr.sin_port = posix.htons(port);
        addr.sin_addr.s_addr = parseAddr(host);

        try posix.bind(sock, @ptrCast(&addr), @sizeOf(posix.sockaddr_in));
        return @intCast(sock);
    }

    pub fn init(host: []const u8, port: u16) !Socket {
        return .{
            .handle = if (builtin.os.tag == .windows)
                try initWin(host, port)
            else
                try initPosix(host, port),
        };
    }

    fn receiveFromPosix(self: *Socket, buf: []u8) !?RecvResult {
        var storage: posix.sockaddr_storage = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr_storage);

        const n = posix.recvfrom(
            @intCast(self.handle),
            buf,
            0,
            @ptrCast(&storage),
            &addr_len,
        ) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => return SocketError.ReceiveFailed,
        };

        if (n == 0) return null;

        const addr = try std.net.Address.fromSockAddr(
            @ptrCast(&storage),
            addr_len,
        );

        return .{
            .len = @intCast(n),
            .addr = addr,
        };
    }

    fn receiveFromWin(self: *Socket, buf: []u8) !?RecvResult {
        var from: ws2.sockaddr.in = undefined;
        var fromlen: c_int = @sizeOf(ws2.sockaddr.in);

        const n = ws2.recvfrom(
            self.handle,
            buf.ptr,
            @intCast(buf.len),
            0,
            @ptrCast(&from),
            &fromlen,
        );

        if (n == ws2.SOCKET_ERROR) {
            if (ws2.WSAGetLastError() == ws2.WinsockError.WSAEWOULDBLOCK)
                return null;
            return SocketError.ReceiveFailed;
        }

        if (n == 0) return null;

        const addr = std.net.Address.initIp4(
            .{
                @intCast(from.addr & 0xff),
                @intCast((from.addr >> 8) & 0xff),
                @intCast((from.addr >> 16) & 0xff),
                @intCast((from.addr >> 24) & 0xff),
            },
            ws2.ntohs(from.port),
        );

        return .{
            .len = @intCast(n),
            .addr = addr,
        };
    }

    pub fn receiveFrom(self: *Socket, buf: []u8) !?RecvResult {
        return if (builtin.os.tag == .windows)
            try receiveFromWin(self, buf)
        else
            try receiveFromPosix(self, buf);
    }

    fn sendToWin(self: *Socket, buf: []const u8, addr: std.net.Address) !void {
        const sent = ws2.sendto(
            self.handle,
            buf.ptr,
            @intCast(buf.len),
            0,
            @ptrCast(&addr),
            @intCast(@sizeOf(ws2.sockaddr.in)),
        );

        if (sent == ws2.SOCKET_ERROR) return SocketError.ReceiveFailed;
        return;
    }

    fn sendToPosix(self: *Socket, buf: []const u8, addr: std.net.Address) !void {
        const sent = try posix.sendto(
            @intCast(self.handle),
            buf.ptr,
            buf.len,
            0,
            @ptrCast(&addr),
            @sizeOf(posix.sockaddr_in),
        );

        if (sent == -1) return SocketError.ReceiveFailed;
    }

    pub fn sendTo(self: *Socket, buf: []const u8, addr: std.net.Address) !void {
        return if (builtin.os.tag == .windows)
            try self.sendToWin(buf, addr)
        else
            try self.sendToPosix(buf, addr);
    }

    pub fn deinit(self: *Socket) void {
        if (builtin.os.tag == .windows) {
            _ = ws2.closesocket(self.handle);
            _ = ws2.WSACleanup();
        } else {
            _ = posix.close(@intCast(self.handle));
        }
    }
};
