const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const builtins = @import("builtins.zig");
const History = builtins.History;

const Parser = @import("Parser.zig");
const ParsedCommand = Parser.ParsedCommand;
const ParserError = Parser.ParserError;
const Redirect = Parser.Redirect;
const Writers = builtins.Writers;
const Output = builtins.Output;

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

const builtin_cmds = [_][]const u8{ "echo", "exit" };

// Completion generator for readline
fn completion_generator(text: [*c]const u8, state: c_int) callconv(.c) [*c]u8 {
    // static variable to keep track of which match we're on
    // (Readline calls this repeatedly with incrementing state)
    const gpa = std.heap.c_allocator;
    var match_index: usize = @intCast(state);
    while (match_index < builtin_cmds.len) : (match_index += 1) {
        const cmd = builtin_cmds[match_index];
        if (std.mem.startsWith(u8, cmd, std.mem.span(text))) {
            // Allocate a C string with a trailing space
            const len = cmd.len + 2; // +1 for space, +1 for null terminator
            var buf = gpa.alloc(u8, len) catch return null;
            @memcpy(buf[0..cmd.len], cmd);
            buf[cmd.len] = ' ';
            buf[cmd.len + 1] = 0;
            return buf.ptr;
        }
    }
    return null;
}

// Completion entry point for readline
fn zig_completion(text: [*c]const u8, start: c_int, end: c_int) callconv(.c) [*c][*c]u8 {
    _ = start; _ = end;
    return c.rl_completion_matches(text, completion_generator);
}

pub fn setup_readline_completion() void {
    // Set the attempted completion function
    c.rl_attempted_completion_function = zig_completion;
}

pub fn init(allocator: Allocator, prompt: []const u8, in: *std.Io.Reader, out: *std.Io.Writer) !Repl {
    // Setup completion with readline
    setup_readline_completion();

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

fn readLine(self: *Repl) ![]const u8 {
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

fn get_writers(self: *Repl, maybe_redirect: ?Redirect) !Writers {
    if (maybe_redirect) |redirect| {
        if (redirect.out_file) |out_file| {
            const file = try std.fs.cwd().createFile(out_file, .{
                .truncate = if (redirect.append) false else true,
            });
            if (redirect.append) {
                // go to end of file to append
                try file.seekFromEnd(0);
            }
            const out_output = Output{ .file = file };
            return Writers{
                .out = out_output,
                .err = Output{ .default = self.out },
            };
        } else if (redirect.err_file) |err_file| {
            const file = try std.fs.cwd().createFile(err_file, .{
                .truncate = if (redirect.append) false else true,
            });
            if (redirect.append) {
                // go to end of file to append
                try file.seekFromEnd(0);
            }
            const err_output = Output{ .file = file };
            return Writers{
                .out = Output{ .default = self.out },
                .err = err_output,
            };
        } else {
            return ParserError.BadRedirect;
        }
    }
    return Writers{
        .out = Output{ .default = self.out },
        .err = Output{ .default = self.out },
    };
}

fn process_line(self: *Repl, line: []const u8) !ReplSignal {
    const processed_cmd = try self.parser.parse(line);
    defer self.allocator.free(processed_cmd.args);
    var writers = try self.get_writers(processed_cmd.redirect);
    defer writers.deinit();
    if (processed_cmd.is_builtin) {
        if (mem.eql(u8, processed_cmd.cmd, "exit")) {
            return .Exit;
        } else if (mem.eql(u8, processed_cmd.cmd, "NoOp")) {
            return .Continue;
        } else if (mem.eql(u8, processed_cmd.cmd, "pwd")) {
            try builtins.pwd(self.allocator, &writers);
        } else if (mem.eql(u8, processed_cmd.cmd, "echo")) {
            try builtins.echo(self.allocator, &writers, processed_cmd.args);
        } else if (mem.eql(u8, processed_cmd.cmd, "history")) {
            try builtins.history(&writers, &self.history, processed_cmd.args);
        } else if (mem.eql(u8, processed_cmd.cmd, "type")) {
            try builtins.type_of_cmd(self.allocator, &writers, processed_cmd.args);
        } else if (mem.eql(u8, processed_cmd.cmd, "cd")) {
            try builtins.cd(self.allocator, &writers, processed_cmd.args);
        }
    } else {
        try builtins.run_external(self.allocator, &writers, processed_cmd);
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
