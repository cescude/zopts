# Command Line parsing with ZOpts

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
unsigned int):

    var num_hats: u32 = 0;
    var distance: i8 = 0;
    
    try opts.flag("num-hats", 'n', &num_hats);
    try opts.flag("distance", 'd', &distance);
    
Pass any of the above as an optional to detect if it was omitted:

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
    
To provide extra information for the help string, use `flagDecl` rather than
`flag`. This will give more context when printing usage information.

    var name: ?[]const u8 = null;
    
    try opts.flagDecl("name", 'f', &name, "NAME", "Name of the user running a query");
