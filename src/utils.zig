const std = @import("std");
const mem = std.mem;
const builtin = @import("builtin");

pub const ParserError = error{ InvalidArgs, TooManyArgs, EmptyInput, BadInput, WrongNumberOfArgs };
pub const RuntimeError = error{ CommandNotFound, InvalidArgs };

pub const ArgList = [][]const u8;
const ExternalCommand = struct { cmd: []const u8, args: ArgList };

const pathListSep: u8 = if (builtin.os.tag == .windows) ';' else ':';

pub fn get_args_str(cmd: []const u8, input: []const u8) ParserError![]const u8 {
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
pub fn get_args(allocator: mem.Allocator, args_str: []const u8) !ArgList {
    var args = std.ArrayList([]const u8).empty;
    var single_quote_open: bool = false;
    var double_quote_open: bool = false;
    var arg = std.ArrayList(u8).empty;
    for (args_str) |c| {
        switch (c) {
            '\'' => {
                if (!double_quote_open) {
                    single_quote_open = !single_quote_open;
                } else {
                    try arg.append(allocator, c);
                }
            },
            '"' => {
                if (!single_quote_open) {
                    double_quote_open = !double_quote_open;
                } else {
                    try arg.append(allocator, c);
                }
            },
            ' ' => {
                if (single_quote_open or double_quote_open) {
                    try arg.append(allocator, c);
                } else if (arg.items.len > 0) {
                    // End of an argument
                    const new_arg = try arg.toOwnedSlice(allocator);
                    try args.append(allocator, new_arg);
                    arg.clearRetainingCapacity();
                    // Do not append empty arguments for consecutive spaces
                }
            },
            else => {
                try arg.append(allocator, c);
            },
        }
    }
    if (arg.items.len > 0) {
        const final_arg = try arg.toOwnedSlice(allocator);
        try args.append(allocator, final_arg);
    }
    return args.toOwnedSlice(allocator);
}

fn get_path(allocator: mem.Allocator) ![]u8 {
    const PATH = try std.process.getEnvVarOwned(allocator, "PATH");
    return PATH;
}

pub fn search_path(allocator: mem.Allocator, path: []u8, cmd: []const u8) ![]u8 {
    var it = mem.splitScalar(u8, path, pathListSep);
    while (it.next()) |p| {
        var dir = std.fs.openDirAbsolute(p, .{ .iterate = true }) catch |err| {
            switch (err) {
                error.FileNotFound => continue,
                else => unreachable,
            }
        };
        defer dir.close();
        var iter_dir = dir.iterate();
        while (try iter_dir.next()) |entry| {
            if (entry.kind == .file and mem.eql(u8, entry.name, cmd)) {
                const cmd_stat = try dir.statFile(entry.name);
                if ((cmd_stat.mode & 0o111) != 0) {
                    const cmd_path = try std.fs.path.join(allocator, &[_][]const u8{ p, entry.name });
                    return cmd_path;
                } else {
                    continue;
                }
            }
        }
    }
    return RuntimeError.CommandNotFound;
}

pub fn find_exec(allocator: mem.Allocator, cmd: []const u8) ![]u8 {
    const PATH = try get_path(allocator);
    defer allocator.free(PATH);
    return search_path(allocator, PATH, cmd);
}

pub fn parse_external(allocator: mem.Allocator, input: []const u8) !?ExternalCommand {
    if (input.len == 0) {
        return null;
    }
    const space_pos_result = mem.indexOf(u8, input, " ");
    if (space_pos_result) |i| {
        const cmd = input[0..i];
        const args_str = input[i + 1 ..];
        const args = try get_args(allocator, args_str);
        return ExternalCommand{ .cmd = cmd, .args = args };
    }
    return ExternalCommand{ .cmd = input, .args = &[_][]const u8{} };
}

pub fn run_external(allocator: mem.Allocator, writer: *std.Io.Writer, external_cmd: ExternalCommand) !void {
    const full_path = find_exec(allocator, external_cmd.cmd) catch |err| {
        switch (err) {
            RuntimeError.CommandNotFound => {
                try writer.print("{s}: not found\n", .{external_cmd.cmd});
                return;
            },
            else => unreachable,
        }
    };
    defer allocator.free(full_path);
    defer allocator.free(external_cmd.args);
    var argv = try std.ArrayList([]const u8).initCapacity(allocator, 1 + external_cmd.args.len);
    defer argv.deinit(allocator);
    argv.appendAssumeCapacity(external_cmd.cmd);
    argv.appendSliceAssumeCapacity(external_cmd.args);
    const proc = try std.process.Child.run(.{
        .argv = argv.items,
        .allocator = allocator,
    });

    // on success, we own the output streams
    defer allocator.free(proc.stdout);
    defer allocator.free(proc.stderr);

    switch (proc.term) {
        .Exited => |code| {
            if (code == 0) {
                try writer.print("{s}", .{proc.stdout});
            } else {
                try writer.print("{s}", .{proc.stderr});
            }
        },
        else => {
            try writer.print("External process terminated abnormally", .{});
            try writer.print("{s}", .{proc.stderr});
        },
    }
}
