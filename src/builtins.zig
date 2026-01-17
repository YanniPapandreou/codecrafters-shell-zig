const std = @import("std");
const mem = std.mem;
const utils = @import("utils");

const ParserError = utils.ParserError;
const RuntimeError = utils.RuntimeError;

pub fn echo(writer: *std.io.Writer, args: []const u8) !void {
    try writer.print("{s}\n", .{args});
}

pub fn type_of_cmd(allocator: mem.Allocator, writer: *std.io.Writer, args: []const u8) !void {
    if (mem.containsAtLeastScalar(u8, args, 1, ' ')) {
        try writer.print("Error: `type` only accepts 1 argument\n", .{});
        return ParserError.TooManyArgs;
    }
    if (mem.eql(u8, args, "exit") or mem.eql(u8, args, "echo") or mem.eql(u8, args, "type")) {
        try writer.print("{s} is a shell builtin\n", .{args});
    } else {
        const full_path = utils.find_exec(allocator, args) catch |err| {
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

