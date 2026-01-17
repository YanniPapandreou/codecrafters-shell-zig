const std = @import("std");
const mem = std.mem;
const utils = @import("utils");

const ParserError = utils.ParserError;
const RuntimeError = utils.RuntimeError;

pub const History = struct {
    allocator: mem.Allocator,
    history: std.ArrayList([]const u8),

    pub fn init(allocator: mem.Allocator) !History {
        const hist = try std.ArrayList([]const u8).initCapacity(allocator, 0);
        return History{
            .allocator = allocator,
            .history = hist,
        };
    }

    pub fn deinit(self: *History) void {
        for (self.history.items) |line| {
            self.allocator.free(line);
        }
        self.history.deinit(self.allocator);
    }

    pub fn append(self: *History, input: []const u8) !void {
        const input_copy = try self.allocator.alloc(u8, input.len);
        @memcpy(input_copy, input);
        try self.history.append(self.allocator, input_copy);
    }

    fn print(self: *History, writer: *std.io.Writer) !void {
        for (self.history.items, 1..) |entry, i| {
            try writer.print("   {d}  {s}\n", .{i, entry});
        }
    }
};

pub fn echo(writer: *std.io.Writer, args: []const u8) !void {
    try writer.print("{s}\n", .{args});
}

pub fn history(writer: *std.io.Writer, hist: *History) !void {
    try hist.print(writer);
}

pub fn type_of_cmd(allocator: mem.Allocator, writer: *std.io.Writer, args: []const u8) !void {
    if (mem.containsAtLeastScalar(u8, args, 1, ' ')) {
        try writer.print("Error: `type` only accepts 1 argument\n", .{});
        return ParserError.TooManyArgs;
    }
    if (mem.eql(u8, args, "exit") or
        mem.eql(u8, args, "echo") or
        mem.eql(u8, args, "history") or
        mem.eql(u8, args, "type"))
    {
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
