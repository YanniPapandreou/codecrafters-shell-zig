const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

const Parser = @This();
pub const ParserError = error{ InvalidArgs, TooManyArgs, EmptyInput, BadInput, WrongNumberOfArgs };

pub const ArgList = [][]const u8;
pub const Redirection = struct {
    to_file: ?[]const u8 = null,
    append: bool = false,
};

pub const ParsedCommand = struct {
    cmd: []const u8,
    args: ArgList,
    is_builtin: bool,
    redirection: Redirection,
};

pub const NoOpCommand = ParsedCommand{
    .cmd = "NoOp",
    .args = &[_][]const u8{},
    .is_builtin = true,
    .redirection = Redirection{},
};

allocator: Allocator,

pub fn init(allocator: Allocator) Parser {
    return Parser{
        .allocator = allocator,
    };
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
    if (input[0] == '\'' or input[0] == '"') {
        const closing_quote_pos = mem.indexOf(u8, input[1..], &[_]u8{input[0]});
        if (closing_quote_pos) |i| {
            const cmd = input[1 .. i + 1];
            const args_str = input[i + 2 ..];
            const args = try self.get_args(args_str);
            return ParsedCommand{
                .cmd = cmd,
                .args = args,
                .is_builtin = false,
                .redirection = Redirection{},
            };
        } else {
            return ParserError.BadInput;
        }
    }
    const space_pos_result = mem.indexOf(u8, input, " ");
    if (space_pos_result) |i| {
        const cmd = input[0..i];
        const args_str = input[i + 1 ..];
        const args = try self.get_args(args_str);
        return ParsedCommand{
            .cmd = cmd,
            .args = args,
            .is_builtin = false,
            .redirection = Redirection{},
        };
    }
    return ParsedCommand{
        .cmd = input,
        .args = &[_][]const u8{},
        .is_builtin = false,
        .redirection = Redirection{},
    };
}

pub fn parse(self: *Parser, input: []const u8) !ParsedCommand {
    if (mem.eql(u8, input, "exit")) {
        return ParsedCommand{
            .cmd = "exit",
            .args = &[_][]const u8{},
            .is_builtin = true,
            .redirection = Redirection{},
        };
    } else if (mem.eql(u8, input, "")) {
        return NoOpCommand;
    } else if (mem.eql(u8, input, "pwd")) {
        return ParsedCommand{
            .cmd = "pwd",
            .args = &[_][]const u8{},
            .is_builtin = true,
            .redirection = Redirection{},
        };
    } else if (mem.startsWith(u8, input, "echo")) {
        const args_str = try self.get_args_str("echo", input);
        const args = try self.get_args(args_str);
        return ParsedCommand{
            .cmd = "echo",
            .args = args,
            .is_builtin = true,
            .redirection = Redirection{},
        };
    } else if (mem.startsWith(u8, input, "history")) {
        const args_str = try self.get_args_str("history", input);
        const args = try self.get_args(args_str);
        return ParsedCommand{
            .cmd = "history",
            .args = args,
            .is_builtin = true,
            .redirection = Redirection{},
        };
    } else if (mem.startsWith(u8, input, "type")) {
        const args_str = try self.get_args_str("type", input);
        const args = try self.get_args(args_str);
        return ParsedCommand{
            .cmd = "type",
            .args = args,
            .is_builtin = true,
            .redirection = Redirection{},
        };
    } else if (mem.startsWith(u8, input, "cd")) {
        const args_str = try self.get_args_str("cd", input);
        const args = try self.get_args(args_str);
        return ParsedCommand{
            .cmd = "cd",
            .args = args,
            .is_builtin = true,
            .redirection = Redirection{},
        };
    } else {
        const external_cmd = try self.parse_external(input);
        return external_cmd;
    }
}
