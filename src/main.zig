const std = @import("std");
const surface = @import("surface.zig");
const realtime = @import("realtime.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    if (args.len < 2) {
        try printUsage();
        return;
    }

    if (std.mem.eql(u8, args[1], "check")) {
        if (args.len != 3) return error.InvalidArguments;
        try runCheck(allocator, args[2]);
        return;
    }

    if (std.mem.eql(u8, args[1], "render")) {
        if (args.len < 5) return error.InvalidArguments;
        const frames = try std.fmt.parseInt(usize, args[3], 10);
        const sample_rate = try std.fmt.parseFloat(f64, args[4]);
        try runRender(allocator, args[2], frames, sample_rate, args[5..]);
        return;
    }

    if (std.mem.eql(u8, args[1], "play")) {
        if (args.len != 3) return error.InvalidArguments;
        try runPlay(allocator, args[2]);
        return;
    }

    try printUsage();
}

fn runCheck(allocator: std.mem.Allocator, path: []const u8) !void {
    var program = try loadProgram(allocator, path);
    defer program.deinit(allocator);
    std.debug.print("ok\n", .{});
}

fn runRender(
    allocator: std.mem.Allocator,
    path: []const u8,
    frames: usize,
    sample_rate: f64,
    input_args: []const []const u8,
) !void {
    var program = try loadProgram(allocator, path);
    defer program.deinit(allocator);

    const inputs = try parseInputArgs(allocator, program, frames, input_args);
    const output = try surface.render(allocator, program, inputs, frames, sample_rate);
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.fs.File.Writer.init(std.fs.File.stdout(), &stdout_buffer);
    try stdout.interface.writeAll("[");
    for (output, 0..) |sample, index| {
        if (index != 0) try stdout.interface.writeAll(", ");
        try stdout.interface.print("{d:.8}", .{sample});
    }
    try stdout.interface.writeAll("]\n");
    try stdout.interface.flush();
}

fn runPlay(allocator: std.mem.Allocator, path: []const u8) !void {
    var program = try loadProgram(allocator, path);
    defer program.deinit(allocator);
    var compiled = try surface.compile(allocator, program);
    defer compiled.deinit();
    try realtime.playProgram(allocator, &compiled);
}

fn loadProgram(allocator: std.mem.Allocator, path: []const u8) !surface.Program {
    const source = try std.fs.cwd().readFileAlloc(allocator, path, 1 << 20);
    defer allocator.free(source);
    const outcome = try surface.parse(allocator, source);
    if (outcome.diagnostic) |diagnostic| {
        std.log.err("line {}: {s}", .{ diagnostic.line, diagnostic.message });
        return error.ParseFailed;
    }
    var program = outcome.program.?;
    if (try surface.validate(allocator, program)) |diagnostic| {
        std.log.err("line {}: {s}", .{ diagnostic.line, diagnostic.message });
        program.deinit(allocator);
        return error.InvalidProgram;
    }
    return program;
}

fn parseInputArgs(
    allocator: std.mem.Allocator,
    program: surface.Program,
    frames: usize,
    args: []const []const u8,
) ![]const []const f64 {
    var values = std.StringHashMap([]const f64).init(allocator);
    defer values.deinit();

    for (args) |arg| {
        const eq_index = std.mem.indexOfScalar(u8, arg, '=') orelse return error.InvalidInputArgument;
        const name = arg[0..eq_index];
        const payload = arg[eq_index + 1 ..];
        if (!programHasInput(program, name)) return error.UnexpectedInput;
        if (values.contains(name)) return error.DuplicateInput;
        try values.put(name, try parseInputValue(allocator, payload, frames));
    }

    const streams = try allocator.alloc([]const f64, program.inputs.len);
    for (program.inputs, 0..) |name, index| {
        streams[index] = values.get(name) orelse return error.MissingInput;
    }
    return streams;
}

fn parseInputValue(allocator: std.mem.Allocator, payload: []const u8, frames: usize) ![]const f64 {
    if (std.mem.indexOfScalar(u8, payload, ',')) |_| {
        var samples = std.ArrayListUnmanaged(f64){};
        defer samples.deinit(allocator);
        var iter = std.mem.splitScalar(u8, payload, ',');
        while (iter.next()) |part| {
            const value = try std.fmt.parseFloat(f64, std.mem.trim(u8, part, " \t\r"));
            if (!std.math.isFinite(value)) return error.InvalidInputArgument;
            try samples.append(allocator, value);
        }
        if (samples.items.len != frames) return error.InvalidFrameCount;
        return samples.toOwnedSlice(allocator);
    }

    const value = try std.fmt.parseFloat(f64, payload);
    if (!std.math.isFinite(value)) return error.InvalidInputArgument;
    const stream = try allocator.alloc(f64, frames);
    @memset(stream, value);
    return stream;
}

fn programHasInput(program: surface.Program, name: []const u8) bool {
    for (program.inputs) |input_name| {
        if (std.mem.eql(u8, input_name, name)) return true;
    }
    return false;
}

fn printUsage() !void {
    std.debug.print(
        \\Usage:
        \\  dspdsl check <patch.dsl>
        \\  dspdsl render <patch.dsl> <frames> <sample_rate> <name=value>...
        \\  dspdsl play <patch.dsl>
        \\
        \\Input values may be scalars or comma-separated frame lists.
        \\Example:
        \\  dspdsl render patches/functions.dsl 4 4 freq=1
        \\  dspdsl play patches/piano.dsl
        \\
    , .{});
}
