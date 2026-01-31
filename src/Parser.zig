const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

const Parser = @This();
pub const ParserError = error{ InvalidArgs, TooManyArgs, EmptyInput, BadInput, WrongNumberOfArgs };

pub const ArgList = [][]const u8;
pub const Redirect = struct {
    cleaned_input: []const u8,
    to_file: []const u8,
    append: bool = false,
};

pub const ParsedCommand = struct {
    cmd: []const u8,
    args: ArgList,
    is_builtin: bool,
    redirection: ?Redirect,
};

pub const NoOpCommand = ParsedCommand{
    .cmd = "NoOp",
    .args = &[_][]const u8{},
    .is_builtin = true,
    .redirection = null,
};

allocator: Allocator,

pub fn init(allocator: Allocator) Parser {
    return Parser{
        .allocator = allocator,
    };
}

fn parse_redirect(_: *Parser, input: []const u8) !?Redirect {
    if (mem.containsAtLeast(u8, input, 1, " 1> ")) {
        var it = mem.splitSequence(u8, input, " 1> ");
        const cleaned_input = it.first();
        const to_file = it.next().?;
        // Should be only one redirection
        if (it.next()) |_| {
            return ParserError.BadInput;
        }
        return Redirect{
            .cleaned_input = cleaned_input,
            .to_file = to_file,
            .append = false,
        };
    } else if (mem.containsAtLeast(u8, input, 1, " > ")) {
        var it = mem.splitSequence(u8, input, " > ");
        const cleaned_input = it.first();
        const to_file = it.next().?;
        // Should be only one redirection
        if (it.next()) |_| {
            return ParserError.BadInput;
        }
        return Redirect{
            .cleaned_input = cleaned_input,
            .to_file = to_file,
            .append = false,
        };
    } else {
        return null;
    }
}

fn get_args_str(_: *Parser, cmd: []const u8, input: []const u8) ParserError![]const u8 {
    if (!mem.containsAtLeast(u8, input, 1, cmd)) {
        return ParserError.BadInput;
    }
    if (mem.eql(u8, input, cmd)) {
        return "";
    }
    const cmd_len = cmd.len + 1;
    if (cmd_len >= input.len) {
        return ParserError.InvalidArgs;
    }
    return input[cmd_len..];
}

// parses arguments, handling single quotes for grouping; caller owns memory of returned ArgList
fn get_args(self: *Parser, args_str: []const u8) !ArgList {
    var args = std.ArrayList([]const u8).empty;
    var single_quote_open: bool = false;
    var double_quote_open: bool = false;
    var arg = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < args_str.len) : (i += 1) {
        const c = args_str[i];
        switch (c) {
            '\\' => {
                if (single_quote_open) {
                    // append this backslash literally
                    try arg.append(self.allocator, c);
                } else {
                    // escape next character
                    try arg.append(self.allocator, args_str[i + 1]);
                    i += 1;
                }
            },
            '\'' => {
                if (!double_quote_open) {
                    single_quote_open = !single_quote_open;
                } else {
                    try arg.append(self.allocator, c);
                }
            },
            '"' => {
                if (!single_quote_open) {
                    double_quote_open = !double_quote_open;
                } else {
                    try arg.append(self.allocator, c);
                }
            },
            ' ' => {
                if (single_quote_open or double_quote_open) {
                    try arg.append(self.allocator, c);
                } else if (arg.items.len > 0) {
                    // End of an argument
                    const new_arg = try arg.toOwnedSlice(self.allocator);
                    try args.append(self.allocator, new_arg);
                    arg.clearRetainingCapacity();
                    // Do not append empty arguments for consecutive spaces
                }
            },
            else => {
                try arg.append(self.allocator, c);
            },
        }
    }
    if (arg.items.len > 0) {
        const final_arg = try arg.toOwnedSlice(self.allocator);
        try args.append(self.allocator, final_arg);
    }
    return args.toOwnedSlice(self.allocator);
}

fn parse_external(self: *Parser, input: []const u8) !ParsedCommand {
    if (input.len == 0) {
        return NoOpCommand;
    }
    const redirect = try self.parse_redirect(input);
    const line = if (redirect) |r|
        r.cleaned_input
    else
        input;
    if (line[0] == '\'' or line[0] == '"') {
        const closing_quote_pos = mem.indexOf(u8, line[1..], &[_]u8{line[0]});
        if (closing_quote_pos) |i| {
            const cmd = line[1 .. i + 1];
            const args_str = line[i + 2 ..];
            const args = try self.get_args(args_str);
            return ParsedCommand{
                .cmd = cmd,
                .args = args,
                .is_builtin = false,
                .redirection = redirect,
            };
        } else {
            return ParserError.BadInput;
        }
    }
    const space_pos_result = mem.indexOf(u8, line, " ");
    if (space_pos_result) |i| {
        const cmd = line[0..i];
        const args_str = line[i + 1 ..];
        const args = try self.get_args(args_str);
        return ParsedCommand{
            .cmd = cmd,
            .args = args,
            .is_builtin = false,
            .redirection = redirect,
        };
    }
    return ParsedCommand{
        .cmd = line,
        .args = &[_][]const u8{},
        .is_builtin = false,
        .redirection = redirect,
    };
}

pub fn parse(self: *Parser, input: []const u8) !ParsedCommand {
    const redirect = try self.parse_redirect(input);
    const line = if (redirect) |r|
        r.cleaned_input
    else
        input;
    if (mem.eql(u8, line, "exit")) {
        return ParsedCommand{
            .cmd = "exit",
            .args = &[_][]const u8{},
            .is_builtin = true,
            .redirection = redirect,
        };
    } else if (mem.eql(u8, line, "")) {
        return NoOpCommand;
    } else if (mem.eql(u8, line, "pwd")) {
        return ParsedCommand{
            .cmd = "pwd",
            .args = &[_][]const u8{},
            .is_builtin = true,
            .redirection = redirect,
        };
    } else if (mem.startsWith(u8, line, "echo")) {
        const args_str = try self.get_args_str("echo", line);
        const args = try self.get_args(args_str);
        return ParsedCommand{
            .cmd = "echo",
            .args = args,
            .is_builtin = true,
            .redirection = redirect,
        };
    } else if (mem.startsWith(u8, line, "history")) {
        const args_str = try self.get_args_str("history", line);
        const args = try self.get_args(args_str);
        return ParsedCommand{
            .cmd = "history",
            .args = args,
            .is_builtin = true,
            .redirection = redirect,
        };
    } else if (mem.startsWith(u8, line, "type")) {
        const args_str = try self.get_args_str("type", line);
        const args = try self.get_args(args_str);
        return ParsedCommand{
            .cmd = "type",
            .args = args,
            .is_builtin = true,
            .redirection = redirect,
        };
    } else if (mem.startsWith(u8, line, "cd")) {
        const args_str = try self.get_args_str("cd", line);
        const args = try self.get_args(args_str);
        return ParsedCommand{
            .cmd = "cd",
            .args = args,
            .is_builtin = true,
            .redirection = redirect,
        };
    } else {
        const external_cmd = try self.parse_external(input);
        return external_cmd;
    }
}
