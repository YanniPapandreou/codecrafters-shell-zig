const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const builtins = @import("builtins.zig");
const History = builtins.History;

const Parser = @import("Parser.zig");
const ParsedCommand = Parser.ParsedCommand;

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
parser: Parser,
in: *std.Io.Reader,
out: *std.Io.Writer,

pub fn init(allocator: Allocator, prompt: []const u8, in: *std.Io.Reader, out: *std.Io.Writer) !Repl {
    var history = try History.init(allocator);
    // try to load history from file specified by env var HISTFILE (if exists)
    try history.startup();
    history.save_loc += history.entries.items.len;
    const parser = Parser.init(allocator);

    return Repl{
        .allocator = allocator,
        .prompt = prompt,
        .history = history,
        .parser = parser,
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
        return "";
    }

    // Add to readline's in-memory history
    _ = c.add_history(c_input);

    // Add to our own history builtin
    try self.history.append(command);
    return command;
}

fn process_line(self: *Repl, line: []const u8) !ReplSignal {
    const processed_cmd = try self.parser.parse(line);
    defer self.allocator.free(processed_cmd.args);
    if (processed_cmd.is_builtin) {
        if (mem.eql(u8, processed_cmd.cmd, "exit")) {
            return .Exit;
        } else if (mem.eql(u8, processed_cmd.cmd, "NoOp")) {
            return .Continue;
        } else if (mem.eql(u8, processed_cmd.cmd, "pwd")) {
            try builtins.pwd(self.allocator, self.out);
        } else if (mem.eql(u8, processed_cmd.cmd, "echo")) {
            try builtins.echo(self.allocator, self.out, processed_cmd.args);
        } else if (mem.eql(u8, processed_cmd.cmd, "history")) {
            try builtins.history(self.out, &self.history, processed_cmd.args);
        } else if (mem.eql(u8, processed_cmd.cmd, "type")) {
            try builtins.type_of_cmd(self.allocator, self.out, processed_cmd.args);
        } else if (mem.eql(u8, processed_cmd.cmd, "cd")) {
            try builtins.cd(self.allocator, self.out, processed_cmd.args);
        }
    } else {
        try builtins.run_external(self.allocator, self.out, processed_cmd);
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
