# Command Line parsing with ZOpts

ZOpts is a zig library for parsing commandline flags. It's primary goal is to be
easy to use without relying on too much magic, leaning on zig's language
features to perform the work.
 
# Synopsis

Basic setup & use:

    const std = @import("std");
    const ZOpts = @import("zopts");
    
    pub fn main() !void {
        var opts = ZOpts.init(std.heap.page_allocator);
        opts.deinit();
        
        // Define flags/options here...
        
        opts.parseOrDie();
    }

Declaring a boolean flag that defaults to false:

    var verbose: bool = false;
    try opts.flag("verbose", 'v', &verbose);
    
Declaring a string that defaults to "today":

    var day: []const u8 = "today";
    try opts.flag("day", 'd', &day);
    
Declaring a string that must be an enum, defaulting to "blue". Parsing will fail
if something other than Red, Green, or Blue is supplied on the commandline
(ignoring case):

    var color_choice: enum{Red,Green,Blue} = .Blue;
    try opts.flag("color", 'c', &color_choice);
    
Declaring a number. Parsing will fail if the supplied number can't be
represented properly (eg., more bits required, or a negative value to an
unsigned):

    var num_hats: u32 = 0;
    var distance: i8 = 0;
    
    try opts.flag("num-hats", 'n', &num_hats);
    try opts.flag("distance", 'd', &distance);
    
Sometimes you don't have a suitable default, and need to detect if an option was
omitted on the commandline. You can do this by making one of the above types
optional:

    var first_name: ?[]const u8 = null;
    var age: ?u8 = null;
    
    try opts.flag("first-name", 'f', &first_name);
    try opts.flag("age", 'a', &age);

    opts.parseOrDie();

    if (first_name) |n| {
        // User passed in a first name
    }
    
    if (age) |n| {
        // User passed in an age
    }

Declaring positional arguments:

    var pattern: []const u8 = "";
    var count: u32 = 0;
    
    try opts.arg(&pattern);
    try opts.arg(&count);

Capturing any extra positional arguments:

    var extra: [][]const u8 = undefined;
    
    try opts.extra(&extra);

To provide usage information for the help string, use `flagDecl` and `argDecl`,
rather than just `flag` or `arg` (respectively). This will give more context
when printing usage information.

    var name: []const u8 = "";
    var file: []const u8 = "";
    
    try opts.flagDecl("name", 'n', &name, "NAME", "Name of the user running a query");
    try opts.argDecl("file", 'f', &file, "INPUT", "File name containing data");
    
## Case example "grep"

Here's the help string for a fictional implementation of grep:

    usage: grep [OPTIONS]... PATTERN [FILE]...
    An example "grep" program illustrating various option types as a means to show
    real usage of the ZOpts package.
    
    OPTIONS
       -C, --context=NUM         Number of lines of context to include (default is
                                 3).
       -i, --ignore-case         Enable case insensitive search.
           --color=[On|Off|Auto] Colorize the output (default is Auto).
       -h, --help                Display this help message
    
    ARGS
       PATTERN                   Pattern to search on.
       [FILE]                    Files to search. Omit for stdin.

This can be implemented w/ ZOpts as follows:

    fn parseOpts(allocator: *std.mem.Allocator) !struct { cfg: Config, data: [][]const u8 } {
        var zopts = ZOpts.init(allocator);
        defer zopts.deinit();

        var cfg = Config{};

        zopts.programName("grep");
        zopts.summary(
            \\An example "grep" program illustrating various option types as
            \\a means to show real usage of the ZOpts package.
        );

        try zopts.flagDecl("context", 'C', &cfg.context, "NUM", "Number of lines of context to include (defaul$
        try zopts.flagDecl("ignore-case", 'i', &cfg.ignore_case, null, "Enable case insensitive search.");
        try zopts.flagDecl("color", null, &cfg.color, null, "Colorize the output (default is Auto).");

        var show_help = false;
        try zopts.flagDecl("help", 'h', &show_help, null, "Display this help message");

        try zopts.argDecl("PATTERN", &cfg.pattern, "Pattern to search on.");
        try zopts.extraDecl("[FILE]", &cfg.files, "Files to search. Omit for stdin.");

        zopts.parseOrDie();

        if (show_help) {
            zopts.printHelpAndDie();
        }

        var result = .{
            .cfg = cfg,
            .data = zopts.toOwnedSlice(),
        };

        return result;
    }
    
    pub fn main() !void {
        var opts = try parseOpts(std.heap.page_allocator);
        defer {
            for (opts.data) |ptr| {
                std.heap.page_allocator.free(ptr);
            }
            std.heap.page_allocator.free(opts.data);
        }
        
        var cfg = opts.cfg;
        
        // Go about your business
    }
