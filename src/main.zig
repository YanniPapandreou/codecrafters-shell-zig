const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;

pub const pathListSep: u8 = if (builtin.os.tag == .windows) ';' else ':';

var stdout_writer = std.fs.File.stdout().writerStreaming(&.{});
const stdout = &stdout_writer.interface;

var stdin_buffer: [4096]u8 = undefined;
var stdin_reader = std.fs.File.stdin().readerStreaming(&stdin_buffer);
const stdin = &stdin_reader.interface;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const repl_allocator = gpa.allocator();

const ParserError = error{ InvalidArgs, TooManyArgs };
const RuntimeError = error{CommandNotFound};

fn get_args(cmd: []const u8, input: []const u8) ParserError![]const u8 {
    const cmd_len = cmd.len + 1;
    if (cmd_len >= input.len) {
        return ParserError.InvalidArgs;
    }
    return input[cmd_len..];
}

fn echo(writer: *std.io.Writer, args: []const u8) !void {
    try writer.print("{s}\n", .{args});
}

fn get_path(allocator: mem.Allocator) ![]u8 {
    const PATH = try std.process.getEnvVarOwned(allocator, "PATH");
    return PATH;
}

fn search_path(allocator: mem.Allocator, path: []u8, cmd: []const u8) ![]u8 {
    var it = mem.splitScalar(u8, path, pathListSep);
    while (it.next()) |p| {
        var dir = std.fs.openDirAbsolute(p, .{ .iterate = true }) catch |err| {
            switch (err) {
                error.FileNotFound => continue,
                else => unreachable,
            }
        };
        defer dir.close();
        var iter_dir = dir.iterate();
        while (try iter_dir.next()) |entry| {
            if (entry.kind == .file and mem.eql(u8, entry.name, cmd)) {
                const cmd_stat = try dir.statFile(entry.name);
                if ((cmd_stat.mode & 0o111) != 0) {
                    const cmd_path = try std.fs.path.join(allocator, &[_][]const u8{ p, entry.name });
                    return cmd_path;
                } else {
                    continue;
                }
            }
        }
    }
    return RuntimeError.CommandNotFound;
}

fn type_of_cmd(allocator: mem.Allocator, writer: *std.io.Writer, args: []const u8) !void {
    if (mem.containsAtLeastScalar(u8, args, 1, ' ')) {
        try writer.print("Error: `type` only accepts 1 argument\n", .{});
        return ParserError.TooManyArgs;
    }
    if (mem.eql(u8, args, "exit") or mem.eql(u8, args, "echo") or mem.eql(u8, args, "type")) {
        try writer.print("{s} is a shell builtin\n", .{args});
    } else {
        const PATH = try get_path(allocator);
        defer allocator.free(PATH);
        const full_path = search_path(allocator, PATH, args) catch |err| {
            switch (err) {
                RuntimeError.CommandNotFound => {
                    try writer.print("{s}: not found\n", .{args});
                    return;
                },
                else => unreachable,
            }
        };
        try writer.print("{s} is {s}\n", .{ args, full_path });
    }
}

pub fn main() !void {
    while (true) {
        // Print the prompt
        try stdout.print("$ ", .{});

        // Capture the user's command
        const command = try stdin.takeDelimiter('\n');

        if (command) |cmd| {
            if (mem.eql(u8, cmd, "exit")) {
                break;
            } else if (mem.startsWith(u8, cmd, "echo")) {
                const args = try get_args("echo", cmd);
                try echo(stdout, args);
            } else if (mem.startsWith(u8, cmd, "type")) {
                const args = try get_args("type", cmd);
                try type_of_cmd(repl_allocator, stdout, args);
            } else {
                try stdout.print("{s}: command not found\n", .{cmd});
            }
        }
    }
}
