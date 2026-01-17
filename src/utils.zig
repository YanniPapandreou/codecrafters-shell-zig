const std = @import("std");
const mem = std.mem;
const builtin = @import("builtin");

pub const ParserError = error{ InvalidArgs, TooManyArgs, EmptyInput, BadInput };
pub const RuntimeError = error{CommandNotFound};

pub const ExternalCommand = struct { cmd: []const u8, args: ?[]const u8 };

pub const pathListSep: u8 = if (builtin.os.tag == .windows) ';' else ':';

pub fn get_args(cmd: []const u8, input: []const u8) ParserError![]const u8 {
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

pub fn parse_external(input: []const u8) ?ExternalCommand {
    if (input.len == 0) {
        return null;
    }
    if (mem.containsAtLeastScalar(u8, input, 1, ' ')) {
        var it = mem.splitScalar(u8, input, ' ');
        return ExternalCommand{ .cmd = it.first(), .args = it.rest() };
    }
    return ExternalCommand{ .cmd = input, .args = null };
}


pub fn run_external(allocator: mem.Allocator, writer: *std.io.Writer, external_cmd: ExternalCommand) !void {
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
    var argv = try std.ArrayList([]const u8).initCapacity(allocator, 1);
    argv.appendAssumeCapacity(external_cmd.cmd);
    defer argv.deinit(allocator);
    if (external_cmd.args) |args| {
        var it = mem.splitScalar(u8, args, ' ');
        while (it.next()) |arg| {
            try argv.append(allocator, arg);
        }
    }
    const proc = try std.process.Child.run(.{
        .argv = argv.items,
        .allocator = allocator,
    });

    // on success, we own the output streams
    defer allocator.free(proc.stdout);
    defer allocator.free(proc.stderr);
    try writer.print("{s}", .{proc.stdout});
}
