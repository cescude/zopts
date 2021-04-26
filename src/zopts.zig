// TODO: try to figure out the width of the terminal or whatever
const std = @import("std");

const reflowText = @import("reflow_text.zig").reflowText;
const FlagConverter = @import("flag_converters.zig");

const max_width: usize = 80;

allocator: *std.mem.Allocator,

program_name: ?[]const u8 = null,
program_summary: ?[]const u8 = null,

values: std.ArrayList([]const u8), // Backing array for string arguments

// Basic pattern:
//   cmd FLAGS... ARGS... EXTRAS...
//
// Both "ARGS" and "EXTRAS" are positional arguments; the difference is
// that EXTRAS are overflow, as in (defun cmd (arg0 arg1 &rest extra)).
//
// ...so, take "grep": the first positional argument is the pattern, the
// remaining arguments are which files to search.

flag_definitions: std.ArrayList(FlagDefinition),
arg_definitions: std.ArrayList(PositionalDefinition),
extras_definition: ?ExtrasDefinition = null, // Used if we need to capture the extra arguments that trail args

last_error: ?[]const u8 = null,

const ZOpts = @This();

const Error = error{ ParseError, OutOfMemory };

const FlagDefinition = struct {
    long_name: ?[]const u8,
    short_name: ?u8,
    val_name: ?[]const u8,
    description: ?[]const u8,
    // There's different parsing rules if this is a bool (flag) vs string
    // (option), namely that bools can omit an equals value, and can't be
    // assigned by a token in the next position.
    //
    // Eg: "--bool_flag" and "--bool_flag=true" but not "--bool_flag true"
    parse_type: enum { Bool, Str },
    val_ptr: FlagConverter,
};

const PositionalDefinition = struct {
    name: ?[]const u8,
    description: ?[]const u8,
    conv: FlagConverter,
};

const ExtrasDefinition = struct {
    name: ?[]const u8,
    description: ?[]const u8,
    ptr: *[][]const u8,
};

pub fn init(allocator: *std.mem.Allocator) ZOpts {
    return .{
        .allocator = allocator,
        .values = std.ArrayList([]const u8).init(allocator),
        .flag_definitions = std.ArrayList(FlagDefinition).init(allocator),
        .arg_definitions = std.ArrayList(PositionalDefinition).init(allocator),
    };
}

pub fn deinit(self: *ZOpts) void {
    for (self.values.items) |str| {
        self.allocator.free(str);
    }
    self.values.deinit();

    self.flag_definitions.deinit();
    self.arg_definitions.deinit();

    if (self.last_error) |msg| {
        self.allocator.free(msg);
    }
}

/// Frees up all unnecessary memory and returns the backing memory for the
/// caller to free:
///
///     var backing = zopts.toOwnedSlice();
///     for (backing) |ptr| {
///         your_allocator.free(ptr);
///     }
///     your_allocator.free(backing);
///
/// Use this when you do option parsing in a function, and need to keep the
/// backing memory defined, eg:
///
///     const Config = struct{
///         // ...
///     };
///
///     fn myParser() !struct{ data: [][]const u8, cfg: Config } {
///         var zopts = ZOpts.init(std.heap.page_allocator);
///         defer zopts.deinit();
///
///         var cfg = Config{};
///
///         // ... declare and parse your options here ...
///
///         var result = .{
///             .data = zopts.toOwnedSlice(),
///             .cfg = cfg,
///         };
///
///         return result;
///     }
pub fn toOwnedSlice(self: *ZOpts) [][]const u8 {
    var allocator = self.allocator;
    var backing_data = self.values.toOwnedSlice();

    // Make sure all our flags, args, and extras are represented

    self.flag_definitions.deinit();
    self.arg_definitions.deinit();
    if (self.last_error) |msg| {
        allocator.free(msg);
    }

    self.* = init(allocator);
    return backing_data;
}

pub fn printHelp(self: *ZOpts, writer: anytype) !void {
    if (self.last_error) |msg| {
        try writer.print("error: {s}\n\n", .{msg});
    }

    if (self.program_name) |program_name| {
        try writer.print("usage: {s} ", .{program_name});
    } else {
        try writer.print("usage: PROGRAM ", .{});
    }

    if (self.flag_definitions.items.len > 0) {
        try writer.print("[OPTIONS] ", .{});
    }

    for (self.arg_definitions.items) |defn| {
        try writer.print("{s} ", .{defn.name});
    }

    if (self.extras_definition) |defn| {
        if (defn.name) |n| {
            try writer.print("{s}...", .{n});
        } else {
            try writer.print("ARGS...", .{});
        }
    }

    try writer.print("\n", .{});

    if (self.program_summary) |program_summary| {
        var iter = reflowText(self.allocator, program_summary, max_width);
        defer iter.deinit();

        while (iter.next() catch null) |line| {
            try writer.print("{s}\n", .{line});
        }
    }

    try writer.print("\n", .{});

    if (self.flag_definitions.items.len > 0) {
        try writer.print("OPTIONS\n", .{});
    }

    for (self.flag_definitions.items) |defn| {
        var spec_line = try specStringAlloc(self.allocator, defn.long_name, defn.short_name, defn.val_name);
        defer self.allocator.free(spec_line);
        try self.printArgUsage(spec_line, defn.description, writer);
    }

    try writer.print("\n", .{});

    if (self.arg_definitions.items.len > 0) {
        try writer.print("ARGS\n", .{});
    }

    for (self.arg_definitions.items) |arg_defn| {
        try self.printArgUsage(arg_defn.name orelse "", arg_defn.description, writer);
    }

    if (self.extras_definition) |defn| {
        try self.printArgUsage(defn.name orelse "", defn.description, writer);
    }
}

fn specStringAlloc(allocator: *std.mem.Allocator, long_name: ?[]const u8, short_name: ?u8, maybe_val_name: ?[]const u8) ![]const u8 {
    if (long_name == null and short_name == null) {
        unreachable;
    }

    if (maybe_val_name) |val_name| {
        if (short_name != null and long_name != null) {
            return try std.fmt.allocPrint(allocator, "-{c}, --{s}={s}", .{ short_name.?, long_name.?, val_name });
        } else if (short_name != null) {
            return try std.fmt.allocPrint(allocator, "-{c}={s}", .{ short_name.?, val_name });
        } else if (long_name != null) {
            return try std.fmt.allocPrint(allocator, "    --{s}={s}", .{ long_name.?, val_name });
        }
    } else {
        if (short_name != null and long_name != null) {
            return try std.fmt.allocPrint(allocator, "-{c}, --{s}", .{ short_name.?, long_name.? });
        } else if (short_name != null) {
            return try std.fmt.allocPrint(allocator, "-{c}", .{short_name.?});
        } else if (long_name != null) {
            return try std.fmt.allocPrint(allocator, "    --{s}", .{long_name.?});
        }
    }

    unreachable;
}

fn printArgUsage(self: *ZOpts, arg_name: []const u8, arg_desc: ?[]const u8, writer: anytype) !void {
    try writer.print("   {s: <25} ", .{arg_name});

    // This is very unlikely, but...
    if (arg_name.len > 25) {
        try writer.print("\n" ++ " " ** 29, .{});
    }

    if (arg_desc) |description| {
        var iter = reflowText(self.allocator, description, max_width - 29);
        defer iter.deinit();

        var first_line = true;
        while (iter.next() catch null) |line| {
            if (first_line) {
                first_line = false;
            } else {
                try writer.print(" " ** 29, .{});
            }
            try writer.print("{s}\n", .{line});
        }
    } else {
        try writer.print("\n", .{});
    }
}

pub fn printHelpAndDie(self: *ZOpts) noreturn {
    const stderr = std.io.getStdErr().writer();
    self.printHelp(stderr) catch {};
    std.process.exit(1);
}

/// Configure the name for this program. This only affects "usage"
/// output; TODO: if omitted, this will be taken from the first argv.
pub fn programName(self: *ZOpts, program_name: []const u8) void {
    self.program_name = program_name;
}

/// Configure a usage summary for this program. This is a summary
/// paragraph that follows the program name in the help text.
pub fn summary(self: *ZOpts, program_summary: []const u8) void {
    self.program_summary = program_summary;
}

/// Configure a commandline flag, as well as provide a memory location
/// to store the result.
///
/// Note that `ptr` can refer to a boolean, signed/unsigned integer, a
/// []const u8 string, or an optional of any of the prior types.
///
/// Boolean flags have slightly different parsing rules from
/// string/value flags.
pub fn flag(self: *ZOpts, comptime long_name: ?[]const u8, comptime short_name: ?u8, ptr: anytype) !void {
    try self.flagDecl(long_name, short_name, ptr, null, null);
}

pub fn flagDecl(self: *ZOpts, comptime long_name: ?[]const u8, comptime short_name: ?u8, ptr: anytype, val_desc: ?[]const u8, description: ?[]const u8) !void {
    if (long_name == null and short_name == null) {
        @compileError("Must provide at least one name to identify this flag");
    }

    const is_bool = @TypeOf(ptr) == *bool or @TypeOf(ptr) == *?bool;
    const conv = FlagConverter.init(ptr);

    try self.flag_definitions.append(.{
        .long_name = long_name,
        .short_name = short_name,
        .val_name = val_desc orelse conv.tag orelse null,
        .description = description,
        .parse_type = if (is_bool) .Bool else .Str,
        .val_ptr = conv,
    });
}

pub fn arg(self: *ZOpts, ptr: anytype) !void {
    try self.argDecl(null, ptr, null);
}

pub fn argDecl(self: *ZOpts, comptime arg_name: ?[]const u8, ptr: anytype, description: ?[]const u8) !void {
    var conv = FlagConverter.init(ptr);

    try self.arg_definitions.append(.{
        .name = if (arg_name != null) arg_name else conv.tag,
        .description = description,
        .conv = conv,
    });
}

/// Name and bind the non-flag commandline arguments
pub fn extra(self: *ZOpts, ptr: *[][]const u8) !void {
    try self.extraDecl(null, ptr, null);
}

pub fn extraDecl(self: *ZOpts, comptime extras_name: ?[]const u8, ptr: *[][]const u8, description: ?[]const u8) !void {
    self.extras_definition = .{
        .name = extras_name orelse "STR",
        .description = description,
        .ptr = ptr,
    };
}

pub fn parseOrDie(self: *ZOpts) void {
    self.parse() catch |_| self.printHelpAndDie();
}

pub fn parse(self: *ZOpts) !void {
    var argv = try std.process.argsAlloc(self.allocator);
    defer std.process.argsFree(self.allocator, argv);
    if (self.program_name == null) {
        const basename = try self.allocator.dupe(u8, std.fs.path.basename(argv[0]));
        errdefer self.allocator.free(basename); // TODO: Assuming this scope is just the current block

        // So it'll get free'd on deinit()
        try self.values.append(basename);
        self.program_name = self.values.items[self.values.items.len - 1];
    }
    try self.parseSlice(argv[1..]);
}

fn setError(self: *ZOpts, comptime fmt: []const u8, vals: anytype) !void {
    if (self.last_error) |e| {
        self.allocator.free(e);
    }

    self.last_error = try std.fmt.allocPrint(self.allocator, fmt, vals);
}

const Action = enum {
    AdvanceOneCharacter,
    ContinueToNextToken,
    SkipNextToken,
};

pub fn parseSlice(self: *ZOpts, argv: [][]const u8) Error!void {
    var no_more_flags = false;
    var num_positionals: usize = 0;
    var extras_start_idx: ?usize = null;

    var idx: usize = 0;
    while (idx < argv.len) : (idx += 1) {
        var token = argv[idx];

        if (no_more_flags) {
            try self.addPositional(token, num_positionals); // TODO: needs test case
            num_positionals += 1;
        } else {
            if (std.mem.eql(u8, token, "--")) {
                no_more_flags = true; // TODO: needs test case
            } else if (std.mem.startsWith(u8, token, "--")) {
                const action = try self.fillLongValue(token[2..], argv[idx + 1 ..]);
                switch (action) {
                    .AdvanceOneCharacter => unreachable,
                    .ContinueToNextToken => {},
                    .SkipNextToken => idx += 1, // we used argv[idx+1] for the value
                }
            } else if (std.mem.eql(u8, token, "-")) {
                try self.addPositional(token, num_positionals); // TODO: needs test case
                num_positionals += 1;
                no_more_flags = true;
            } else if (std.mem.startsWith(u8, token, "-")) {

                // Pull out all short flags from the token
                token = token[1..];
                shortloop: while (token.len > 0) {
                    const action = try self.fillShortValue(token, argv[idx + 1 ..]);
                    switch (action) {
                        .AdvanceOneCharacter => token = token[1..], // go to the next short flag
                        .ContinueToNextToken => {
                            break :shortloop;
                        },
                        .SkipNextToken => {
                            idx += 1;
                            break :shortloop;
                        },
                    }
                }
            } else {
                try self.addPositional(token, num_positionals); // TODO: needs test case
                num_positionals += 1;
                no_more_flags = true;
            }
        }

        if (num_positionals == self.arg_definitions.items.len) {
            extras_start_idx = self.values.items.len;
        }
    }

    if (self.extras_definition) |defn| {
        if (extras_start_idx) |extras_idx| {
            defn.ptr.* = self.values.items[extras_idx..];
        } else {
            defn.ptr.* = self.values.items[0..0];
        }
    }
}

fn addPositional(self: *ZOpts, value: []const u8, arg_idx: usize) !void {
    if (arg_idx < self.arg_definitions.items.len) {
        // We have a definition for this positional! Convert directly.
        var defn = self.arg_definitions.items[arg_idx];

        const dup_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(dup_value);

        try defn.conv.conv_fn(defn.conv.ptr, dup_value);
        try self.values.append(dup_value);
    } else if (self.extras_definition) |_| {
        try self.values.append(try self.allocator.dupe(u8, value));
    } else {
        // We've received an arg but ran out of arg bindings, and also
        // don't have a extras_definition.ptr to bind it to.
        try self.setError("Unexpected argument \"{s}\"", .{value});
        return error.ParseError;
    }
}

fn fillLongValue(self: *ZOpts, token: []const u8, remainder: [][]const u8) !Action {
    var flag_name = extractName(token);
    var defn: FlagDefinition = getFlagByLongName(self.flag_definitions.items, flag_name) orelse {
        try self.setError("Unrecognized option \"--{s}\"", .{flag_name});
        return error.ParseError;
    };

    var action_taken: Action = undefined;

    const ptr = defn.val_ptr.ptr;
    const conv_fn = defn.val_ptr.conv_fn;

    switch (defn.parse_type) {
        .Bool => {
            action_taken = Action.ContinueToNextToken;
            if (extractEqualValue(token)) |value| {
                conv_fn(ptr, value) catch |err| {
                    // NOTE: zig bug--using "switch (err) {...}" doesn't compile!
                    if (err == error.ParseError) {
                        try self.setError("Can't set flag \"--{s}\" to \"{s}\"", .{ flag_name, value });
                    }
                    return err;
                };
            } else {
                try conv_fn(ptr, "true"); // This should never give a parse error...
            }
        },
        .Str => {
            var value: []const u8 = undefined;

            if (extractEqualValue(token)) |v| {
                action_taken = Action.ContinueToNextToken;
                value = v;
            } else if (extractNextValue(remainder)) |v| {
                action_taken = Action.SkipNextToken;
                value = v;
            } else {
                try self.setError("Missing value for option \"{s}\"", .{flag_name});
                return error.ParseError; // missing a string value
            }

            // We want our own, backing copy of the value...
            const value_copy = try self.allocator.dupe(u8, value);
            errdefer self.allocator.free(value_copy);

            // Remember this value so we can free it on deinit()
            try self.values.append(value_copy);
            errdefer _ = self.values.pop();

            // Attempt the conversion
            conv_fn(ptr, value_copy) catch |err| {
                // NOTE: zig bug--using "switch (err) {...}" doesn't compile!
                if (err == error.ParseError) {
                    try self.setError("Can't set flag \"--{s}\" to \"{s}\"", .{ flag_name, value });
                }
                return err;
            };
        },
    }

    return action_taken;
}

fn fillShortValue(self: *ZOpts, token: []const u8, remainder: [][]const u8) !Action {
    var flag_name = token[0];
    var defn: FlagDefinition = getFlagByShortName(self.flag_definitions.items, flag_name) orelse {
        try self.setError("Unrecognized option \"-{c}\"", .{flag_name});
        return error.ParseError;
    };

    var action_taken: Action = undefined;

    const ptr = defn.val_ptr.ptr;
    const conv_fn = defn.val_ptr.conv_fn;

    switch (defn.parse_type) {
        .Bool => {
            if (token.len > 1 and token[1] == '=') {
                action_taken = Action.ContinueToNextToken; // didn't use any of the remainder
                conv_fn(ptr, token[2..]) catch |err| {
                    // NOTE: zig bug--using "switch (err) {...}" doesn't compile!
                    if (err == error.ParseError) {
                        try self.setError("Can't set flag \"-{c}\" to \"{s}\"", .{ flag_name, token[2..] });
                    }
                    return err;
                };
            } else {
                action_taken = Action.AdvanceOneCharacter;
                try conv_fn(ptr, "true"); // This should never give a parse error
            }
        },
        .Str => {
            var value: []const u8 = undefined;

            if (token.len > 1 and token[1] == '=') {
                action_taken = Action.ContinueToNextToken;
                value = token[2..];
            } else if (token.len > 1) {
                action_taken = Action.ContinueToNextToken;
                value = token[1..];
            } else if (extractNextValue(remainder)) |v| {
                action_taken = Action.SkipNextToken;
                value = v;
            } else {
                try self.setError("Missing value for option \"{c}\"", .{flag_name});
                return error.ParseError; // missing a string value
            }

            // We want our own, backing copy of the value...
            const value_copy = try self.allocator.dupe(u8, value);
            errdefer self.allocator.free(value_copy);

            // Remember this value so we can free it on deinit()
            try self.values.append(value_copy);
            errdefer _ = self.values.pop();

            // Attempt the conversion
            conv_fn(ptr, value_copy) catch |err| {
                // NOTE: zig bug--using "switch (err) {...}" doesn't compile!
                if (err == error.ParseError) {
                    try self.setError("Can't set flag \"-{c}\" to \"{s}\"", .{ flag_name, token[2..] });
                }
                return err;
            };
        },
    }

    return action_taken;
}

fn extractName(token: []const u8) []const u8 {
    if (std.mem.indexOf(u8, token, "=")) |idx| {
        return token[0..idx];
    } else {
        return token;
    }
}

fn extractEqualValue(token: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, token, "=")) |idx| {
        return token[idx + 1 ..];
    } else {
        return null;
    }
}

fn extractNextValue(remainder: [][]const u8) ?[]const u8 {
    if (remainder.len > 0 and !std.mem.startsWith(u8, remainder[0], "-")) {
        return remainder[0];
    } else {
        return null;
    }
}

fn getFlagByLongName(flags: []FlagDefinition, flag_name: []const u8) ?FlagDefinition {
    for (flags) |defn| {
        if (defn.long_name) |long_name| {
            if (std.mem.eql(u8, long_name, flag_name)) {
                return defn;
            }
        }
    }

    return null;
}

fn getFlagByShortName(flags: []FlagDefinition, flag_name: u8) ?FlagDefinition {
    for (flags) |defn| {
        if (defn.short_name) |short_name| {
            if (short_name == flag_name) {
                return defn;
            }
        }
    }

    return null;
}

const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

test "anyflag" {
    var args = ZOpts.init(std.testing.allocator);
    defer args.deinit();

    var flag0: ?bool = null;
    var flag1: bool = false;
    var flag2: ?[]const u8 = null;
    var flag3: []const u8 = "fail";
    var flag4: enum { One, Two, Three, Four } = .Three;
    var flag5: ?enum { Red, Orange, Yellow } = null;

    try args.flag("flag0", null, &flag0);
    try args.flag("flag1", null, &flag1);
    try args.flag("flag2", null, &flag2);
    try args.flag("flag3", null, &flag3);
    try args.flag("flag4", null, &flag4);
    try args.flag("flag5", null, &flag5);

    var argv = [_][]const u8{
        "--flag0=yes", "--flag1=1", "--flag2=pass", "--flag3=pass", "--flag4=two", "--flag5=YelloW",
    };
    try args.parseSlice(argv[0..]);

    expect(flag0 orelse false);
    expect(flag1);
    expectEqualStrings("pass", flag2 orelse "fail");
    expectEqualStrings("pass", flag3);
    expect(flag4 == .Two);
    expect(flag5.? == .Yellow);
}

test "Omitted flags get default values" {
    var args = ZOpts.init(std.testing.allocator);
    defer args.deinit();

    var flag0: ?bool = null;
    var flag1: ?bool = true;
    var flag2: ?[]const u8 = null;
    var flag3: ?[]const u8 = "default";

    try args.flag("flag0", 'a', &flag0);
    try args.flag("flag1", 'b', &flag1);
    try args.flag("flag2", 'c', &flag2);
    try args.flag("flag3", 'd', &flag3);

    var argv = [_][]const u8{};
    try args.parseSlice(argv[0..]);

    expect(flag0 == null);
    expect(flag1 orelse false);
    expect(flag2 == null);
    expectEqualStrings("default", flag3 orelse "fail");
}

test "Flags can be set" {
    var args = ZOpts.init(std.testing.allocator);
    defer args.deinit();

    var flag0: ?bool = null;
    var flag1: ?bool = false;
    var flag2: ?[]const u8 = null;
    var flag3: ?[]const u8 = "default";

    try args.flag("flag0", 'a', &flag0);
    try args.flag("flag1", 'b', &flag1);
    try args.flag("flag2", 'c', &flag2);
    try args.flag("flag3", 'd', &flag3);

    var argv = [_][]const u8{ "--flag0", "--flag1", "--flag2", "aaa", "--flag3", "bbb" };
    try args.parseSlice(argv[0..]);

    expect(flag0 orelse false);
    expect(flag1 orelse false);
    expectEqualStrings("aaa", flag2 orelse "fail");
    expectEqualStrings("bbb", flag3 orelse "fail");

    flag0 = null;
    flag1 = false;
    flag2 = null;
    flag3 = "default";

    argv = [_][]const u8{ "-a", "-b", "-c", "aaa", "-d", "bbb" };
    try args.parseSlice(argv[0..]);

    expect(flag0 orelse false);
    expect(flag1 orelse false);
    expectEqualStrings("aaa", flag2 orelse "fail");
    expectEqualStrings("bbb", flag3 orelse "fail");
}

test "Various ways to set a string value" {
    var args = ZOpts.init(std.testing.allocator);
    defer args.deinit();

    var flag_equal: ?[]const u8 = null;
    var flag_posn: ?[]const u8 = null;

    try args.flag("flag_equal", 'a', &flag_equal);
    try args.flag("flag_posn", 'b', &flag_posn);

    var argv = [_][]const u8{ "--flag_equal=aaa", "--flag_posn", "bbb" };
    try args.parseSlice(argv[0..]);

    expectEqualStrings("aaa", flag_equal orelse "fail");
    expectEqualStrings("bbb", flag_posn orelse "fail");

    flag_equal = null;
    flag_posn = null;

    argv = [_][]const u8{ "-a=aaa", "-b", "bbb" };
    try args.parseSlice(argv[0..]);

    expectEqualStrings("aaa", flag_equal orelse "fail");
    expectEqualStrings("bbb", flag_posn orelse "fail");
}

test "Expecting errors on bad input" {
    var args = ZOpts.init(std.testing.allocator);
    defer args.deinit();

    var flag0: ?bool = null;
    var flag1: ?[]const u8 = null;

    try args.flag("flag0", 'a', &flag0);
    try args.flag("flag1", 'b', &flag1);

    var argv = [_][]const u8{"--flag10=aaa"};
    expectError(error.ParseError, args.parseSlice(argv[0..]));

    argv = [_][]const u8{"-c"};
    expectError(error.ParseError, args.parseSlice(argv[0..]));

    argv = [_][]const u8{"-ac"};
    expectError(error.ParseError, args.parseSlice(argv[0..]));

    argv = [_][]const u8{"--flag0=not_right"};
    expectError(error.ParseError, args.parseSlice(argv[0..]));

    argv = [_][]const u8{"positional_argument"};
    expectError(error.ParseError, args.parseSlice(argv[0..]));
}

test "Missing string argument" {
    var args = ZOpts.init(std.testing.allocator);
    defer args.deinit();

    var miss0: ?[]const u8 = null;
    var miss1: []const u8 = "";

    try args.flag("miss0", 'm', &miss0);
    try args.flag("miss1", 'n', &miss1);

    // There's four codepaths for this error...

    var argv = [_][]const u8{"--miss0"};
    expectError(error.ParseError, args.parseSlice(argv[0..]));

    argv = [_][]const u8{"--miss1"};
    expectError(error.ParseError, args.parseSlice(argv[0..]));

    argv = [_][]const u8{"-m"};
    expectError(error.ParseError, args.parseSlice(argv[0..]));

    argv = [_][]const u8{"-n"};
    expectError(error.ParseError, args.parseSlice(argv[0..]));
}

test "Various ways to set a boolean to true" {
    var args = ZOpts.init(std.testing.allocator);
    defer args.deinit();

    var flag_basic: ?bool = null;
    var flag_true: ?bool = null;
    var flag_yes: ?bool = null;
    var flag_on: ?bool = null;
    var flag_y: ?bool = null;
    var flag_1: ?bool = null;

    try args.flag("flag_basic", 'a', &flag_basic);
    try args.flag("flag_true", 'b', &flag_true);
    try args.flag("flag_yes", 'c', &flag_yes);
    try args.flag("flag_on", 'd', &flag_on);
    try args.flag("flag_y", 'e', &flag_y);
    try args.flag("flag_1", 'f', &flag_1);

    var argv = [_][]const u8{
        "--flag_basic", "--flag_true=true", "--flag_yes=yes",
        "--flag_on=on", "--flag_y=y",       "--flag_1=1",
    };
    try args.parseSlice(argv[0..]);

    expect(flag_basic orelse false);
    expect(flag_true orelse false);
    expect(flag_yes orelse false);
    expect(flag_on orelse false);
    expect(flag_y orelse false);
    expect(flag_1 orelse false);

    flag_basic = null;
    flag_true = null;
    flag_yes = null;
    flag_on = null;
    flag_y = null;
    flag_1 = null;

    argv = [_][]const u8{ "-a", "-b=true", "-c=yes", "-d=on", "-e=y", "-f=1" };
    try args.parseSlice(argv[0..]);

    expect(flag_basic orelse false);
    expect(flag_true orelse false);
    expect(flag_yes orelse false);
    expect(flag_on orelse false);
    expect(flag_y orelse false);
    expect(flag_1 orelse false);
}

test "Various ways to set a boolean to false" {
    var args = ZOpts.init(std.testing.allocator);
    defer args.deinit();

    var flag_basic: ?bool = null;
    var flag_true: ?bool = null;
    var flag_yes: ?bool = null;
    var flag_on: ?bool = null;
    var flag_y: ?bool = null;
    var flag_1: ?bool = null;

    try args.flag("flag_basic", 'a', &flag_basic);
    try args.flag("flag_true", 'b', &flag_true);
    try args.flag("flag_yes", 'c', &flag_yes);
    try args.flag("flag_on", 'd', &flag_on);
    try args.flag("flag_y", 'e', &flag_y);
    try args.flag("flag_1", 'f', &flag_1);

    var argv = [_][]const u8{
        "--flag_true=false", "--flag_yes=no",
        "--flag_on=off",     "--flag_y=n",
        "--flag_1=0",
    };
    try args.parseSlice(argv[0..]);

    expect(flag_basic == null);
    expect(!flag_true.?);
    expect(!flag_yes.?);
    expect(!flag_on.?);
    expect(!flag_y.?);
    expect(!flag_1.?);

    flag_basic = null;
    flag_true = null;
    flag_yes = null;
    flag_on = null;
    flag_y = null;
    flag_1 = null;

    argv = [_][]const u8{ "-b=false", "-c=no", "-d=off", "-e=n", "-f=0" };
    try args.parseSlice(argv[0..]);

    expect(flag_basic == null);
    expect(!flag_true.?);
    expect(!flag_yes.?);
    expect(!flag_on.?);
    expect(!flag_y.?);
    expect(!flag_1.?);
}

test "Number support" {
    var args = ZOpts.init(std.testing.allocator);
    defer args.deinit();

    var flag0: u1 = 0;
    var flag1: ?u2 = null;
    var flag2: u32 = 0;
    var flag3: ?u64 = null;

    var flag4: i2 = 0;
    var flag5: ?i2 = null;
    var flag6: i32 = 0;
    var flag7: ?i64 = null;

    try args.flag("flag0", null, &flag0);
    try args.flag("flag1", null, &flag1);
    try args.flag("flag2", null, &flag2);
    try args.flag("flag3", null, &flag3);

    try args.flag("flag4", null, &flag4);
    try args.flag("flag5", null, &flag5);
    try args.flag("flag6", null, &flag6);
    try args.flag("flag7", null, &flag7);

    var argv = [_][]const u8{
        "--flag0=1",  "--flag1=1", "--flag2=300000", "--flag3=300000",
        "--flag4=-1", "--flag5=1", "--flag6=-20",    "--flag7=-10000",
    };
    try args.parseSlice(argv[0..]);

    expect(flag0 == 1);
    expect(flag1.? == 1);
    expect(flag2 == 300000);
    expect(flag3.? == 300000);

    expect(flag4 == -1);
    expect(flag5.? == 1);
    expect(flag6 == -20);
    expect(flag7.? == -10000);
}

test "Mashing together short opts" {
    var args = ZOpts.init(std.testing.allocator);
    defer args.deinit();

    var flag_a: ?bool = null;
    var flag_b: ?bool = null;
    var flag_c: ?bool = null;

    var flag_d: ?[]const u8 = null;
    var flag_e: ?[]const u8 = null;

    var flag_f: ?bool = null;
    var flag_g: ?[]const u8 = null;

    var flag_h: ?bool = null;
    var flag_i: ?[]const u8 = null;

    try args.flag(null, 'a', &flag_a);
    try args.flag(null, 'b', &flag_b);
    try args.flag(null, 'c', &flag_c);

    try args.flag(null, 'd', &flag_d);
    try args.flag(null, 'e', &flag_e);

    try args.flag(null, 'f', &flag_f);
    try args.flag(null, 'g', &flag_g);

    try args.flag(null, 'h', &flag_h);
    try args.flag(null, 'i', &flag_i);

    var argv = [_][]const u8{ "-abc=no", "-d=pass", "-e", "pass", "-fg=pass", "-hi", "pass" };
    try args.parseSlice(argv[0..]);

    expect(flag_a.?);
    expect(flag_b.?);
    expect(!flag_c.?);

    expectEqualStrings("pass", flag_d.?);
    expectEqualStrings("pass", flag_e.?);

    expect(flag_f.?);
    expectEqualStrings("pass", flag_g.?);

    expect(flag_h.?);
    expectEqualStrings("pass", flag_i.?);
}

test "Positional functionality" {
    var args = ZOpts.init(std.testing.allocator);
    defer args.deinit();

    var flag0: bool = false;
    var flag1: u16 = 0;
    var arg0: []const u8 = "";
    var arg1: ?u64 = null;
    var files: [][]const u8 = undefined;

    try args.flag("flag0", null, &flag0);
    try args.flag("flag1", null, &flag1);
    try args.arg(&arg0);
    try args.arg(&arg1);
    try args.extra(&files);

    var argv_missing = [_][]const u8{};
    try args.parseSlice(argv_missing[0..]);
    expect(arg0.len == 0);
    expect(arg1 == null);
    expect(files.len == 0);

    var argv = [_][]const u8{ "--flag0", "--flag1", "1234", "*.txt", "200000", "one.txt", "two.txt" };
    try args.parseSlice(argv[0..]);

    expect(flag0);
    expect(flag1 == 1234);
    expectEqualStrings("*.txt", arg0);
    expect(arg1.? == 200000);
    expect(files.len == 2);
    expectEqualStrings("one.txt", files[0]);
    expectEqualStrings("two.txt", files[1]);
}

test "Subcommand template" {
    // General strategy is parse with an enum in the first position, gathering
    // the extra args.
    var args = ZOpts.init(std.testing.allocator);
    defer args.deinit();

    var maybe_cmd: ?enum { Left, Right, Up, Down } = null;
    var extras: [][]const u8 = undefined;

    try args.arg(&maybe_cmd);
    try args.extra(&extras);

    var argv = [_][]const u8{ "right", "--verbose" };

    try args.parseSlice(argv[0..]);

    if (maybe_cmd) |cmd| switch (cmd) {
        .Left, .Up, .Down => {
            // Would typically add code to handle these other cases here
            expect(false);
        },
        .Right => {
            var left_args = ZOpts.init(std.testing.allocator);
            defer left_args.deinit();

            var verbose = false;
            try left_args.flag("verbose", 'v', &verbose);

            try left_args.parseSlice(extras);

            expect(verbose);
        },
    } else {
        expect(false);
    }
}

test "Using toOwnedSlice to parse in a function" {
    const Config = struct {
        arg0: []const u8 = "",
        arg1: []const u8 = "",
        extras: [][]const u8 = undefined,
    };

    const impl = struct {
        pub fn getOpts() !struct { cfg: Config, data: [][]const u8 } {
            var zopts = ZOpts.init(std.testing.allocator);
            defer zopts.deinit();

            var cfg = Config{};

            try zopts.flag("arg0", null, &cfg.arg0);
            try zopts.arg(&cfg.arg1);
            try zopts.extra(&cfg.extras);

            var argv = [_][]const u8{ "--arg0=one", "two", "three", "four" };
            try zopts.parseSlice(argv[0..]);

            var result = .{
                .cfg = cfg,
                .data = zopts.toOwnedSlice(),
            };

            return result;
        }
    };

    var opts = try impl.getOpts();
    defer {
        for (opts.data) |ptr| {
            std.testing.allocator.free(ptr);
        }
        std.testing.allocator.free(opts.data);
    }

    expectEqualStrings("one", opts.cfg.arg0);
    expectEqualStrings("two", opts.cfg.arg1);
    expect(opts.cfg.extras.len == 2);
    expectEqualStrings("three", opts.cfg.extras[0]);
    expectEqualStrings("four", opts.cfg.extras[1]);
}

test "README: Grep Example (lazy)" {
    var zopts = ZOpts.init(std.testing.allocator);
    defer zopts.deinit();

    var context: u32 = 3;
    var ignore_case = false;
    var color: enum { On, Off, Auto } = .Auto;

    var pattern: ?[]const u8 = null;
    var files: [][]const u8 = undefined;

    try zopts.flag("context", 'C', &context);
    try zopts.flag("ignore-case", 'i', &ignore_case);
    try zopts.flag("color", null, &color);

    var show_help = false;
    try zopts.flag("help", 'h', &show_help);

    try zopts.arg(&pattern);
    try zopts.extra(&files);

    var argv = [_][]const u8{"-h"};
    try zopts.parseSlice(argv[0..]);

    if (show_help) {
        try zopts.printHelp(std.io.getStdErr().writer());
    }
}

test "README: Grep Example (full)" {
    const Config = struct {
        context: u32 = 3,
        ignore_case: bool = false,
        color: enum { On, Off, Auto } = .Auto,

        pattern: ?[]const u8 = null, // Optional, because we need to see if it was specified
        files: [][]const u8 = undefined,
    };

    const defs = struct {
        pub fn parseOpts(allocator: *std.mem.Allocator) !struct { cfg: Config, data: [][]const u8 } {
            var zopts = ZOpts.init(allocator);
            defer zopts.deinit();

            var cfg = Config{};

            zopts.programName("grep");
            zopts.summary(
                \\An example "grep" program illustrating various option types as
                \\a means to show real usage of the ZOpts package.
            );

            try zopts.flagDecl("context", 'C', &cfg.context, "LINES",
                \\Number of lines of context to include before and after
                \\a match (default is 3).
            );
            try zopts.flagDecl("ignore-case", 'i', &cfg.ignore_case, null, "Enable case insensitive search.");
            try zopts.flagDecl("color", null, &cfg.color, null, "Colorize the output (default is Auto).");

            var show_help = false;
            try zopts.flagDecl("help", 'h', &show_help, null, "Display this help message");

            try zopts.argDecl("PATTERN", &cfg.pattern, "Pattern to search on.");
            try zopts.extraDecl("[FILE]", &cfg.files, "Files to search. Omit for stdin.");

            var argv = [_][]const u8{"-h"};
            try zopts.parseSlice(argv[0..]);

            if (show_help) {
                var help_str = std.ArrayList(u8).init(std.testing.allocator);
                defer help_str.deinit();

                try zopts.printHelp(help_str.writer());
                std.debug.print("\n{s}\n", .{help_str.items[0..]});
            }

            var result = .{
                .cfg = cfg,
                .data = zopts.toOwnedSlice(),
            };

            return result;
        }
    };

    var opts = try defs.parseOpts(std.testing.allocator);
}
