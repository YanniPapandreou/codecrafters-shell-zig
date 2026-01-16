const std = @import("std");

var stdout_writer = std.fs.File.stdout().writerStreaming(&.{});
const stdout = &stdout_writer.interface;

var stdin_buffer: [4096]u8 = undefined;
var stdin_reader = std.fs.File.stdin().readerStreaming(&stdin_buffer);
const stdin = &stdin_reader.interface;

const ParserError = error{ InvalidArgs, TooManyArgs };

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

fn type_of_cmd(writer: *std.io.Writer, args: []const u8) !void {
    if (std.mem.containsAtLeastScalar(u8, args, 1, ' ')) {
        try writer.print("Error: `type` only accepts 1 argument\n", .{});
        return ParserError.TooManyArgs;
    }
    if (std.mem.eql(u8, args, "exit") or std.mem.eql(u8, args, "echo") or std.mem.eql(u8, args, "type")) {
        try writer.print("{s} is a shell builtin\n", .{args});
    } else {
        try writer.print("{s}: not found\n", .{args});
    }
}

pub fn main() !void {
    while (true) {
        // Print the prompt
        try stdout.print("$ ", .{});

        // Capture the user's command
        const command = try stdin.takeDelimiter('\n');

        if (command) |cmd| {
            if (std.mem.eql(u8, cmd, "exit")) {
                break;
            } else if (std.mem.startsWith(u8, cmd, "echo")) {
                const args = try get_args("echo", cmd);
                try echo(stdout, args);
            } else if (std.mem.startsWith(u8, cmd, "type")) {
                const args = try get_args("type", cmd);
                try type_of_cmd(stdout, args);
            } else {
                try stdout.print("{s}: command not found\n", .{cmd});
            }
        }
    }
}
