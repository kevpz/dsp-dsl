const std = @import("std");

pub const Expr = union(enum) {
    number: f64,
    ref_: []const u8,
    call: Call,

    pub fn clone(self: Expr, allocator: std.mem.Allocator, duplicate_names: bool) !Expr {
        return switch (self) {
            .number => self,
            .ref_ => |name| .{
                .ref_ = if (duplicate_names) try allocator.dupe(u8, name) else name,
            },
            .call => |call| blk: {
                var args = try allocator.alloc(Expr, call.args.len);
                errdefer allocator.free(args);
                for (call.args, 0..) |arg, index| {
                    args[index] = try arg.clone(allocator, duplicate_names);
                }
                break :blk .{
                    .call = .{
                        .name = if (duplicate_names) try allocator.dupe(u8, call.name) else call.name,
                        .args = args,
                    },
                };
            },
        };
    }

    pub fn deinit(self: Expr, allocator: std.mem.Allocator, free_names: bool) void {
        switch (self) {
            .number => {},
            .ref_ => |name| {
                if (free_names) allocator.free(name);
            },
            .call => |call| {
                for (call.args) |arg| {
                    arg.deinit(allocator, free_names);
                }
                allocator.free(call.args);
                if (free_names) allocator.free(call.name);
            },
        }
    }
};

pub const Call = struct {
    name: []const u8,
    args: []const Expr,
};

pub const Binding = struct {
    name: []const u8,
    expr: Expr,
};

pub const CoreProgram = struct {
    inputs: []const []const u8,
    bindings: []const Binding,
    owned_names: bool = false,

    pub fn deinit(self: *const CoreProgram, allocator: std.mem.Allocator) void {
        for (self.bindings) |binding| {
            binding.expr.deinit(allocator, self.owned_names);
            if (self.owned_names) allocator.free(binding.name);
        }
        if (self.owned_names) {
            for (self.inputs) |name| {
                allocator.free(name);
            }
        }
        allocator.free(self.inputs);
        allocator.free(self.bindings);
    }
};

pub const BinaryInstruction = struct {
    left_slot: usize,
    right_slot: usize,
    out_slot: usize,
};

pub const UnaryInstruction = struct {
    arg_slot: usize,
    out_slot: usize,
};

pub const MixInstruction = struct {
    args_start: usize,
    args_len: usize,
    out_slot: usize,
};

pub const PhaseInstruction = struct {
    freq_slot: usize,
    out_slot: usize,
    state_index: usize,
};

pub const OscInstruction = struct {
    freq_slot: usize,
    out_slot: usize,
    state_index: usize,
    freq_scale_slot: usize = no_slot,
    gain_slot: usize = no_slot,
    freq_multiplier: f64 = 1.0,
    output_multiplier: f64 = 1.0,
};

pub const OscBankTerm = struct {
    freq_slot: usize,
    state_index: usize,
    freq_scale_slot: usize = no_slot,
    gain_slot: usize = no_slot,
    freq_multiplier: f64 = 1.0,
    output_multiplier: f64 = 1.0,
};

pub const OscBankInstruction = struct {
    terms_start: usize,
    terms_len: usize,
    out_slot: usize,
};

pub const AdsrInstruction = struct {
    gate_slot: usize,
    attack_slot: usize,
    decay_slot: usize,
    sustain_slot: usize,
    release_slot: usize,
    out_slot: usize,
    state_index: usize,
};

pub const AdsrConstInstruction = struct {
    gate_slot: usize,
    out_slot: usize,
    state_index: usize,
    attack: f64,
    decay: f64,
    sustain: f64,
    release: f64,
};

pub const LowpassInstruction = struct {
    input_slot: usize,
    cutoff_slot: usize,
    out_slot: usize,
    state_index: usize,
};

pub const LowpassConstInstruction = struct {
    input_slot: usize,
    out_slot: usize,
    state_index: usize,
    cutoff: f64,
};

pub const Instruction = union(BuiltinOp) {
    add: BinaryInstruction,
    sub: BinaryInstruction,
    mul: BinaryInstruction,
    mix: MixInstruction,
    mtof: UnaryInstruction,
    phase: PhaseInstruction,
    sin: UnaryInstruction,
    osc: OscInstruction,
    osc_bank: OscBankInstruction,
    adsr: AdsrInstruction,
    adsr_const: AdsrConstInstruction,
    lowpass: LowpassInstruction,
    lowpass_const: LowpassConstInstruction,
};

pub const CompiledProgram = struct {
    allocator: std.mem.Allocator,
    input_names: []const []const u8,
    input_slots: []const usize,
    const_slots: []const usize,
    const_values: []const f64,
    mix_arg_slots: []const usize,
    osc_bank_terms: []const OscBankTerm,
    instructions: []const Instruction,
    output_slot: usize,
    slot_count: usize,
    phase_state_count: usize,
    adsr_state_count: usize,
    lowpass_state_count: usize,

    pub fn deinit(self: *CompiledProgram) void {
        for (self.input_names) |name| {
            self.allocator.free(name);
        }
        self.allocator.free(self.input_names);
        self.allocator.free(self.input_slots);
        self.allocator.free(self.const_slots);
        self.allocator.free(self.const_values);
        self.allocator.free(self.mix_arg_slots);
        self.allocator.free(self.osc_bank_terms);
        self.allocator.free(self.instructions);
    }

    pub fn makeRuntime(self: *const CompiledProgram, allocator: std.mem.Allocator, sample_rate: f64) !Runtime {
        return Runtime.init(allocator, self, sample_rate);
    }
};

pub const BuiltinOp = enum {
    add,
    sub,
    mul,
    mix,
    mtof,
    phase,
    sin,
    osc,
    osc_bank,
    adsr,
    adsr_const,
    lowpass,
    lowpass_const,
};

pub const StateKind = enum {
    phase,
    adsr,
    lowpass,
};

const no_slot = std.math.maxInt(usize);

const CompiledValue = struct {
    slot: usize,
    temporary: bool,
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    compiled: *const CompiledProgram,
    sample_rate: f64,
    values: []f64,
    phase_states: []PhaseState,
    adsr_states: []AdsrState,
    lowpass_states: []LowpassState,

    pub fn init(allocator: std.mem.Allocator, compiled: *const CompiledProgram, sample_rate: f64) !Runtime {
        if (!std.math.isFinite(sample_rate) or sample_rate <= 0.0) return error.InvalidSampleRate;
        const values = try allocator.alloc(f64, compiled.slot_count);
        @memset(values, 0.0);
        const phase_states = try allocator.alloc(PhaseState, compiled.phase_state_count);
        errdefer allocator.free(phase_states);
        @memset(phase_states, .{});
        const adsr_states = try allocator.alloc(AdsrState, compiled.adsr_state_count);
        errdefer allocator.free(adsr_states);
        @memset(adsr_states, .{});
        const lowpass_states = try allocator.alloc(LowpassState, compiled.lowpass_state_count);
        errdefer allocator.free(lowpass_states);
        @memset(lowpass_states, .{});
        for (compiled.const_slots, compiled.const_values) |slot, value| {
            values[slot] = value;
        }
        return .{
            .allocator = allocator,
            .compiled = compiled,
            .sample_rate = sample_rate,
            .values = values,
            .phase_states = phase_states,
            .adsr_states = adsr_states,
            .lowpass_states = lowpass_states,
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.allocator.free(self.values);
        self.allocator.free(self.phase_states);
        self.allocator.free(self.adsr_states);
        self.allocator.free(self.lowpass_states);
    }

    pub fn step(self: *Runtime, input_values: []const f64) !f64 {
        if (input_values.len != self.compiled.input_slots.len) return error.InvalidInputArity;

        for (self.compiled.input_slots, input_values) |slot, value| {
            self.values[slot] = value;
        }

        for (self.compiled.instructions) |instruction| {
            const out_slot = instructionOutSlot(instruction);
            self.values[out_slot] = try executeInstruction(
                self.compiled,
                instruction,
                self.values,
                self.phase_states,
                self.adsr_states,
                self.lowpass_states,
                self.sample_rate,
            );
        }

        return self.values[self.compiled.output_slot];
    }
};

pub const PhaseState = struct {
    phase: f64 = 0.0,

    pub fn step(self: *PhaseState, freq: f64, sample_rate: f64) f64 {
        const output = self.phase;
        self.phase = @mod(self.phase + (freq / sample_rate), 1.0);
        return output;
    }
};

pub const LowpassState = struct {
    y_prev: f64 = 0.0,

    pub fn step(self: *LowpassState, x: f64, cutoff: f64, sample_rate: f64) f64 {
        const clamped = std.math.clamp(cutoff, 0.0, sample_rate / 2.0);
        const a = @exp((-2.0 * std.math.pi * clamped) / sample_rate);
        const y = (1.0 - a) * x + a * self.y_prev;
        self.y_prev = y;
        return y;
    }
};

pub const AdsrState = struct {
    stage: Stage = .idle,
    level: f64 = 0.0,
    gate_prev: f64 = 0.0,
    remaining: usize = 0,
    increment: f64 = 0.0,
    target: f64 = 0.0,
    sustain_level: f64 = 0.0,
    decay_samples: usize = 1,

    const Stage = enum { idle, attack, decay, sustain, release };

    pub fn step(
        self: *AdsrState,
        gate: f64,
        attack: f64,
        decay: f64,
        sustain: f64,
        release: f64,
        sample_rate: f64,
    ) f64 {
        const rising = self.gate_prev <= 0.0 and gate > 0.0;
        const falling = self.gate_prev > 0.0 and gate <= 0.0;

        if (rising) {
            self.startAttack(attack, decay, sustain, sample_rate);
        } else if (falling) {
            self.startRelease(release, sample_rate);
        }

        self.gate_prev = gate;

        switch (self.stage) {
            .idle => {
                self.level = 0.0;
                return 0.0;
            },
            .sustain => {
                self.level = self.sustain_level;
                return self.level;
            },
            else => {},
        }

        self.level += self.increment;
        self.remaining -= 1;

        if (self.remaining == 0) {
            self.level = self.target;
            switch (self.stage) {
                .attack => self.startDecay(),
                .decay => {
                    self.stage = .sustain;
                    self.level = self.sustain_level;
                    self.increment = 0.0;
                },
                .release => {
                    self.stage = .idle;
                    self.level = 0.0;
                    self.increment = 0.0;
                },
                else => {},
            }
        }

        return self.level;
    }

    fn startAttack(self: *AdsrState, attack: f64, decay: f64, sustain: f64, sample_rate: f64) void {
        self.sustain_level = std.math.clamp(sustain, 0.0, 1.0);
        self.decay_samples = secondsToSamples(decay, sample_rate);
        self.beginSegment(.attack, 1.0, secondsToSamples(attack, sample_rate));
    }

    fn startDecay(self: *AdsrState) void {
        self.beginSegment(.decay, self.sustain_level, self.decay_samples);
    }

    fn startRelease(self: *AdsrState, release: f64, sample_rate: f64) void {
        self.beginSegment(.release, 0.0, secondsToSamples(release, sample_rate));
    }

    fn beginSegment(self: *AdsrState, stage: Stage, target: f64, samples: usize) void {
        const count = @max(@as(usize, 1), samples);
        self.stage = stage;
        self.target = target;
        self.remaining = count;
        self.increment = (target - self.level) / @as(f64, @floatFromInt(count));
    }
};

pub fn compile(allocator: std.mem.Allocator, program: CoreProgram) !CompiledProgram {
    const live_analysis = try analyzeLiveBindings(allocator, program);
    defer live_analysis.deinit(allocator);

    var compiler = Compiler{
        .allocator = allocator,
        .program = program,
        .constant_slots = .empty,
        .constant_values = .empty,
        .mix_arg_slots = .empty,
        .osc_bank_terms = .empty,
        .instructions = .empty,
        .name_slots = std.StringHashMap(usize).init(allocator),
        .constant_cache = std.AutoHashMap(u64, usize).init(allocator),
        .free_temp_slots = .empty,
        .next_slot = 0,
    };
    defer compiler.constant_slots.deinit(allocator);
    defer compiler.constant_values.deinit(allocator);
    defer compiler.mix_arg_slots.deinit(allocator);
    defer compiler.osc_bank_terms.deinit(allocator);
    defer compiler.instructions.deinit(allocator);
    defer compiler.name_slots.deinit();
    defer compiler.constant_cache.deinit();
    defer compiler.free_temp_slots.deinit(allocator);
    try compiler.free_temp_slots.ensureTotalCapacity(allocator, live_analysis.node_count);

    for (program.inputs) |name| {
        const slot = compiler.allocPersistentSlot();
        try compiler.name_slots.put(name, slot);
    }

    for (program.bindings, 0..) |binding, index| {
        if (!live_analysis.live[index]) continue;
        const value = try compiler.compileExpr(binding.expr);
        try compiler.name_slots.put(binding.name, value.slot);
    }

    var input_names = try allocator.alloc([]const u8, program.inputs.len);
    errdefer {
        for (input_names[0..]) |name| allocator.free(name);
        allocator.free(input_names);
    }
    var input_slots = try allocator.alloc(usize, program.inputs.len);
    errdefer allocator.free(input_slots);
    for (program.inputs, 0..) |name, index| {
        input_names[index] = try allocator.dupe(u8, name);
        input_slots[index] = compiler.name_slots.get(name).?;
    }
    const const_slots = try compiler.constant_slots.toOwnedSlice(allocator);
    const const_values = try compiler.constant_values.toOwnedSlice(allocator);
    const mix_arg_slots = try compiler.mix_arg_slots.toOwnedSlice(allocator);
    const osc_bank_terms = try compiler.osc_bank_terms.toOwnedSlice(allocator);
    const instructions = try compiler.instructions.toOwnedSlice(allocator);

    return .{
        .allocator = allocator,
        .input_names = input_names,
        .input_slots = input_slots,
        .const_slots = const_slots,
        .const_values = const_values,
        .mix_arg_slots = mix_arg_slots,
        .osc_bank_terms = osc_bank_terms,
        .instructions = instructions,
        .output_slot = compiler.name_slots.get("out") orelse return error.MissingOut,
        .slot_count = compiler.next_slot,
        .phase_state_count = compiler.phase_state_count,
        .adsr_state_count = compiler.adsr_state_count,
        .lowpass_state_count = compiler.lowpass_state_count,
    };
}

pub fn render(
    allocator: std.mem.Allocator,
    program: CoreProgram,
    inputs: []const []const f64,
    frames: usize,
    sample_rate: f64,
) ![]f64 {
    if (inputs.len != program.inputs.len) return error.InvalidInputArity;
    for (inputs) |stream| {
        if (stream.len != frames) return error.InvalidFrameCount;
    }

    var compiled = try compile(allocator, program);
    defer compiled.deinit();

    var runtime = try compiled.makeRuntime(allocator, sample_rate);
    defer runtime.deinit();

    var frame_inputs = try allocator.alloc(f64, inputs.len);
    defer allocator.free(frame_inputs);

    var output = try allocator.alloc(f64, frames);
    for (0..frames) |frame| {
        for (inputs, 0..) |stream, index| {
            frame_inputs[index] = stream[frame];
        }
        output[frame] = try runtime.step(frame_inputs);
    }
    return output;
}

const LiveBindingAnalysis = struct {
    live: []bool,
    node_count: usize,

    fn deinit(self: LiveBindingAnalysis, allocator: std.mem.Allocator) void {
        allocator.free(self.live);
    }
};

fn analyzeLiveBindings(allocator: std.mem.Allocator, program: CoreProgram) !LiveBindingAnalysis {
    var binding_indices = std.StringHashMap(usize).init(allocator);
    defer binding_indices.deinit();
    for (program.bindings, 0..) |binding, index| {
        try binding_indices.put(binding.name, index);
    }

    const live = try allocator.alloc(bool, program.bindings.len);
    errdefer allocator.free(live);
    @memset(live, false);

    var stack = std.ArrayListUnmanaged(usize).empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, program.bindings.len - 1);

    while (stack.items.len > 0) {
        const binding_index = stack.pop().?;
        if (live[binding_index]) continue;
        live[binding_index] = true;
        try collectReferencedBindingIndices(allocator, program.bindings[binding_index].expr, &binding_indices, &stack, live);
    }

    var node_count: usize = 0;
    for (program.bindings, 0..) |binding, index| {
        if (!live[index]) continue;
        node_count += countExprNodes(binding.expr);
    }

    return .{
        .live = live,
        .node_count = node_count,
    };
}

fn collectReferencedBindingIndices(
    allocator: std.mem.Allocator,
    expr: Expr,
    binding_indices: *const std.StringHashMap(usize),
    stack: *std.ArrayListUnmanaged(usize),
    live: []bool,
) !void {
    switch (expr) {
        .number => {},
        .ref_ => |name| {
            if (binding_indices.get(name)) |binding_index| {
                if (!live[binding_index]) try stack.append(allocator, binding_index);
            }
        },
        .call => |call| {
            for (call.args) |arg| {
                try collectReferencedBindingIndices(allocator, arg, binding_indices, stack, live);
            }
        },
    }
}

fn countExprNodes(expr: Expr) usize {
    return switch (expr) {
        .number, .ref_ => 1,
        .call => |call| blk: {
            var total: usize = 1;
            for (call.args) |arg| total += countExprNodes(arg);
            break :blk total;
        },
    };
}

const Compiler = struct {
    allocator: std.mem.Allocator,
    program: CoreProgram,
    constant_slots: std.ArrayListUnmanaged(usize),
    constant_values: std.ArrayListUnmanaged(f64),
    mix_arg_slots: std.ArrayListUnmanaged(usize),
    osc_bank_terms: std.ArrayListUnmanaged(OscBankTerm),
    instructions: std.ArrayListUnmanaged(Instruction),
    name_slots: std.StringHashMap(usize),
    constant_cache: std.AutoHashMap(u64, usize),
    free_temp_slots: std.ArrayListUnmanaged(usize),
    next_slot: usize,
    phase_state_count: usize = 0,
    adsr_state_count: usize = 0,
    lowpass_state_count: usize = 0,

    fn allocPersistentSlot(self: *Compiler) usize {
        const slot = self.next_slot;
        self.next_slot += 1;
        return slot;
    }

    fn allocTemporarySlot(self: *Compiler) usize {
        return self.free_temp_slots.pop() orelse blk: {
            const slot = self.next_slot;
            self.next_slot += 1;
            break :blk slot;
        };
    }

    fn releaseTemporary(self: *Compiler, value: CompiledValue) void {
        if (!value.temporary) return;
        self.free_temp_slots.appendAssumeCapacity(value.slot);
    }

    fn allocState(self: *Compiler, kind: StateKind) usize {
        return switch (kind) {
            .phase => blk: {
                const slot = self.phase_state_count;
                self.phase_state_count += 1;
                break :blk slot;
            },
            .adsr => blk: {
                const slot = self.adsr_state_count;
                self.adsr_state_count += 1;
                break :blk slot;
            },
            .lowpass => blk: {
                const slot = self.lowpass_state_count;
                self.lowpass_state_count += 1;
                break :blk slot;
            },
        };
    }

    fn allocConst(self: *Compiler, value: f64) anyerror!usize {
        const key: u64 = @bitCast(value);
        if (self.constant_cache.get(key)) |slot| return slot;

        const slot = self.allocPersistentSlot();
        try self.constant_slots.append(self.allocator, slot);
        try self.constant_values.append(self.allocator, value);
        try self.constant_cache.put(key, slot);
        return slot;
    }

    fn emitBinaryInstruction(self: *Compiler, op: BuiltinOp, left_slot: usize, right_slot: usize) anyerror!CompiledValue {
        const out_slot = self.allocTemporarySlot();
        const payload: BinaryInstruction = .{
            .left_slot = left_slot,
            .right_slot = right_slot,
            .out_slot = out_slot,
        };
        switch (op) {
            .add => try self.instructions.append(self.allocator, .{ .add = payload }),
            .sub => try self.instructions.append(self.allocator, .{ .sub = payload }),
            .mul => try self.instructions.append(self.allocator, .{ .mul = payload }),
            else => unreachable,
        }
        return .{ .slot = out_slot, .temporary = true };
    }

    fn emitUnaryInstruction(self: *Compiler, op: BuiltinOp, arg_slot: usize) anyerror!CompiledValue {
        const out_slot = self.allocTemporarySlot();
        const payload: UnaryInstruction = .{
            .arg_slot = arg_slot,
            .out_slot = out_slot,
        };
        switch (op) {
            .mtof => try self.instructions.append(self.allocator, .{ .mtof = payload }),
            .sin => try self.instructions.append(self.allocator, .{ .sin = payload }),
            else => unreachable,
        }
        return .{ .slot = out_slot, .temporary = true };
    }

    fn emitMixInstruction(self: *Compiler, arg_slots: []const usize) anyerror!CompiledValue {
        const out_slot = self.allocTemporarySlot();
        const start = self.mix_arg_slots.items.len;
        try self.mix_arg_slots.appendSlice(self.allocator, arg_slots);
        try self.instructions.append(self.allocator, .{
            .mix = .{
                .args_start = start,
                .args_len = arg_slots.len,
                .out_slot = out_slot,
            },
        });
        return .{ .slot = out_slot, .temporary = true };
    }

    fn emitOscBankInstruction(self: *Compiler, term_count: usize) anyerror!CompiledValue {
        const out_slot = self.allocTemporarySlot();
        try self.instructions.append(self.allocator, .{
            .osc_bank = .{
                .terms_start = self.osc_bank_terms.items.len - term_count,
                .terms_len = term_count,
                .out_slot = out_slot,
            },
        });
        return .{ .slot = out_slot, .temporary = true };
    }

    fn compileMulTerms(self: *Compiler, terms: []const Expr) anyerror!?CompiledValue {
        if (terms.len == 0) return null;
        var value = try self.compileExpr(terms[0]);
        for (terms[1..]) |term| {
            const term_value = try self.compileExpr(term);
            errdefer self.releaseTemporary(term_value);
            const out = try self.emitBinaryInstruction(.mul, value.slot, term_value.slot);
            self.releaseTemporary(value);
            self.releaseTemporary(term_value);
            value = out;
        }
        return value;
    }

    fn compileOscillatorExpr(self: *Compiler, expr: Expr) anyerror!?CompiledValue {
        var pattern = try matchOscillatorPattern(self.allocator, expr);
        defer pattern.deinit(self.allocator);
        if (!pattern.matched) return null;

        const freq_value = try self.compileExpr(pattern.freq_base);
        errdefer self.releaseTemporary(freq_value);
        const freq_scale_value = try self.compileMulTerms(pattern.freq_scale_terms);
        errdefer if (freq_scale_value) |value| self.releaseTemporary(value);
        const gain_value = try self.compileMulTerms(pattern.gain_terms);
        errdefer if (gain_value) |value| self.releaseTemporary(value);
        const out_slot = self.allocTemporarySlot();
        const state_slot = self.allocState(.phase);
        try self.instructions.append(self.allocator, .{
            .osc = .{
                .freq_slot = freq_value.slot,
                .out_slot = out_slot,
                .state_index = state_slot,
                .freq_scale_slot = if (freq_scale_value) |value| value.slot else no_slot,
                .gain_slot = if (gain_value) |value| value.slot else no_slot,
                .freq_multiplier = pattern.freq_multiplier,
                .output_multiplier = pattern.gain_multiplier,
            },
        });
        self.releaseTemporary(freq_value);
        if (freq_scale_value) |value| self.releaseTemporary(value);
        if (gain_value) |value| self.releaseTemporary(value);
        return .{ .slot = out_slot, .temporary = true };
    }

    fn compileOscillatorBankExpr(self: *Compiler, expr: Expr) anyerror!?CompiledValue {
        var bank = try matchOscillatorBankPattern(self.allocator, expr);
        defer bank.deinit(self.allocator);
        if (!bank.matched) return null;

        const term_start = self.osc_bank_terms.items.len;
        errdefer self.osc_bank_terms.shrinkRetainingCapacity(term_start);

        var temp_values = std.ArrayListUnmanaged(CompiledValue).empty;
        defer temp_values.deinit(self.allocator);
        var emitted = false;
        defer {
            if (!emitted) {
                for (temp_values.items) |value| self.releaseTemporary(value);
            }
        }

        for (bank.patterns) |pattern| {
            const freq_value = try self.compileExpr(pattern.freq_base);
            if (freq_value.temporary) try temp_values.append(self.allocator, freq_value);
            const freq_scale_value = try self.compileMulTerms(pattern.freq_scale_terms);
            if (freq_scale_value) |value| {
                if (value.temporary) try temp_values.append(self.allocator, value);
            }
            const gain_value = try self.compileMulTerms(pattern.gain_terms);
            if (gain_value) |value| {
                if (value.temporary) try temp_values.append(self.allocator, value);
            }

            try self.osc_bank_terms.append(self.allocator, .{
                .freq_slot = freq_value.slot,
                .state_index = self.allocState(.phase),
                .freq_scale_slot = if (freq_scale_value) |value| value.slot else no_slot,
                .gain_slot = if (gain_value) |value| value.slot else no_slot,
                .freq_multiplier = pattern.freq_multiplier,
                .output_multiplier = pattern.gain_multiplier,
            });
        }

        const out = try self.emitOscBankInstruction(bank.patterns.len);
        for (temp_values.items) |value| self.releaseTemporary(value);
        emitted = true;
        return out;
    }

    fn compileExpr(self: *Compiler, expr: Expr) anyerror!CompiledValue {
        if (try self.compileOscillatorBankExpr(expr)) |value| return value;
        if (try self.compileOscillatorExpr(expr)) |slot| return slot;
        if (evalPureConstExpr(expr)) |value| return .{ .slot = try self.allocConst(value), .temporary = false };
        return switch (expr) {
            .number => |value| .{ .slot = try self.allocConst(value), .temporary = false },
            .ref_ => |name| blk: {
                const slot = self.name_slots.get(name) orelse return error.UnknownIdentifier;
                break :blk .{ .slot = slot, .temporary = false };
            },
            .call => |call| blk: {
                switch (builtinFromName(call.name)) {
                    .add => break :blk try self.compileBinaryCall(call.args, .add),
                    .sub => break :blk try self.compileBinaryCall(call.args, .sub),
                    .mul => break :blk try self.compileBinaryCall(call.args, .mul),
                    .mix => {
                        if (call.args.len == 1) break :blk try self.compileExpr(call.args[0]);
                        var arg_slots = try self.allocator.alloc(usize, call.args.len);
                        defer self.allocator.free(arg_slots);
                        var temp_values = std.ArrayListUnmanaged(CompiledValue).empty;
                        defer temp_values.deinit(self.allocator);
                        for (call.args, 0..) |arg, index| {
                            const value = try self.compileExpr(arg);
                            arg_slots[index] = value.slot;
                            if (value.temporary) try temp_values.append(self.allocator, value);
                        }
                        const out = try self.emitMixInstruction(arg_slots);
                        for (temp_values.items) |value| self.releaseTemporary(value);
                        break :blk out;
                    },
                    .mtof => {
                        const arg = try self.compileExpr(call.args[0]);
                        errdefer self.releaseTemporary(arg);
                        const out = try self.emitUnaryInstruction(.mtof, arg.slot);
                        self.releaseTemporary(arg);
                        break :blk out;
                    },
                    .sin => {
                        const arg = try self.compileExpr(call.args[0]);
                        errdefer self.releaseTemporary(arg);
                        const out = try self.emitUnaryInstruction(.sin, arg.slot);
                        self.releaseTemporary(arg);
                        break :blk out;
                    },
                    .phase => {
                        const freq = try self.compileExpr(call.args[0]);
                        errdefer self.releaseTemporary(freq);
                        const out_slot = self.allocTemporarySlot();
                        try self.instructions.append(self.allocator, .{
                            .phase = .{
                                .freq_slot = freq.slot,
                                .out_slot = out_slot,
                                .state_index = self.allocState(.phase),
                            },
                        });
                        self.releaseTemporary(freq);
                        break :blk .{ .slot = out_slot, .temporary = true };
                    },
                    .adsr => {
                        const gate = try self.compileExpr(call.args[0]);
                        errdefer self.releaseTemporary(gate);
                        const attack = evalPureConstExpr(call.args[1]);
                        const decay = evalPureConstExpr(call.args[2]);
                        const sustain = evalPureConstExpr(call.args[3]);
                        const release = evalPureConstExpr(call.args[4]);
                        const out_slot = self.allocTemporarySlot();
                        if (attack != null and decay != null and sustain != null and release != null) {
                            try self.instructions.append(self.allocator, .{
                                .adsr_const = .{
                                    .gate_slot = gate.slot,
                                    .out_slot = out_slot,
                                    .state_index = self.allocState(.adsr),
                                    .attack = attack.?,
                                    .decay = decay.?,
                                    .sustain = sustain.?,
                                    .release = release.?,
                                },
                            });
                        } else {
                            const attack_value = try self.compileExpr(call.args[1]);
                            errdefer self.releaseTemporary(attack_value);
                            const decay_value = try self.compileExpr(call.args[2]);
                            errdefer self.releaseTemporary(decay_value);
                            const sustain_value = try self.compileExpr(call.args[3]);
                            errdefer self.releaseTemporary(sustain_value);
                            const release_value = try self.compileExpr(call.args[4]);
                            errdefer self.releaseTemporary(release_value);
                            try self.instructions.append(self.allocator, .{
                                .adsr = .{
                                    .gate_slot = gate.slot,
                                    .attack_slot = attack_value.slot,
                                    .decay_slot = decay_value.slot,
                                    .sustain_slot = sustain_value.slot,
                                    .release_slot = release_value.slot,
                                    .out_slot = out_slot,
                                    .state_index = self.allocState(.adsr),
                                },
                            });
                            self.releaseTemporary(attack_value);
                            self.releaseTemporary(decay_value);
                            self.releaseTemporary(sustain_value);
                            self.releaseTemporary(release_value);
                        }
                        self.releaseTemporary(gate);
                        break :blk .{ .slot = out_slot, .temporary = true };
                    },
                    .lowpass => {
                        const input = try self.compileExpr(call.args[0]);
                        errdefer self.releaseTemporary(input);
                        const cutoff = evalPureConstExpr(call.args[1]);
                        const out_slot = self.allocTemporarySlot();
                        if (cutoff) |cutoff_value| {
                            try self.instructions.append(self.allocator, .{
                                .lowpass_const = .{
                                    .input_slot = input.slot,
                                    .out_slot = out_slot,
                                    .state_index = self.allocState(.lowpass),
                                    .cutoff = cutoff_value,
                                },
                            });
                        } else {
                            const cutoff_value = try self.compileExpr(call.args[1]);
                            errdefer self.releaseTemporary(cutoff_value);
                            try self.instructions.append(self.allocator, .{
                                .lowpass = .{
                                    .input_slot = input.slot,
                                    .cutoff_slot = cutoff_value.slot,
                                    .out_slot = out_slot,
                                    .state_index = self.allocState(.lowpass),
                                },
                            });
                            self.releaseTemporary(cutoff_value);
                        }
                        self.releaseTemporary(input);
                        break :blk .{ .slot = out_slot, .temporary = true };
                    },
                    .osc, .osc_bank, .adsr_const, .lowpass_const => unreachable,
                }
            },
        };
    }

    fn compileBinaryCall(self: *Compiler, args: []const Expr, op: BuiltinOp) anyerror!CompiledValue {
        std.debug.assert(args.len == 2);
        const left = try self.compileExpr(args[0]);
        errdefer self.releaseTemporary(left);
        const right = try self.compileExpr(args[1]);
        errdefer self.releaseTemporary(right);
        const out = try self.emitBinaryInstruction(op, left.slot, right.slot);
        self.releaseTemporary(left);
        self.releaseTemporary(right);
        return out;
    }
};

fn builtinFromName(name: []const u8) BuiltinOp {
    if (std.mem.eql(u8, name, "add")) return .add;
    if (std.mem.eql(u8, name, "sub")) return .sub;
    if (std.mem.eql(u8, name, "mul")) return .mul;
    if (std.mem.eql(u8, name, "mix")) return .mix;
    if (std.mem.eql(u8, name, "mtof")) return .mtof;
    if (std.mem.eql(u8, name, "phase")) return .phase;
    if (std.mem.eql(u8, name, "sin")) return .sin;
    if (std.mem.eql(u8, name, "adsr")) return .adsr;
    if (std.mem.eql(u8, name, "lowpass")) return .lowpass;
    @panic("unknown builtin");
}

fn evalPureConstExpr(expr: Expr) ?f64 {
    return switch (expr) {
        .number => |value| value,
        .ref_ => null,
        .call => |call| blk: {
            if (std.mem.eql(u8, call.name, "phase") or std.mem.eql(u8, call.name, "adsr") or std.mem.eql(u8, call.name, "lowpass")) {
                break :blk null;
            }

            if (std.mem.eql(u8, call.name, "add")) {
                const left = evalPureConstExpr(call.args[0]) orelse break :blk null;
                const right = evalPureConstExpr(call.args[1]) orelse break :blk null;
                break :blk left + right;
            }
            if (std.mem.eql(u8, call.name, "sub")) {
                const left = evalPureConstExpr(call.args[0]) orelse break :blk null;
                const right = evalPureConstExpr(call.args[1]) orelse break :blk null;
                break :blk left - right;
            }
            if (std.mem.eql(u8, call.name, "mul")) {
                const left = evalPureConstExpr(call.args[0]) orelse break :blk null;
                const right = evalPureConstExpr(call.args[1]) orelse break :blk null;
                break :blk left * right;
            }
            if (std.mem.eql(u8, call.name, "mix")) {
                var total: f64 = 0.0;
                for (call.args) |arg| {
                    total += evalPureConstExpr(arg) orelse break :blk null;
                }
                break :blk total;
            }
            if (std.mem.eql(u8, call.name, "mtof")) {
                const note = evalPureConstExpr(call.args[0]) orelse break :blk null;
                break :blk 440.0 * @exp2((note - 69.0) / 12.0);
            }
            if (std.mem.eql(u8, call.name, "sin")) {
                const phase = evalPureConstExpr(call.args[0]) orelse break :blk null;
                break :blk @sin(2.0 * std.math.pi * phase);
            }
            break :blk null;
        },
    };
}

fn instructionOutSlot(instruction: Instruction) usize {
    return switch (instruction) {
        .add => |payload| payload.out_slot,
        .sub => |payload| payload.out_slot,
        .mul => |payload| payload.out_slot,
        .mix => |payload| payload.out_slot,
        .mtof => |payload| payload.out_slot,
        .phase => |payload| payload.out_slot,
        .sin => |payload| payload.out_slot,
        .osc => |payload| payload.out_slot,
        .osc_bank => |payload| payload.out_slot,
        .adsr => |payload| payload.out_slot,
        .adsr_const => |payload| payload.out_slot,
        .lowpass => |payload| payload.out_slot,
        .lowpass_const => |payload| payload.out_slot,
    };
}

fn executeInstruction(
    compiled: *const CompiledProgram,
    instruction: Instruction,
    values: []f64,
    phase_states: []PhaseState,
    adsr_states: []AdsrState,
    lowpass_states: []LowpassState,
    sample_rate: f64,
) !f64 {
    return switch (instruction) {
        .add => |payload| values[payload.left_slot] + values[payload.right_slot],
        .sub => |payload| values[payload.left_slot] - values[payload.right_slot],
        .mul => |payload| values[payload.left_slot] * values[payload.right_slot],
        .mix => |payload| blk: {
            var total: f64 = 0.0;
            const arg_slots = compiled.mix_arg_slots[payload.args_start .. payload.args_start + payload.args_len];
            for (arg_slots) |slot| total += values[slot];
            break :blk total;
        },
        .mtof => |payload| 440.0 * @exp2((values[payload.arg_slot] - 69.0) / 12.0),
        .phase => |payload| phase_states[payload.state_index].step(values[payload.freq_slot], sample_rate),
        .sin => |payload| @sin(2.0 * std.math.pi * values[payload.arg_slot]),
        .osc => |payload| blk: {
            var freq = values[payload.freq_slot] * payload.freq_multiplier;
            if (payload.freq_scale_slot != no_slot) freq *= values[payload.freq_scale_slot];
            var output = phase_states[payload.state_index].step(freq, sample_rate);
            output = @sin(2.0 * std.math.pi * output);
            var gain = payload.output_multiplier;
            if (payload.gain_slot != no_slot) gain *= values[payload.gain_slot];
            break :blk output * gain;
        },
        .osc_bank => |payload| blk: {
            var total: f64 = 0.0;
            const terms = compiled.osc_bank_terms[payload.terms_start .. payload.terms_start + payload.terms_len];
            for (terms) |term| {
                var freq = values[term.freq_slot] * term.freq_multiplier;
                if (term.freq_scale_slot != no_slot) freq *= values[term.freq_scale_slot];
                var output = phase_states[term.state_index].step(freq, sample_rate);
                output = @sin(2.0 * std.math.pi * output);
                var gain = term.output_multiplier;
                if (term.gain_slot != no_slot) gain *= values[term.gain_slot];
                total += output * gain;
            }
            break :blk total;
        },
        .adsr => |payload| blk: {
            break :blk adsr_states[payload.state_index].step(
                values[payload.gate_slot],
                values[payload.attack_slot],
                values[payload.decay_slot],
                values[payload.sustain_slot],
                values[payload.release_slot],
                sample_rate,
            );
        },
        .adsr_const => |payload| blk: {
            break :blk adsr_states[payload.state_index].step(
                values[payload.gate_slot],
                payload.attack,
                payload.decay,
                payload.sustain,
                payload.release,
                sample_rate,
            );
        },
        .lowpass => |payload| lowpass_states[payload.state_index].step(
            values[payload.input_slot],
            values[payload.cutoff_slot],
            sample_rate,
        ),
        .lowpass_const => |payload| lowpass_states[payload.state_index].step(
            values[payload.input_slot],
            payload.cutoff,
            sample_rate,
        ),
    };
}

fn secondsToSamples(seconds: f64, sample_rate: f64) usize {
    const clamped = if (seconds < 0.0) 0.0 else seconds;
    const rounded = @round(clamped * sample_rate);
    const count: usize = @intFromFloat(rounded);
    return @max(@as(usize, 1), count);
}

fn exprNumber(value: f64) Expr {
    return .{ .number = value };
}

fn exprRef(name: []const u8) Expr {
    return .{ .ref_ = name };
}

fn exprCall(name: []const u8, args: []const Expr) Expr {
    return .{ .call = .{ .name = name, .args = args } };
}

const OscillatorPattern = struct {
    matched: bool = false,
    freq_base: Expr = undefined,
    freq_scale_terms: []Expr = &.{},
    freq_multiplier: f64 = 1.0,
    gain_terms: []Expr = &.{},
    gain_multiplier: f64 = 1.0,

    fn deinit(self: *OscillatorPattern, allocator: std.mem.Allocator) void {
        allocator.free(self.freq_scale_terms);
        allocator.free(self.gain_terms);
    }
};

const OscillatorBankPattern = struct {
    matched: bool = false,
    patterns: []OscillatorPattern = &.{},

    fn deinit(self: *OscillatorBankPattern, allocator: std.mem.Allocator) void {
        for (self.patterns) |*pattern| pattern.deinit(allocator);
        allocator.free(self.patterns);
    }
};

const GainAccumulator = struct {
    multiplier: f64 = 1.0,
    dynamic_terms: std.ArrayListUnmanaged(Expr) = .empty,

    fn deinit(self: *GainAccumulator, allocator: std.mem.Allocator) void {
        self.dynamic_terms.deinit(allocator);
    }
};

const CoreOscillator = struct {
    found: bool = false,
    freq_expr: Expr = undefined,
};

fn matchOscillatorPattern(allocator: std.mem.Allocator, expr: Expr) !OscillatorPattern {
    switch (expr) {
        .call => |call| {
            if (std.mem.eql(u8, call.name, "mul") and call.args.len == 2) {
                const left_core = matchOscillatorCore(call.args[0]);
                if (left_core.found and exprIsStateless(call.args[1])) {
                    return buildOscillatorPattern(allocator, left_core.freq_expr, call.args[1]);
                }

                const right_core = matchOscillatorCore(call.args[1]);
                if (right_core.found and exprIsStateless(call.args[0])) {
                    return buildOscillatorPattern(allocator, right_core.freq_expr, call.args[0]);
                }
            }
        },
        else => {},
    }

    const core = matchOscillatorCore(expr);
    if (!core.found) return .{};
    return buildOscillatorPattern(allocator, core.freq_expr, null);
}

fn matchOscillatorCore(expr: Expr) CoreOscillator {
    return switch (expr) {
        .call => |sin_call| blk: {
            if (!std.mem.eql(u8, sin_call.name, "sin") or sin_call.args.len != 1) break :blk .{};
            switch (sin_call.args[0]) {
                .call => |phase_call| {
                    if (!std.mem.eql(u8, phase_call.name, "phase") or phase_call.args.len != 1) break :blk .{};
                    break :blk .{
                        .found = true,
                        .freq_expr = phase_call.args[0],
                    };
                },
                else => break :blk .{},
            }
        },
        else => .{},
    };
}

fn buildOscillatorPattern(
    allocator: std.mem.Allocator,
    freq_expr: Expr,
    gain_expr: ?Expr,
) !OscillatorPattern {
    var freq_terms = std.ArrayListUnmanaged(Expr).empty;
    defer freq_terms.deinit(allocator);
    try collectMulTerms(allocator, freq_expr, &freq_terms);

    var dynamic_freq_terms = std.ArrayListUnmanaged(Expr).empty;
    defer dynamic_freq_terms.deinit(allocator);
    var freq_multiplier: f64 = 1.0;
    for (freq_terms.items) |term| {
        switch (term) {
            .number => |value| freq_multiplier *= value,
            else => try dynamic_freq_terms.append(allocator, term),
        }
    }

    var freq_base: Expr = undefined;
    var freq_scale_terms: []Expr = &.{};
    if (dynamic_freq_terms.items.len == 0) {
        freq_base = .{ .number = 1.0 };
    } else {
        freq_base = dynamic_freq_terms.items[0];
        freq_scale_terms = try allocator.dupe(Expr, dynamic_freq_terms.items[1..]);
    }

    var gain_terms_list = std.ArrayListUnmanaged(Expr).empty;
    defer gain_terms_list.deinit(allocator);
    var gain_multiplier: f64 = 1.0;
    if (gain_expr) |gain| {
        var flattened = std.ArrayListUnmanaged(Expr).empty;
        defer flattened.deinit(allocator);
        try collectMulTerms(allocator, gain, &flattened);
        for (flattened.items) |term| {
            switch (term) {
                .number => |value| gain_multiplier *= value,
                else => try gain_terms_list.append(allocator, term),
            }
        }
    }

    return .{
        .matched = true,
        .freq_base = freq_base,
        .freq_scale_terms = freq_scale_terms,
        .freq_multiplier = freq_multiplier,
        .gain_terms = try allocator.dupe(Expr, gain_terms_list.items),
        .gain_multiplier = gain_multiplier,
    };
}

fn collectMulTerms(allocator: std.mem.Allocator, expr: Expr, terms: *std.ArrayListUnmanaged(Expr)) !void {
    switch (expr) {
        .call => |call| {
            if (std.mem.eql(u8, call.name, "mul") and call.args.len == 2) {
                try collectMulTerms(allocator, call.args[0], terms);
                try collectMulTerms(allocator, call.args[1], terms);
                return;
            }
        },
        else => {},
    }
    try terms.append(allocator, expr);
}

fn matchOscillatorBankPattern(allocator: std.mem.Allocator, expr: Expr) !OscillatorBankPattern {
    var gain = GainAccumulator{};
    defer gain.deinit(allocator);

    var patterns = std.ArrayListUnmanaged(OscillatorPattern).empty;
    var matched = false;
    errdefer {
        for (patterns.items) |*pattern| pattern.deinit(allocator);
        patterns.deinit(allocator);
    }

    matched = try flattenOscillatorBankTerms(allocator, expr, &gain, &patterns);
    if (!matched or patterns.items.len < 2) {
        for (patterns.items) |*pattern| pattern.deinit(allocator);
        patterns.deinit(allocator);
        return .{};
    }

    return .{
        .matched = true,
        .patterns = try patterns.toOwnedSlice(allocator),
    };
}

fn flattenOscillatorBankTerms(
    allocator: std.mem.Allocator,
    expr: Expr,
    gain: *GainAccumulator,
    patterns: *std.ArrayListUnmanaged(OscillatorPattern),
) !bool {
    switch (expr) {
        .call => |call| {
            if (std.mem.eql(u8, call.name, "mix")) {
                for (call.args) |arg| {
                    if (!try flattenOscillatorBankTerms(allocator, arg, gain, patterns)) return false;
                }
                return true;
            }
            if (std.mem.eql(u8, call.name, "add") and call.args.len == 2) {
                if (!try flattenOscillatorBankTerms(allocator, call.args[0], gain, patterns)) return false;
                if (!try flattenOscillatorBankTerms(allocator, call.args[1], gain, patterns)) return false;
                return true;
            }
            if (std.mem.eql(u8, call.name, "mul") and call.args.len == 2) {
                if (exprIsStateless(call.args[1])) {
                    const saved_len = gain.dynamic_terms.items.len;
                    const saved_multiplier = gain.multiplier;
                    try appendGainExpr(allocator, gain, call.args[1]);
                    const matched = try flattenOscillatorBankTerms(allocator, call.args[0], gain, patterns);
                    gain.dynamic_terms.items.len = saved_len;
                    gain.multiplier = saved_multiplier;
                    return matched;
                }
                if (exprIsStateless(call.args[0])) {
                    const saved_len = gain.dynamic_terms.items.len;
                    const saved_multiplier = gain.multiplier;
                    try appendGainExpr(allocator, gain, call.args[0]);
                    const matched = try flattenOscillatorBankTerms(allocator, call.args[1], gain, patterns);
                    gain.dynamic_terms.items.len = saved_len;
                    gain.multiplier = saved_multiplier;
                    return matched;
                }
            }
        },
        else => {},
    }

    var pattern = try matchOscillatorPattern(allocator, expr);
    errdefer pattern.deinit(allocator);
    if (!pattern.matched) return false;
    try mergePatternGain(allocator, &pattern, gain);
    try patterns.append(allocator, pattern);
    return true;
}

fn appendGainExpr(allocator: std.mem.Allocator, gain: *GainAccumulator, expr: Expr) !void {
    var terms = std.ArrayListUnmanaged(Expr).empty;
    defer terms.deinit(allocator);
    try collectMulTerms(allocator, expr, &terms);
    for (terms.items) |term| {
        switch (term) {
            .number => |value| gain.multiplier *= value,
            else => try gain.dynamic_terms.append(allocator, term),
        }
    }
}

fn mergePatternGain(
    allocator: std.mem.Allocator,
    pattern: *OscillatorPattern,
    gain: *const GainAccumulator,
) !void {
    if (gain.multiplier != 1.0) pattern.gain_multiplier *= gain.multiplier;
    if (gain.dynamic_terms.items.len == 0) return;

    const merged = try allocator.alloc(Expr, pattern.gain_terms.len + gain.dynamic_terms.items.len);
    @memcpy(merged[0..pattern.gain_terms.len], pattern.gain_terms);
    @memcpy(merged[pattern.gain_terms.len..], gain.dynamic_terms.items);
    allocator.free(pattern.gain_terms);
    pattern.gain_terms = merged;
}

fn exprIsStateless(expr: Expr) bool {
    return switch (expr) {
        .number, .ref_ => true,
        .call => |call| blk: {
            if (std.mem.eql(u8, call.name, "phase") or std.mem.eql(u8, call.name, "adsr") or std.mem.eql(u8, call.name, "lowpass")) {
                break :blk false;
            }
            for (call.args) |arg| {
                if (!exprIsStateless(arg)) break :blk false;
            }
            break :blk true;
        },
    };
}

test "phase outputs wrapping ramp" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const bindings = try allocator.dupe(Binding, &.{
        .{ .name = "out", .expr = exprCall("phase", try allocator.dupe(Expr, &.{exprRef("freq")})) },
    });
    const program = CoreProgram{
        .inputs = try allocator.dupe([]const u8, &.{"freq"}),
        .bindings = bindings,
    };
    const output = try render(allocator, program, &.{&.{ 1.0, 1.0, 1.0, 1.0, 1.0 }}, 5, 4.0);
    defer allocator.free(output);

    try std.testing.expectApproxEqAbs(0.0, output[0], 1e-9);
    try std.testing.expectApproxEqAbs(0.25, output[1], 1e-9);
    try std.testing.expectApproxEqAbs(0.5, output[2], 1e-9);
    try std.testing.expectApproxEqAbs(0.75, output[3], 1e-9);
    try std.testing.expectApproxEqAbs(0.0, output[4], 1e-9);
}

test "sin phase oscillator matches expected quarter cycle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const phase_args = try allocator.dupe(Expr, &.{exprRef("freq")});
    const sin_args = try allocator.dupe(Expr, &.{exprCall("phase", phase_args)});
    const bindings = try allocator.dupe(Binding, &.{
        .{ .name = "out", .expr = exprCall("sin", sin_args) },
    });
    const program = CoreProgram{
        .inputs = try allocator.dupe([]const u8, &.{"freq"}),
        .bindings = bindings,
    };
    const output = try render(allocator, program, &.{&.{ 1.0, 1.0, 1.0, 1.0 }}, 4, 4.0);
    defer allocator.free(output);

    try std.testing.expectApproxEqAbs(0.0, output[0], 1e-9);
    try std.testing.expectApproxEqAbs(1.0, output[1], 1e-9);
    try std.testing.expectApproxEqAbs(0.0, output[2], 1e-9);
    try std.testing.expectApproxEqAbs(-1.0, output[3], 1e-9);
}

test "adsr rises and releases linearly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const env_args = try allocator.dupe(Expr, &.{
        exprRef("gate"),
        exprNumber(0.25),
        exprNumber(0.5),
        exprNumber(0.5),
        exprNumber(0.5),
    });
    const bindings = try allocator.dupe(Binding, &.{
        .{ .name = "env", .expr = exprCall("adsr", env_args) },
        .{ .name = "out", .expr = exprRef("env") },
    });
    const program = CoreProgram{
        .inputs = try allocator.dupe([]const u8, &.{"gate"}),
        .bindings = bindings,
    };
    const output = try render(allocator, program, &.{&.{ 0.0, 1.0, 1.0, 1.0, 0.0, 0.0 }}, 6, 4.0);
    defer allocator.free(output);

    const expected = [_]f64{ 0.0, 1.0, 0.75, 0.5, 0.25, 0.0 };
    for (expected, 0..) |want, index| {
        try std.testing.expectApproxEqAbs(want, output[index], 1e-9);
    }
}

test "constants are hoisted out of the runtime loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const out_args = try allocator.dupe(Expr, &.{ exprNumber(2.0), exprNumber(3.0) });
    const bindings = try allocator.dupe(Binding, &.{
        .{ .name = "out", .expr = exprCall("add", out_args) },
    });
    const program = CoreProgram{
        .inputs = try allocator.dupe([]const u8, &.{}),
        .bindings = bindings,
    };

    var compiled = try compile(allocator, program);
    defer compiled.deinit();

    try std.testing.expectEqual(@as(usize, 1), compiled.const_slots.len);
    try std.testing.expectEqual(@as(usize, 0), compiled.instructions.len);
}

test "oscillator pattern is fused into a single instruction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const mul_freq_args = try allocator.dupe(Expr, &.{ exprRef("freq"), exprNumber(2.0) });
    const phase_args = try allocator.dupe(Expr, &.{exprCall("mul", mul_freq_args)});
    const sin_args = try allocator.dupe(Expr, &.{exprCall("phase", phase_args)});
    const out_args = try allocator.dupe(Expr, &.{ exprCall("sin", sin_args), exprNumber(0.5) });
    const bindings = try allocator.dupe(Binding, &.{
        .{ .name = "out", .expr = exprCall("mul", out_args) },
    });
    const program = CoreProgram{
        .inputs = try allocator.dupe([]const u8, &.{"freq"}),
        .bindings = bindings,
    };

    var compiled = try compile(allocator, program);
    defer compiled.deinit();

    try std.testing.expectEqual(@as(usize, 1), compiled.instructions.len);
    switch (compiled.instructions[0]) {
        .osc => |payload| {
            try std.testing.expectApproxEqAbs(@as(f64, 2.0), payload.freq_multiplier, 1e-12);
            try std.testing.expectApproxEqAbs(@as(f64, 0.5), payload.output_multiplier, 1e-12);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "oscillator mix is fused into an oscillator bank" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const left_args = try allocator.dupe(Expr, &.{exprRef("freq")});
    const right_freq_args = try allocator.dupe(Expr, &.{ exprRef("freq"), exprNumber(2.0) });
    const right_phase_args = try allocator.dupe(Expr, &.{exprCall("mul", right_freq_args)});
    const mix_args = try allocator.dupe(Expr, &.{
        exprCall("sin", try allocator.dupe(Expr, &.{exprCall("phase", left_args)})),
        exprCall("sin", try allocator.dupe(Expr, &.{exprCall("phase", right_phase_args)})),
    });
    const bindings = try allocator.dupe(Binding, &.{
        .{ .name = "out", .expr = exprCall("mix", mix_args) },
    });
    const program = CoreProgram{
        .inputs = try allocator.dupe([]const u8, &.{"freq"}),
        .bindings = bindings,
    };

    var compiled = try compile(allocator, program);
    defer compiled.deinit();

    try std.testing.expectEqual(@as(usize, 1), compiled.instructions.len);
    try std.testing.expectEqual(@as(usize, 2), compiled.osc_bank_terms.len);
    switch (compiled.instructions[0]) {
        .osc_bank => |payload| try std.testing.expectEqual(@as(usize, 2), payload.terms_len),
        else => return error.TestUnexpectedResult,
    }
}

test "unused bindings are eliminated before lowering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const dead_phase_args = try allocator.dupe(Expr, &.{exprRef("freq")});
    const bindings = try allocator.dupe(Binding, &.{
        .{ .name = "dead", .expr = exprCall("phase", dead_phase_args) },
        .{ .name = "out", .expr = exprNumber(0.0) },
    });
    const program = CoreProgram{
        .inputs = try allocator.dupe([]const u8, &.{"freq"}),
        .bindings = bindings,
    };

    var compiled = try compile(allocator, program);
    defer compiled.deinit();

    try std.testing.expectEqual(@as(usize, 0), compiled.instructions.len);
}

test "lowpass with constant cutoff uses specialized instruction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try allocator.dupe(Expr, &.{ exprRef("x"), exprNumber(1000.0) });
    const bindings = try allocator.dupe(Binding, &.{
        .{ .name = "out", .expr = exprCall("lowpass", args) },
    });
    const program = CoreProgram{
        .inputs = try allocator.dupe([]const u8, &.{"x"}),
        .bindings = bindings,
    };

    var compiled = try compile(allocator, program);
    defer compiled.deinit();

    try std.testing.expectEqual(@as(usize, 1), compiled.instructions.len);
    switch (compiled.instructions[0]) {
        .lowpass_const => |payload| try std.testing.expectApproxEqAbs(@as(f64, 1000.0), payload.cutoff, 1e-12),
        else => return error.TestUnexpectedResult,
    }
}

test "runtime rejects non-positive sample rate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const bindings = try allocator.dupe(Binding, &.{
        .{ .name = "out", .expr = exprNumber(0.0) },
    });
    const program = CoreProgram{
        .inputs = try allocator.dupe([]const u8, &.{}),
        .bindings = bindings,
    };

    try std.testing.expectError(error.InvalidSampleRate, render(allocator, program, &.{}, 1, 0.0));
}
