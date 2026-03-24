const std = @import("std");
const core = @import("lib.zig");
const surface = @import("surface.zig");

const SAMPLE_RATE: f64 = 48_000.0;
const PERIODS = [_]usize{ 64, 128, 256 };
const BUFFERS_PER_CASE: usize = 512;
const PATCH_CASES = [_][]const u8{
    "../../patches/piano.dsl",
    "../../patches/vangelis.dsl",
    "../../patches/bright_saw_8.dsl",
};
const SYNTH_CASES = [_]SynthCase{
    .{ .name = "bank_256", .oscillators = 256, .modulated = false },
    .{ .name = "bank_1024", .oscillators = 1024, .modulated = false },
    .{ .name = "mod_bank_256", .oscillators = 256, .modulated = true },
    .{ .name = "mod_bank_1024", .oscillators = 1024, .modulated = true },
};

const SynthCase = struct {
    name: []const u8,
    oscillators: usize,
    modulated: bool,
};

const BufferStats = struct {
    mean_ns: f64,
    p99_ns: u64,
    max_ns: u64,
    deadline_misses: usize,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.fs.File.Writer.init(std.fs.File.stdout(), &stdout_buffer);

    try stdout.interface.writeAll("== Patch Corpus ==\n");
    for (PATCH_CASES) |path| {
        try benchPatch(allocator, &stdout.interface, path);
    }

    try stdout.interface.writeAll("\n== Synthetic Corpus ==\n");
    for (SYNTH_CASES) |case| {
        try benchSyntheticCase(allocator, &stdout.interface, case);
    }
    try stdout.interface.flush();
}

fn benchPatch(allocator: std.mem.Allocator, writer: anytype, path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const case_allocator = arena.allocator();

    var program = try loadProgram(case_allocator, path);
    defer program.deinit(case_allocator);

    var timer = try std.time.Timer.start();
    var compiled = try surface.compile(case_allocator, program);
    const compile_ns = timer.read();
    defer compiled.deinit();

    try printCompiledHeader(writer, path, compile_ns, compiled);
    try benchCompiled(case_allocator, writer, &compiled);
}

fn benchSyntheticCase(allocator: std.mem.Allocator, writer: anytype, synth_case: SynthCase) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const case_allocator = arena.allocator();

    const program = try buildOscillatorBankProgram(case_allocator, synth_case.oscillators, synth_case.modulated);

    var timer = try std.time.Timer.start();
    var compiled = try core.compile(case_allocator, program);
    const compile_ns = timer.read();
    defer compiled.deinit();

    try printCompiledHeader(writer, synth_case.name, compile_ns, compiled);
    try benchCompiled(case_allocator, writer, &compiled);
}

fn benchCompiled(allocator: std.mem.Allocator, writer: anytype, compiled: *const core.CompiledProgram) !void {
    for (PERIODS) |frames_per_buffer| {
        const stats = try dryRealtimeStats(allocator, compiled, frames_per_buffer, BUFFERS_PER_CASE);
        const budget_ns = framesToBudgetNs(frames_per_buffer);
        try writer.print(
            "  {d:>3}f: mean={d:.3}ms p99={d:.3}ms max={d:.3}ms budget={d:.3}ms misses={d}\n",
            .{
                frames_per_buffer,
                nsToMsFloat(stats.mean_ns),
                nsToMsInt(stats.p99_ns),
                nsToMsInt(stats.max_ns),
                nsToMsInt(budget_ns),
                stats.deadline_misses,
            },
        );
    }
}

fn dryRealtimeStats(
    allocator: std.mem.Allocator,
    compiled: *const core.CompiledProgram,
    frames_per_buffer: usize,
    buffer_count: usize,
) !BufferStats {
    var runtime = try compiled.makeRuntime(allocator, SAMPLE_RATE);
    defer runtime.deinit();

    const input_values = try allocator.alloc(f64, compiled.input_names.len);
    defer allocator.free(input_values);
    const durations = try allocator.alloc(u64, buffer_count);
    defer allocator.free(durations);

    var timer = try std.time.Timer.start();
    var deadline_misses: usize = 0;
    const deadline_ns = framesToBudgetNs(frames_per_buffer);
    var frame_index: usize = 0;
    for (0..buffer_count) |buffer_index| {
        for (0..frames_per_buffer) |_| {
            fillInputs(compiled, input_values, frame_index);
            _ = try runtime.step(input_values);
            frame_index += 1;
        }
        durations[buffer_index] = timer.lap();
        if (durations[buffer_index] > deadline_ns) deadline_misses += 1;
    }

    const sorted = try allocator.dupe(u64, durations);
    defer allocator.free(sorted);
    std.mem.sort(u64, sorted, {}, std.sort.asc(u64));

    var total_ns: u128 = 0;
    var max_ns: u64 = 0;
    for (durations) |duration| {
        total_ns += duration;
        max_ns = @max(max_ns, duration);
    }
    const p99_index = if (sorted.len == 0) 0 else ((sorted.len - 1) * 99) / 100;

    return .{
        .mean_ns = @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(buffer_count)),
        .p99_ns = sorted[p99_index],
        .max_ns = max_ns,
        .deadline_misses = deadline_misses,
    };
}

fn loadProgram(allocator: std.mem.Allocator, path: []const u8) !surface.Program {
    const source = try std.fs.cwd().readFileAlloc(allocator, path, 1 << 20);
    defer allocator.free(source);

    const outcome = try surface.parse(allocator, source);
    if (outcome.diagnostic) |diagnostic| {
        std.log.err("{s}: line {}: {s}", .{ path, diagnostic.line, diagnostic.message });
        return error.ParseFailed;
    }

    const program = outcome.program.?;
    if (try surface.validate(allocator, program)) |diagnostic| {
        std.log.err("{s}: line {}: {s}", .{ path, diagnostic.line, diagnostic.message });
        return error.InvalidProgram;
    }
    return program;
}

fn buildOscillatorBankProgram(
    allocator: std.mem.Allocator,
    oscillator_count: usize,
    modulated: bool,
) !core.CoreProgram {
    var terms = std.ArrayListUnmanaged(core.Expr).empty;
    defer terms.deinit(allocator);

    for (0..oscillator_count) |index| {
        const partial = @as(f64, @floatFromInt(1 + (index % 16)));
        const detune = 1.0 + (@as(f64, @floatFromInt(index % 11)) - 5.0) * 0.0008;
        var freq_expr = try call2(allocator, "mul", ref("freq"), number(partial * detune));

        if (modulated) {
            const mod_rate = 0.05 + @as(f64, @floatFromInt(index % 23)) * 0.0375;
            const depth = 0.001 + @as(f64, @floatFromInt(index % 7)) * 0.00035;
            const mod_osc = try call1(allocator, "sin", try call1(allocator, "phase", number(mod_rate)));
            const mod_scale = try call2(
                allocator,
                "add",
                number(1.0),
                try call2(allocator, "mul", mod_osc, number(depth)),
            );
            freq_expr = try call2(allocator, "mul", freq_expr, mod_scale);
        }

        const gain = 1.0 / @as(f64, @floatFromInt(1 + (index % 24)));
        const osc = try call1(allocator, "sin", try call1(allocator, "phase", freq_expr));
        const term = try call2(allocator, "mul", osc, number(gain));
        try terms.append(allocator, term);
    }

    const bindings = try allocator.dupe(core.Binding, &.{
        .{ .name = "out", .expr = try callN(allocator, "mix", terms.items) },
    });

    return .{
        .inputs = try allocator.dupe([]const u8, &.{"freq"}),
        .bindings = bindings,
    };
}

fn fillInputs(compiled: *const core.CompiledProgram, input_values: []f64, frame_index: usize) void {
    const t = @as(f64, @floatFromInt(frame_index));
    for (compiled.input_names, 0..) |name, index| {
        if (std.mem.eql(u8, name, "note")) {
            input_values[index] = 60.0;
        } else if (std.mem.eql(u8, name, "gate")) {
            input_values[index] = 1.0;
        } else if (std.mem.eql(u8, name, "freq")) {
            input_values[index] = 220.0;
        } else if (std.mem.eql(u8, name, "x")) {
            input_values[index] = @sin(t * 0.001);
        } else {
            input_values[index] = 0.25;
        }
    }
}

fn printCompiledHeader(writer: anytype, name: []const u8, compile_ns: u64, compiled: core.CompiledProgram) !void {
    try writer.print(
        "{s}\n  compile={d:.3}ms instructions={d} osc_bank_terms={d} slots={d}\n",
        .{
            name,
            nsToMsInt(compile_ns),
            compiled.instructions.len,
            compiled.osc_bank_terms.len,
            compiled.slot_count,
        },
    );
}

fn framesToBudgetNs(frames_per_buffer: usize) u64 {
    return @intFromFloat((@as(f64, @floatFromInt(frames_per_buffer)) * std.time.ns_per_s) / SAMPLE_RATE);
}

fn nsToMsInt(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / @as(f64, std.time.ns_per_ms);
}

fn nsToMsFloat(ns: f64) f64 {
    return ns / @as(f64, std.time.ns_per_ms);
}

fn number(value: f64) core.Expr {
    return .{ .number = value };
}

fn ref(name: []const u8) core.Expr {
    return .{ .ref_ = name };
}

fn call1(allocator: std.mem.Allocator, name: []const u8, arg: core.Expr) !core.Expr {
    return .{ .call = .{ .name = name, .args = try allocator.dupe(core.Expr, &.{arg}) } };
}

fn call2(allocator: std.mem.Allocator, name: []const u8, left: core.Expr, right: core.Expr) !core.Expr {
    return .{ .call = .{ .name = name, .args = try allocator.dupe(core.Expr, &.{ left, right }) } };
}

fn callN(allocator: std.mem.Allocator, name: []const u8, args: []const core.Expr) !core.Expr {
    return .{ .call = .{ .name = name, .args = try allocator.dupe(core.Expr, args) } };
}
