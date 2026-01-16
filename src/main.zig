const std = @import("std");

var stdout_writer = std.fs.File.stdout().writerStreaming(&.{});
const stdout = &stdout_writer.interface;

var stdin_buffer: [4096]u8 = undefined;
var stdin_reader = std.fs.File.stdin().readerStreaming(&stdin_buffer);
const stdin = &stdin_reader.interface;

const ParserError = error {InvalidInput};

fn get_args(cmd: []const u8, input: []const u8) ParserError![]const u8 {
    const cmd_len = cmd.len + 1;
    if (cmd_len >= input.len) {
        return ParserError.InvalidInput;
    }
    return input[cmd_len..];
}

fn echo(writer: *std.io.Writer, input: []const u8) !void {
    try writer.print("{s}\n", .{input});
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
            } else if (std.mem.startsWith(u8, cmd, "echo ")) {
                const args = try get_args("echo", cmd);
                try echo(stdout, args);
            } else {
                try stdout.print("{s}: command not found\n", .{cmd});
            }
        }
    }
}
