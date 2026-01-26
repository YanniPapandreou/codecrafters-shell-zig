const std = @import("std");
const mem = std.mem;
const utils = @import("utils.zig");

const ParserError = utils.ParserError;
const RuntimeError = utils.RuntimeError;
const ArgList = utils.ArgList;

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

    fn print(self: *History, writer: *std.Io.Writer) !void {
        for (self.entries.items, 1..) |entry, i| {
            try writer.print("   {d}  {s}\n", .{ i, entry });
        }
    }

    fn print_last_n(self: *History, writer: *std.Io.Writer, n: usize) !void {
        if (n == 0) {
            return;
        }
        const n_history = self.entries.items.len;
        if (n >= n_history) {
            try self.print(writer);
            return;
        }
        for ((n_history - n)..n_history) |i| {
            const entry = self.entries.items[i];
            try writer.print("   {d}  {s}\n", .{ i + 1, entry });
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

pub fn echo(allocator: mem.Allocator, writer: *std.Io.Writer, args: ArgList) !void {
    const out = try mem.join(allocator, " ", args);
    try writer.print("{s}\n", .{out});
}

pub fn history(writer: *std.Io.Writer, hist: *History, args: ArgList) !void {
    if (args.len == 0) {
        try hist.print(writer);
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
                try writer.print("Error: `history` accepts at most 1 integer argument, got `{s}`\n", .{args[0]});
                return RuntimeError.InvalidArgs;
            },
            std.fmt.ParseIntError.Overflow => {
                try writer.print("Error: number too large `{s}`\n", .{args[0]});
                return RuntimeError.InvalidArgs;
            },
        }
    };
    try hist.print_last_n(writer, n);
}

pub fn type_of_cmd(allocator: mem.Allocator, writer: *std.Io.Writer, args: ArgList) !void {
    if (args.len != 1) {
        try writer.print("Error: `type` only accepts 1 argument\n", .{});
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
        try writer.print("{s} is a shell builtin\n", .{arg});
    } else {
        const full_path = utils.find_exec(allocator, arg) catch |err| {
            switch (err) {
                RuntimeError.CommandNotFound => {
                    try writer.print("{s}: not found\n", .{arg});
                    return;
                },
                else => unreachable,
            }
        };
        try writer.print("{s} is {s}\n", .{ arg, full_path });
    }
}

pub fn pwd(allocator: mem.Allocator, writer: *std.Io.Writer) !void {
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    try writer.print("{s}\n", .{cwd});
}

pub fn cd(allocator: mem.Allocator, writer: *std.Io.Writer, args: ArgList) !void {
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
                    try writer.print("cd: {s}: No such file or directory\n", .{arg});
                    return;
                },
                else => return err,
            };
    var dir = std.fs.openDirAbsolute(path, .{}) catch |err|
        switch (err) {
            std.fs.File.OpenError.FileNotFound => {
                try writer.print("cd: {s}: No such file or directory\n", .{path});
                return;
            },
            else => return err,
        };
    defer dir.close();
    try dir.setAsCwd();
}
