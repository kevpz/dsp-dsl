const std = @import("std");
const core = @import("lib.zig");
const surface = @import("surface.zig");

const c = @cImport({
    @cInclude("alsa/asoundlib.h");
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xutil.h");
    @cInclude("X11/keysym.h");
});

pub const REALTIME_SAMPLE_RATE: u32 = 48_000;
pub const REALTIME_FRAMES_PER_BUFFER: usize = 256;
pub const REALTIME_PERIOD_CANDIDATES = [_]usize{ 128, 256, 64 };
pub const REALTIME_BASE_OCTAVE: i32 = 4;
const MIN_BASE_OCTAVE: i32 = 0;
const MAX_BASE_OCTAVE: i32 = 8;
const WINDOW_WIDTH: c_uint = 560;
const WINDOW_HEIGHT: c_uint = 120;
const DISPLAY_POLL_TIMEOUT_MS: i32 = 20;
const ALSA_BUFFER_PERIODS: usize = 4;
const ALSA_MIN_BUFFER_PERIODS: usize = 2;

pub const MappedKey = union(enum) {
    none,
    escape,
    octave_down,
    octave_up,
    note: u8,
};

pub const Snapshot = struct {
    note: f64,
    gate: f64,
};

pub const KeyboardController = struct {
    mutex: std.Thread.Mutex = .{},
    base_octave: i32,
    active_key: ?u8 = null,
    note: f64,
    gate: f64 = 0.0,

    pub fn init(base_octave: i32) KeyboardController {
        const clamped = clampInt(base_octave, MIN_BASE_OCTAVE, MAX_BASE_OCTAVE);
        return .{
            .base_octave = clamped,
            .note = @as(f64, @floatFromInt(midiNote(clamped, 0))),
        };
    }

    pub fn getBaseOctave(self: *KeyboardController) i32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.base_octave;
    }

    pub fn snapshot(self: *KeyboardController) Snapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .note = self.note,
            .gate = self.gate,
        };
    }

    pub fn handleKeyPress(self: *KeyboardController, key: MappedKey) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        switch (key) {
            .octave_down => {
                self.base_octave = @max(MIN_BASE_OCTAVE, self.base_octave - 1);
                return true;
            },
            .octave_up => {
                self.base_octave = @min(MAX_BASE_OCTAVE, self.base_octave + 1);
                return true;
            },
            .note => |note_key| {
                const offset = noteOffset(note_key) orelse return false;
                if (self.active_key == note_key and self.gate > 0.0) return true;
                self.active_key = note_key;
                self.note = @as(f64, @floatFromInt(midiNote(self.base_octave, offset)));
                self.gate = 1.0;
                return true;
            },
            else => return false,
        }
    }

    pub fn handleKeyRelease(self: *KeyboardController, key: MappedKey) bool {
        const note_key = switch (key) {
            .note => |value| value,
            else => return false,
        };
        if (noteOffset(note_key) == null) return false;

        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.active_key == note_key) {
            self.active_key = null;
            self.gate = 0.0;
        }
        return true;
    }

    pub fn clearGate(self: *KeyboardController) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.active_key = null;
        self.gate = 0.0;
    }
};

pub const RealtimePlayer = struct {
    allocator: std.mem.Allocator,
    compiled: *const core.CompiledProgram,
    controller: *KeyboardController,
    runtime: core.Runtime,
    input_values: []f64,
    note_input_index: usize,
    gate_input_index: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        compiled: *const core.CompiledProgram,
        controller: *KeyboardController,
        sample_rate: u32,
    ) !RealtimePlayer {
        try validateRealtimeProgram(compiled);
        if (sample_rate != REALTIME_SAMPLE_RATE) return error.InvalidSampleRate;

        const runtime = try compiled.makeRuntime(allocator, @as(f64, @floatFromInt(sample_rate)));
        const input_values = try allocator.alloc(f64, compiled.input_names.len);
        @memset(input_values, 0.0);

        return .{
            .allocator = allocator,
            .compiled = compiled,
            .controller = controller,
            .runtime = runtime,
            .input_values = input_values,
            .note_input_index = findInputIndex(compiled, "note") orelse return error.InvalidRealtimeProgram,
            .gate_input_index = findInputIndex(compiled, "gate") orelse return error.InvalidRealtimeProgram,
        };
    }

    pub fn deinit(self: *RealtimePlayer) void {
        self.runtime.deinit();
        self.allocator.free(self.input_values);
    }

    pub fn renderBuffer(self: *RealtimePlayer, output: []f32) !void {
        const snapshot = self.controller.snapshot();
        self.input_values[self.note_input_index] = snapshot.note;
        self.input_values[self.gate_input_index] = snapshot.gate;

        for (output) |*sample| {
            sample.* = sanitizeAudioSample(try self.runtime.step(self.input_values));
        }
    }
};

pub fn validateRealtimeProgram(compiled: *const core.CompiledProgram) !void {
    if (compiled.input_names.len != 2) return error.InvalidRealtimeProgram;
    const has_note = findInputIndex(compiled, "note") != null;
    const has_gate = findInputIndex(compiled, "gate") != null;
    if (!(has_note and has_gate)) return error.InvalidRealtimeProgram;
}

pub fn playProgram(
    allocator: std.mem.Allocator,
    compiled: *const core.CompiledProgram,
) !void {
    var controller = KeyboardController.init(REALTIME_BASE_OCTAVE);
    var player = try RealtimePlayer.init(
        allocator,
        compiled,
        &controller,
        REALTIME_SAMPLE_RATE,
    );
    defer player.deinit();

    try runSession(&controller, &player);
}

const AudioThreadContext = struct {
    running: *std.atomic.Value(bool),
    failed: *std.atomic.Value(bool),
    player: *RealtimePlayer,
};

const NegotiatedAudioConfig = struct {
    frames_per_buffer: usize,
    buffer_frames: usize,
};

const OpenedPlayback = struct {
    pcm: *c.snd_pcm_t,
    config: NegotiatedAudioConfig,
};

fn runSession(controller: *KeyboardController, player: *RealtimePlayer) !void {
    const display = c.XOpenDisplay(null) orelse return error.DisplayUnavailable;
    defer _ = c.XCloseDisplay(display);

    const screen = c.XDefaultScreen(display);
    const root = c.XRootWindow(display, screen);
    const black = c.XBlackPixel(display, screen);
    const white = c.XWhitePixel(display, screen);

    const window = c.XCreateSimpleWindow(
        display,
        root,
        120,
        120,
        WINDOW_WIDTH,
        WINDOW_HEIGHT,
        1,
        black,
        white,
    );
    if (window == 0) return error.WindowCreationFailed;
    defer _ = c.XDestroyWindow(display, window);

    _ = c.XSelectInput(
        display,
        window,
        @as(c_long, c.ExposureMask | c.KeyPressMask | c.KeyReleaseMask | c.FocusChangeMask | c.StructureNotifyMask),
    );

    var title_buffer: [128]u8 = undefined;
    try updateWindowTitle(display, window, controller.getBaseOctave(), &title_buffer);

    var delete_atom = c.XInternAtom(display, "WM_DELETE_WINDOW", c.False);
    _ = c.XSetWMProtocols(display, window, &delete_atom, 1);
    _ = c.XMapRaised(display, window);
    _ = c.XFlush(display);

    printKeyboardHelp(controller.getBaseOctave());

    var running = std.atomic.Value(bool).init(true);
    var failed = std.atomic.Value(bool).init(false);
    var audio_ctx = AudioThreadContext{
        .running = &running,
        .failed = &failed,
        .player = player,
    };
    const audio_thread = try std.Thread.spawn(.{}, audioThreadMain, .{&audio_ctx});
    defer audio_thread.join();

    while (running.load(.seq_cst)) {
        while (c.XPending(display) > 0) {
            var event: c.XEvent = undefined;
            _ = c.XNextEvent(display, &event);
            switch (event.type) {
                c.KeyPress => {
                    const mapped = decodeKeyEvent(&event.xkey);
                    if (mapped == .escape) {
                        controller.clearGate();
                        running.store(false, .seq_cst);
                        break;
                    }
                    const updated_octave = mapped == .octave_down or mapped == .octave_up;
                    if (controller.handleKeyPress(mapped) and updated_octave) {
                        try updateWindowTitle(display, window, controller.getBaseOctave(), &title_buffer);
                    }
                },
                c.KeyRelease => {
                    if (isAutoRepeat(display, &event.xkey)) continue;
                    _ = controller.handleKeyRelease(decodeKeyEvent(&event.xkey));
                },
                c.FocusOut => controller.clearGate(),
                c.ClientMessage => {
                    if (@as(c_ulong, @intCast(event.xclient.data.l[0])) == delete_atom) {
                        controller.clearGate();
                        running.store(false, .seq_cst);
                        break;
                    }
                },
                c.DestroyNotify => {
                    controller.clearGate();
                    running.store(false, .seq_cst);
                    break;
                },
                else => {},
            }
        }
        try waitForDisplayActivity(display);
    }

    controller.clearGate();
    if (failed.load(.seq_cst)) return error.RealtimeAudioFailed;
}

fn audioThreadMain(ctx: *AudioThreadContext) void {
    const opened = openConfiguredPlaybackPcm() catch |err| {
        std.log.err("failed to configure ALSA playback: {}", .{err});
        ctx.failed.store(true, .seq_cst);
        ctx.running.store(false, .seq_cst);
        return;
    };
    const pcm = opened.pcm;
    defer _ = c.snd_pcm_close(pcm);

    std.log.info(
        "realtime audio: {d} Hz, {d}-frame period, {d}-frame buffer",
        .{ REALTIME_SAMPLE_RATE, opened.config.frames_per_buffer, opened.config.buffer_frames },
    );

    const buffer = ctx.player.allocator.alloc(f32, opened.config.frames_per_buffer) catch |err| {
        std.log.err("failed to allocate realtime buffer: {}", .{err});
        ctx.failed.store(true, .seq_cst);
        ctx.running.store(false, .seq_cst);
        return;
    };
    defer ctx.player.allocator.free(buffer);
    while (ctx.running.load(.seq_cst)) {
        ctx.player.renderBuffer(buffer) catch |err| {
            std.log.err("realtime render failed: {}", .{err});
            ctx.failed.store(true, .seq_cst);
            ctx.running.store(false, .seq_cst);
            return;
        };

        var offset: usize = 0;
        while (offset < buffer.len and ctx.running.load(.seq_cst)) {
            const remaining = buffer.len - offset;
            const written = c.snd_pcm_writei(
                pcm,
                @ptrCast(buffer[offset..].ptr),
                @as(c_ulong, @intCast(remaining)),
            );
            if (written < 0) {
                const recovered = c.snd_pcm_recover(pcm, @as(c_int, @intCast(written)), 1);
                if (recovered < 0) {
                    logAlsaError("ALSA playback write failed", recovered);
                    ctx.failed.store(true, .seq_cst);
                    ctx.running.store(false, .seq_cst);
                    return;
                }
                continue;
            }
            offset += @as(usize, @intCast(written));
        }
    }

    _ = c.snd_pcm_drop(pcm);
}

fn openConfiguredPlaybackPcm() !OpenedPlayback {
    const open_flags: c_int = c.SND_PCM_NO_AUTO_RESAMPLE | c.SND_PCM_NO_AUTO_CHANNELS | c.SND_PCM_NO_AUTO_FORMAT;
    for (REALTIME_PERIOD_CANDIDATES) |frames_per_buffer| {
        var pcm_opt: ?*c.snd_pcm_t = null;
        if (c.snd_pcm_open(&pcm_opt, "default", c.SND_PCM_STREAM_PLAYBACK, open_flags) < 0) {
            return error.AudioDeviceUnavailable;
        }
        const pcm = pcm_opt.?;
        errdefer _ = c.snd_pcm_close(pcm);

        if (try tryConfigurePlaybackPcm(pcm, frames_per_buffer)) |config| {
            return .{ .pcm = pcm, .config = config };
        }

        _ = c.snd_pcm_close(pcm);
    }
    return error.UnsupportedAudioConfig;
}

fn tryConfigurePlaybackPcm(pcm: *c.snd_pcm_t, frames_per_buffer: usize) !?NegotiatedAudioConfig {
    var hw_params: ?*c.snd_pcm_hw_params_t = null;
    if (c.snd_pcm_hw_params_malloc(&hw_params) < 0) return error.OutOfMemory;
    defer c.snd_pcm_hw_params_free(hw_params);

    var sw_params: ?*c.snd_pcm_sw_params_t = null;
    if (c.snd_pcm_sw_params_malloc(&sw_params) < 0) return error.OutOfMemory;
    defer c.snd_pcm_sw_params_free(sw_params);

    if (c.snd_pcm_hw_params_any(pcm, hw_params) < 0) return null;
    if (c.snd_pcm_hw_params_set_access(pcm, hw_params, c.SND_PCM_ACCESS_RW_INTERLEAVED) < 0) return null;
    if (c.snd_pcm_hw_params_set_format(pcm, hw_params, c.SND_PCM_FORMAT_FLOAT_LE) < 0) return null;
    if (c.snd_pcm_hw_params_set_channels(pcm, hw_params, 1) < 0) return null;
    if (c.snd_pcm_hw_params_set_rate_resample(pcm, hw_params, 0) < 0) return null;

    var rate: c_uint = REALTIME_SAMPLE_RATE;
    var rate_dir: c_int = 0;
    if (c.snd_pcm_hw_params_set_rate_near(pcm, hw_params, &rate, &rate_dir) < 0) return null;

    var period_size: c.snd_pcm_uframes_t = @intCast(frames_per_buffer);
    var period_dir: c_int = 0;
    if (c.snd_pcm_hw_params_set_period_size_near(pcm, hw_params, &period_size, &period_dir) < 0) return null;

    var buffer_size: c.snd_pcm_uframes_t = @intCast(frames_per_buffer * ALSA_BUFFER_PERIODS);
    if (c.snd_pcm_hw_params_set_buffer_size_near(pcm, hw_params, &buffer_size) < 0) return null;
    if (c.snd_pcm_hw_params(pcm, hw_params) < 0) return null;

    var actual_rate: c_uint = 0;
    var actual_rate_dir: c_int = 0;
    if (c.snd_pcm_hw_params_get_rate(hw_params, &actual_rate, &actual_rate_dir) < 0) return null;

    var actual_period_size: c.snd_pcm_uframes_t = 0;
    var actual_period_dir: c_int = 0;
    if (c.snd_pcm_hw_params_get_period_size(hw_params, &actual_period_size, &actual_period_dir) < 0) return null;

    var actual_buffer_size: c.snd_pcm_uframes_t = 0;
    if (c.snd_pcm_hw_params_get_buffer_size(hw_params, &actual_buffer_size) < 0) return null;

    if (actual_rate != REALTIME_SAMPLE_RATE) return null;
    if (actual_period_size != frames_per_buffer) return null;
    if (actual_buffer_size < actual_period_size * ALSA_MIN_BUFFER_PERIODS) return null;

    if (c.snd_pcm_sw_params_current(pcm, sw_params) < 0) return null;
    if (c.snd_pcm_sw_params_set_avail_min(pcm, sw_params, actual_period_size) < 0) return null;
    if (c.snd_pcm_sw_params_set_start_threshold(pcm, sw_params, actual_period_size) < 0) return null;
    if (c.snd_pcm_sw_params_set_stop_threshold(pcm, sw_params, actual_buffer_size) < 0) return null;
    if (c.snd_pcm_sw_params(pcm, sw_params) < 0) return null;
    if (c.snd_pcm_prepare(pcm) < 0) return null;

    return .{
        .frames_per_buffer = @intCast(actual_period_size),
        .buffer_frames = @intCast(actual_buffer_size),
    };
}

fn waitForDisplayActivity(display: *c.Display) !void {
    const display_fd = c.XConnectionNumber(display);
    var poll_fds = [_]std.posix.pollfd{
        .{
            .fd = display_fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
    };
    _ = try std.posix.poll(poll_fds[0..], DISPLAY_POLL_TIMEOUT_MS);
}

fn printKeyboardHelp(base_octave: i32) void {
    std.debug.print(
        \\DSP DSL realtime player at 48kHz.
        \\Focus the player window and use the computer keyboard.
        \\Base octave: {}
        \\Lower row: z s x d c v g b h n j m
        \\Upper row: q 2 w 3 e r 5 t 6 y 7 u
        \\[ / ]: octave down/up
        \\Esc: stop
        \\
    , .{base_octave});
}

fn updateWindowTitle(
    display: *c.Display,
    window: c.Window,
    base_octave: i32,
    buffer: []u8,
) !void {
    const title = try std.fmt.bufPrintZ(
        buffer,
        "DSP DSL Player - Base octave: {} - [ ] to shift, Esc to stop",
        .{base_octave},
    );
    _ = c.XStoreName(display, window, title.ptr);
    _ = c.XFlush(display);
}

fn logAlsaError(prefix: []const u8, status: c_int) void {
    const message = std.mem.span(c.snd_strerror(status));
    std.log.err("{s}: {s}", .{ prefix, message });
}

fn decodeKeyEvent(event: *c.XKeyEvent) MappedKey {
    var event_copy = event.*;
    var buffer: [8]u8 = undefined;
    var keysym: c.KeySym = 0;
    const count = c.XLookupString(
        &event_copy,
        @ptrCast(&buffer),
        @as(c_int, @intCast(buffer.len)),
        &keysym,
        null,
    );

    if (keysym == c.XK_Escape) return .escape;
    if (keysym == c.XK_bracketleft) return .octave_down;
    if (keysym == c.XK_bracketright) return .octave_up;
    if (count <= 0) return .none;

    var key = buffer[0];
    if (key >= 'A' and key <= 'Z') key += 'a' - 'A';
    if (noteOffset(key) != null) return .{ .note = key };
    return .none;
}

fn isAutoRepeat(display: *c.Display, release_event: *const c.XKeyEvent) bool {
    if (c.XPending(display) == 0) return false;
    var next_event: c.XEvent = undefined;
    _ = c.XPeekEvent(display, &next_event);
    return next_event.type == c.KeyPress and
        next_event.xkey.keycode == release_event.keycode and
        next_event.xkey.time == release_event.time;
}

fn noteOffset(key: u8) ?i32 {
    return switch (key) {
        'z' => 0,
        's' => 1,
        'x' => 2,
        'd' => 3,
        'c' => 4,
        'v' => 5,
        'g' => 6,
        'b' => 7,
        'h' => 8,
        'n' => 9,
        'j' => 10,
        'm' => 11,
        'q' => 12,
        '2' => 13,
        'w' => 14,
        '3' => 15,
        'e' => 16,
        'r' => 17,
        '5' => 18,
        't' => 19,
        '6' => 20,
        'y' => 21,
        '7' => 22,
        'u' => 23,
        else => null,
    };
}

fn midiNote(base_octave: i32, offset: i32) i32 {
    const midi = 12 * (base_octave + 1) + offset;
    return clampInt(midi, 0, 127);
}

fn findInputIndex(compiled: *const core.CompiledProgram, name: []const u8) ?usize {
    for (compiled.input_names, 0..) |input_name, index| {
        if (std.mem.eql(u8, input_name, name)) return index;
    }
    return null;
}

fn sanitizeAudioSample(sample: f64) f32 {
    if (!std.math.isFinite(sample)) return 0.0;
    return @as(f32, @floatCast(std.math.clamp(sample, -1.0, 1.0)));
}

fn clampInt(value: i32, lower: i32, upper: i32) i32 {
    return @min(@max(value, lower), upper);
}

test "realtime contract accepts note and gate only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\input gate
        \\input note
        \\out = gate
    ;
    const outcome = try surface.parse(allocator, source);
    const program = outcome.program.?;
    var compiled = try surface.compile(allocator, program);
    defer compiled.deinit();

    try validateRealtimeProgram(&compiled);
}

test "realtime period candidates prefer 128 frame default" {
    try std.testing.expectEqualSlices(usize, &.{ 128, 256, 64 }, &REALTIME_PERIOD_CANDIDATES);
}

test "realtime contract rejects other inputs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\input note
        \\input gate
        \\input velocity
        \\out = gate
    ;
    const outcome = try surface.parse(allocator, source);
    const program = outcome.program.?;
    var compiled = try surface.compile(allocator, program);
    defer compiled.deinit();

    try std.testing.expectError(error.InvalidRealtimeProgram, validateRealtimeProgram(&compiled));
}

test "keyboard controller press and release sets note and gate" {
    var controller = KeyboardController.init(REALTIME_BASE_OCTAVE);

    try std.testing.expect(controller.handleKeyPress(.{ .note = 'z' }));
    const pressed = controller.snapshot();
    try std.testing.expectEqual(@as(f64, 60.0), pressed.note);
    try std.testing.expectEqual(@as(f64, 1.0), pressed.gate);

    try std.testing.expect(controller.handleKeyRelease(.{ .note = 'z' }));
    const released = controller.snapshot();
    try std.testing.expectEqual(@as(f64, 60.0), released.note);
    try std.testing.expectEqual(@as(f64, 0.0), released.gate);
}

test "keyboard controller ignores non active release" {
    var controller = KeyboardController.init(REALTIME_BASE_OCTAVE);

    _ = controller.handleKeyPress(.{ .note = 'z' });
    _ = controller.handleKeyPress(.{ .note = 'x' });
    _ = controller.handleKeyRelease(.{ .note = 'z' });
    const held = controller.snapshot();
    try std.testing.expectEqual(@as(f64, 62.0), held.note);
    try std.testing.expectEqual(@as(f64, 1.0), held.gate);

    _ = controller.handleKeyRelease(.{ .note = 'x' });
    const released = controller.snapshot();
    try std.testing.expectEqual(@as(f64, 62.0), released.note);
    try std.testing.expectEqual(@as(f64, 0.0), released.gate);
}

test "keyboard controller octave shift affects future notes only" {
    var controller = KeyboardController.init(REALTIME_BASE_OCTAVE);

    _ = controller.handleKeyPress(.{ .note = 'z' });
    _ = controller.handleKeyPress(.octave_up);
    const held = controller.snapshot();
    try std.testing.expectEqual(@as(f64, 60.0), held.note);
    try std.testing.expectEqual(@as(f64, 1.0), held.gate);

    _ = controller.handleKeyRelease(.{ .note = 'z' });
    _ = controller.handleKeyPress(.{ .note = 'z' });
    const shifted = controller.snapshot();
    try std.testing.expectEqual(@as(f64, 72.0), shifted.note);
    try std.testing.expectEqual(@as(f64, 1.0), shifted.gate);
}

test "clear gate preserves last note" {
    var controller = KeyboardController.init(REALTIME_BASE_OCTAVE);

    _ = controller.handleKeyPress(.{ .note = 'x' });
    controller.clearGate();
    const snapshot = controller.snapshot();
    try std.testing.expectEqual(@as(f64, 62.0), snapshot.note);
    try std.testing.expectEqual(@as(f64, 0.0), snapshot.gate);
}

test "render buffer clips output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\input note
        \\input gate
        \\out = mul(2, gate)
    ;
    const outcome = try surface.parse(allocator, source);
    const program = outcome.program.?;
    var compiled = try surface.compile(allocator, program);
    defer compiled.deinit();
    var controller = KeyboardController.init(REALTIME_BASE_OCTAVE);
    _ = controller.handleKeyPress(.{ .note = 'z' });
    var player = try RealtimePlayer.init(allocator, &compiled, &controller, REALTIME_SAMPLE_RATE);
    defer player.deinit();

    var samples: [4]f32 = undefined;
    try player.renderBuffer(samples[0..]);
    for (samples) |sample| {
        try std.testing.expectEqual(@as(f32, 1.0), sample);
    }
}

test "render buffer sanitizes non finite output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\input note
        \\input gate
        \\out = mul(1e308, 1e308)
    ;
    const outcome = try surface.parse(allocator, source);
    const program = outcome.program.?;
    var compiled = try surface.compile(allocator, program);
    defer compiled.deinit();
    var controller = KeyboardController.init(REALTIME_BASE_OCTAVE);
    _ = controller.handleKeyPress(.{ .note = 'z' });
    var player = try RealtimePlayer.init(allocator, &compiled, &controller, REALTIME_SAMPLE_RATE);
    defer player.deinit();

    var samples: [3]f32 = undefined;
    try player.renderBuffer(samples[0..]);
    for (samples) |sample| {
        try std.testing.expectEqual(@as(f32, 0.0), sample);
    }
}

test "realtime player requires 48khz" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\input note
        \\input gate
        \\out = gate
    ;
    const outcome = try surface.parse(allocator, source);
    const program = outcome.program.?;
    var compiled = try surface.compile(allocator, program);
    defer compiled.deinit();
    var controller = KeyboardController.init(REALTIME_BASE_OCTAVE);

    try std.testing.expectError(
        error.InvalidSampleRate,
        RealtimePlayer.init(allocator, &compiled, &controller, 44_100),
    );
}
