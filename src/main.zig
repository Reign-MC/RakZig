const std = @import("std");

const Server = @import("RakZig").Server;
const Options = @import("RakZig").Options;

const Connection = @import("RakZig").Connection;

fn onGamePacket(conn: *Connection, payload: []const u8) void {
    std.debug.print("GamePacket received, guid={d} len={d} data={any}\n", .{ conn.guid, payload.len, payload });
}

fn onConnect(conn: *Connection) void {
    std.debug.print("Client connected, guid: {d}\n", .{conn.guid});
    conn.onGamePacket(onGamePacket);
}

fn onDisconnect(conn: *Connection) void {
    std.debug.print("Client disconnected, guid: {d}\n", .{conn.guid});
}

pub fn main() void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var server = Server.init(.{}, allocator) catch |err| {
        std.debug.print("Error initializing server: {}", .{err});
        return;
    };
    defer server.deinit();

    server.onConnect(onConnect);
    server.onDisconnect(onDisconnect);

    server.start() catch |err| {
        std.debug.print("Error starting server: {any}", .{err});
        return;
    };

    server.listen() catch |err| {
        std.debug.print("Error listening: {}", .{err});
        return;
    };
}
