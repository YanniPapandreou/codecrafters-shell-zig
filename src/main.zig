const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const builtins = @import("builtins");
const utils = @import("utils");
const History = builtins.History;

// import c readline headers
const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("readline/readline.h");
    @cInclude("readline/history.h");
});

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
        // Use readline for input with prompt
        const prompt = "$ ";
        const c_input = c.readline(prompt);
        if (c_input == null) break; // EOF (Ctrl-D)

        defer c.free(c_input);

        // Convert C string to Zig slice
        const command = std.mem.span(c_input);
        if (command.len == 0) continue;

        // Add to readline's in-memory history
        _ = c.add_history(c_input);

        try repl_history.append(command);
        if (mem.eql(u8, command, "exit")) {
            break;
        } else if (mem.startsWith(u8, command, "echo")) {
            const args = try utils.get_args("echo", command);
            try builtins.echo(stdout, args);
        } else if (mem.startsWith(u8, command, "history")) {
            const args = try utils.get_args("history", command);
            try builtins.history(stdout, &repl_history, args);
        } else if (mem.startsWith(u8, command, "type")) {
            const args = try utils.get_args("type", command);
            try builtins.type_of_cmd(repl_allocator, stdout, args);
        } else {
            const external_cmd = utils.parse_external(command) orelse continue;
            try utils.run_external(repl_allocator, stdout, external_cmd);
        }
    }
}
