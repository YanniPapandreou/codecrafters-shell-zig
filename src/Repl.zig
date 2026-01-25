const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const builtins = @import("builtins.zig");
const History = builtins.History;
const utils = @import("utils.zig");

const ReplSignal = enum {
    Exit,
    Continue,
};

// import c readline headers
const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("readline/readline.h");
    @cInclude("readline/history.h");
});

const Repl = @This();

allocator: Allocator,
prompt: []const u8,
history: History,
in: *std.Io.Reader,
out: *std.Io.Writer,

pub fn init(allocator: Allocator, prompt: []const u8, in: *std.Io.Reader, out: *std.Io.Writer) !Repl {
    var history = try History.init(allocator);
    // try to load history from file specified by env var HISTFILE (if exists)
    try history.startup();
    history.save_loc += history.entries.items.len;

    return Repl{
        .allocator = allocator,
        .prompt = prompt,
        .history = history,
        .in = in,
        .out = out,
    };
}

pub fn deinit(self: *Repl) void {
    defer self.history.deinit();
}

pub fn readLine(self: *Repl) ![]const u8 {
    // Use readline for input with prompt
    const c_prompt: [:0]const u8 = @ptrCast(self.prompt);
    const c_input = c.readline(c_prompt);
    if (c_input == null) {
        return "exit";
    }

    // Convert C string to Zig slice
    const command = std.mem.span(c_input);
    if (command.len == 0) {
        return "continue";
    }

    // Add to readline's in-memory history
    _ = c.add_history(c_input);

    // Add to our own history builtin
    try self.history.append(command);
    return command;
}

pub fn process_line(self: *Repl, line: []const u8) !ReplSignal {
    if (mem.eql(u8, line, "exit")) {
        return .Exit;
    } else if (mem.eql(u8, line, "continue")) {
        return .Continue;
    } else if (mem.eql(u8, line, "pwd")) {
        try builtins.pwd(self.allocator, self.out);
    } else if (mem.startsWith(u8, line, "echo")) {
        const args = try utils.get_args("echo", line);
        try builtins.echo(self.out, args);
    } else if (mem.startsWith(u8, line, "history")) {
        const args = try utils.get_args("history", line);
        try builtins.history(self.out, &self.history, args);
    } else if (mem.startsWith(u8, line, "type")) {
        const args = try utils.get_args("type", line);
        try builtins.type_of_cmd(self.allocator, self.out, args);
    } else if (mem.startsWith(u8, line, "cd")) {
        const args = try utils.get_args("cd", line);
        try builtins.cd(self.allocator, self.out, args);
    } else {
        const external_cmd = utils.parse_external(line) orelse return .Continue;
        try utils.run_external(self.allocator, self.out, external_cmd);
    }
    return .Continue;
}

pub fn run(self: *Repl) !void {
    while (true) {
        const line = self.readLine() catch |err| {
            _ = try self.out.print("Error {s}\n", .{@errorName(err)});
            continue;
        };
        const signal = self.process_line(line) catch |err| {
            _ = try self.out.print("Error: {s}\n", .{@errorName(err)});
            continue;
        };
        switch (signal) {
            .Continue => {},
            .Exit => break,
        }
    }
}
