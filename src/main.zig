const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const builtins = @import("builtins");
const utils = @import("utils");
const History = builtins.History;

var stdout_writer = std.fs.File.stdout().writerStreaming(&.{});
const stdout = &stdout_writer.interface;

var stdin_buffer: [4096]u8 = undefined;
var stdin_reader = std.fs.File.stdin().readerStreaming(&stdin_buffer);
const stdin = &stdin_reader.interface;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const repl_allocator = gpa.allocator();

pub fn main() !void {
    var repl_history = try History.init(repl_allocator);
    defer repl_history.deinit();
    while (true) {
        // Print the prompt
        try stdout.print("$ ", .{});

        // Capture the user's command
        const command = try stdin.takeDelimiter('\n');

        if (command) |cmd| {
            try repl_history.append(cmd);
            if (mem.eql(u8, cmd, "exit")) {
                break;
            } else if (mem.startsWith(u8, cmd, "echo")) {
                const args = try utils.get_args("echo", cmd);
                try builtins.echo(stdout, args);
            } else if (mem.eql(u8, cmd, "history")) {
                try builtins.history(stdout, &repl_history);
            } else if (mem.startsWith(u8, cmd, "type")) {
                const args = try utils.get_args("type", cmd);
                try builtins.type_of_cmd(repl_allocator, stdout, args);
            } else {
                const external_cmd = utils.parse_external(cmd) orelse continue;
                try utils.run_external(repl_allocator, stdout, external_cmd);
            }
        }
    }
}
