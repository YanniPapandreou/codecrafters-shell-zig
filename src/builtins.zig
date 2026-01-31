const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;

const Parser = @import("Parser.zig");
const ParserError = Parser.ParserError;
const ParsedCommand = Parser.ParsedCommand;
const ArgList = Parser.ArgList;

pub const RuntimeError = error{ CommandNotFound, InvalidArgs };

const OutputType = enum { default, file };

pub const Output = union(OutputType) {
    default: *std.Io.Writer,
    file: std.fs.File,

    pub fn deinit(self: *Output) void {
        switch (self.*) {
            .file => |file| file.close(),
            .default => {},
        }
    }

    fn writeAll(self: *Output, content: []const u8) !void {
        switch (self.*) {
            .default => |default| try default.writeAll(content),
            .file => |file| try file.writeAll(content),
        }
    }

    fn print(self: *Output, allocator: mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
        switch (self.*) {
            .default => |default| try default.print(fmt, args),
            .file => |file| {
                const content = try std.fmt.allocPrint(allocator, fmt, args);
                defer allocator.free(content);
                try file.writeAll(content);
            },
        }
    }
};

pub const Writers = struct {
    out: Output,
    err: Output,

    pub fn deinit(self: *Writers) void {
        self.out.deinit();
        self.err.deinit();
    }
};

pub const History = struct {
    allocator: mem.Allocator,
    entries: std.ArrayList([]const u8),
    save_loc: usize,

    pub fn init(allocator: mem.Allocator) !History {
        const hist = try std.ArrayList([]const u8).initCapacity(allocator, 0);
        return History{
            .allocator = allocator,
            .entries = hist,
            .save_loc = 0,
        };
    }

    pub fn deinit(self: *History) void {
        const HISTFILE = self.get_histfile() catch "";
        if (!mem.eql(u8, HISTFILE, "")) {
            self.write_to_file(HISTFILE, true) catch unreachable;
        }
        for (self.entries.items) |line| {
            self.allocator.free(line);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn append(self: *History, input: []const u8) !void {
        const input_copy = try self.allocator.alloc(u8, input.len);
        @memcpy(input_copy, input);
        try self.entries.append(self.allocator, input_copy);
    }

    fn print(self: *History, writers: *Writers) !void {
        for (self.entries.items, 1..) |entry, i| {
            try writers.out.print(self.allocator, "   {d}  {s}\n", .{ i, entry });
        }
    }

    fn print_last_n(self: *History, writers: *Writers, n: usize) !void {
        if (n == 0) {
            return;
        }
        const n_history = self.entries.items.len;
        if (n >= n_history) {
            try self.print(writers);
            return;
        }
        for ((n_history - n)..n_history) |i| {
            const entry = self.entries.items[i];
            try writers.out.print(self.allocator, "   {d}  {s}\n", .{ i + 1, entry });
        }
    }

    fn read_from_file(self: *History, path: []const u8) !void {
        // get file contents
        const file_contents = try std.fs.cwd().readFileAlloc(self.allocator, path, 1024 * 1024);
        defer self.allocator.free(file_contents);

        var lines = mem.splitScalar(u8, file_contents, '\n');
        while (lines.next()) |line| {
            // trim trailing '\r' (for Windows CRLF)
            var trimmed = line;
            if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '\r') {
                trimmed = trimmed[0 .. trimmed.len - 1];
            }
            if (trimmed.len == 0) continue;
            try self.append(trimmed);
        }
    }

    fn write_to_file(self: *History, path: []const u8, should_append: bool) !void {
        const cwd = std.fs.cwd();
        const handle = try cwd.createFile(path, .{
            // set truncate based on whether we are appending or not
            .truncate = if (should_append) false else true,
        });
        defer handle.close();

        if (should_append) {
            // go to end of file to append
            try handle.seekFromEnd(0);
        }

        const start_index = if (should_append) self.save_loc else 0;

        for (self.entries.items[start_index..]) |entry| {
            _ = try handle.write(entry);
            _ = try handle.write("\n");
            self.save_loc += 1;
        }
    }

    fn get_histfile(self: *History) ![]const u8 {
        const HISTFILE = std.process.getEnvVarOwned(self.allocator, "HISTFILE") catch |err|
            switch (err) {
                std.process.GetEnvVarOwnedError.EnvironmentVariableNotFound => "",
                else => return err,
            };
        return HISTFILE;
    }

    pub fn startup(self: *History) !void {
        const HISTFILE = try self.get_histfile();
        defer self.allocator.free(HISTFILE);
        if (!mem.eql(u8, HISTFILE, "")) {
            try self.read_from_file(HISTFILE);
        }
    }
};

pub fn echo(allocator: mem.Allocator, writers: *Writers, args: ArgList) !void {
    const out = try mem.join(allocator, " ", args);
    try writers.out.print(allocator, "{s}\n", .{out});
}

pub fn history(writers: *Writers, hist: *History, args: ArgList) !void {
    if (args.len == 0) {
        try hist.print(writers);
        return;
    } else if (args.len != 1 and args.len != 2) {
        return ParserError.WrongNumberOfArgs;
    }
    if (mem.eql(u8, args[0], "-r")) {
        const path = args[1];
        try hist.read_from_file(path);
        return;
    } else if (mem.eql(u8, args[0], "-w")) {
        const path = args[1];
        try hist.write_to_file(path, false);
        return;
    } else if (mem.eql(u8, args[0], "-a")) {
        const path = args[1];
        try hist.write_to_file(path, true);
        return;
    }
    const n = std.fmt.parseInt(usize, args[0], 10) catch |err| {
        switch (err) {
            std.fmt.ParseIntError.InvalidCharacter => {
                try writers.err.print(hist.allocator, "Error: `history` accepts at most 1 integer argument, got `{s}`\n", .{args[0]});
                return RuntimeError.InvalidArgs;
            },
            std.fmt.ParseIntError.Overflow => {
                try writers.err.print(hist.allocator, "Error: number too large `{s}`\n", .{args[0]});
                return RuntimeError.InvalidArgs;
            },
        }
    };
    try hist.print_last_n(writers, n);
}

pub fn type_of_cmd(allocator: mem.Allocator, writers: *Writers, args: ArgList) !void {
    if (args.len != 1) {
        try writers.err.print(allocator, "Error: `type` only accepts 1 argument\n", .{});
        return ParserError.WrongNumberOfArgs;
    }
    const arg = args[0];
    if (mem.eql(u8, arg, "exit") or
        mem.eql(u8, arg, "echo") or
        mem.eql(u8, arg, "history") or
        mem.eql(u8, arg, "type") or
        mem.eql(u8, arg, "pwd") or
        mem.eql(u8, arg, "cd"))
    {
        try writers.out.print(allocator, "{s} is a shell builtin\n", .{arg});
    } else {
        const full_path = find_exec(allocator, arg) catch |err| {
            switch (err) {
                RuntimeError.CommandNotFound => {
                    try writers.err.print(allocator, "{s}: not found\n", .{arg});
                    return;
                },
                else => unreachable,
            }
        };
        try writers.out.print(allocator, "{s} is {s}\n", .{ arg, full_path });
    }
}

pub fn pwd(allocator: mem.Allocator, writers: *Writers) !void {
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    try writers.out.print(allocator, "{s}\n", .{cwd});
}

pub fn cd(allocator: mem.Allocator, writers: *Writers, args: ArgList) !void {
    if (args.len > 1) {
        return ParserError.TooManyArgs;
    }
    const arg = if (args.len == 0) "~" else args[0];
    const path = if (mem.eql(u8, arg, "~"))
        try std.process.getEnvVarOwned(allocator, "HOME")
    else
        std.fs.realpathAlloc(allocator, arg) catch |err|
            switch (err) {
                std.posix.RealPathError.FileNotFound => {
                    try writers.err.print(allocator, "cd: {s}: No such file or directory\n", .{arg});
                    return;
                },
                else => return err,
            };
    var dir = std.fs.openDirAbsolute(path, .{}) catch |err|
        switch (err) {
            std.fs.File.OpenError.FileNotFound => {
                try writers.err.print(allocator, "cd: {s}: No such file or directory\n", .{path});
                return;
            },
            else => return err,
        };
    defer dir.close();
    try dir.setAsCwd();
}

const pathListSep: u8 = if (builtin.os.tag == .windows) ';' else ':';

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

pub fn run_external(allocator: mem.Allocator, writers: *Writers, external_cmd: ParsedCommand) !void {
    const full_path = find_exec(allocator, external_cmd.cmd) catch |err| {
        switch (err) {
            RuntimeError.CommandNotFound => {
                try writers.err.print(allocator, "{s}: not found\n", .{external_cmd.cmd});
                return;
            },
            else => unreachable,
        }
    };
    defer allocator.free(full_path);
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
            // Always write stdout to the redirected output
            try writers.out.writeAll(proc.stdout);
            if (code != 0) {
                try writers.err.writeAll(proc.stderr);
            }
        },
        else => {
            try writers.err.writeAll("External process terminated abnormally");
            try writers.err.writeAll(proc.stderr);
        },
    }
}
