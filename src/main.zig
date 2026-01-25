const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const core = @import("core");
const Repl = core.Repl;

var stdout_writer = std.fs.File.stdout().writerStreaming(&.{});
const stdout = &stdout_writer.interface;

var stdin_buffer: [4096]u8 = undefined;
var stdin_reader = std.fs.File.stdin().readerStreaming(&stdin_buffer);
const stdin = &stdin_reader.interface;

// var gpa = std.heap.GeneralPurposeAllocator(.{}){};
// const allocator = gpa.allocator();
var dba = std.heap.DebugAllocator(.{}){};
const allocator = dba.allocator();

pub fn main() !void {
    const prompt = "$ ";
    var repl = try Repl.init(allocator, prompt, stdin, stdout);
    defer repl.deinit();
    try repl.run();
}
