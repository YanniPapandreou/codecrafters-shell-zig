const std = @import("std");

var stdout_writer = std.fs.File.stdout().writerStreaming(&.{});
const stdout = &stdout_writer.interface;

var stdin_buffer: [4096]u8 = undefined;
var stdin_reader = std.fs.File.stdin().readerStreaming(&stdin_buffer);
const stdin = &stdin_reader.interface;

pub fn main() !void {
    // Print the prompt
    try stdout.print("$ ", .{});

    // Capture the user's command
    const command = try stdin.takeDelimiter('\n');
    try stdout.print("{s}: command not found\n", .{command.?});
}
