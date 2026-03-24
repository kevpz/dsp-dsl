const std = @import("std");
const core = @import("lib.zig");

pub const Diagnostic = struct {
    line: usize,
    message: []const u8,
};

pub const ParseOutcome = struct {
    program: ?Program,
    diagnostic: ?Diagnostic,
};

pub const Program = struct {
    functions: []const FunctionDef,
    inputs: []const []const u8,
    bindings: []const ParsedBinding,
    source_storage: ?[]u8 = null,

    pub fn deinit(self: *Program, allocator: std.mem.Allocator) void {
        for (self.functions) |function| {
            function.expr.deinit(allocator, false);
            allocator.free(function.params);
        }
        for (self.bindings) |binding| {
            binding.expr.deinit(allocator, false);
        }
        allocator.free(self.functions);
        allocator.free(self.inputs);
        allocator.free(self.bindings);
        if (self.source_storage) |storage| allocator.free(storage);
    }
};

pub const FunctionDef = struct {
    name: []const u8,
    params: []const []const u8,
    expr: core.Expr,
    line: usize,
};

pub const ParsedBinding = struct {
    name: []const u8,
    expr: core.Expr,
    line: usize,
};

const TokenKind = enum { number, ident, symbol };

const Token = struct {
    kind: TokenKind,
    lexeme: []const u8,
};

const KEYWORDS = [_][]const u8{ "input", "out" };
const BUILTIN_NAMES = [_][]const u8{
    "add",
    "sub",
    "mul",
    "mix",
    "mtof",
    "phase",
    "sin",
    "adsr",
    "lowpass",
};
const PRELUDE_NAMES = [_][]const u8{
    "mod",
    "lerp",
    "pos",
    "range",
};
const VisitMark = enum { visiting, visited };

pub fn parse(allocator: std.mem.Allocator, source: []const u8) !ParseOutcome {
    const owned_source = try allocator.dupe(u8, source);
    var parsed_ok = false;
    defer {
        if (!parsed_ok) allocator.free(owned_source);
    }

    var functions: std.ArrayListUnmanaged(FunctionDef) = .empty;
    defer {
        if (!parsed_ok) {
            deinitFunctionList(functions.items, allocator);
            functions.deinit(allocator);
        }
    }
    var inputs: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        if (!parsed_ok) inputs.deinit(allocator);
    }
    var bindings: std.ArrayListUnmanaged(ParsedBinding) = .empty;
    defer {
        if (!parsed_ok) {
            deinitBindingList(bindings.items, allocator);
            bindings.deinit(allocator);
        }
    }

    var line_iter = std.mem.splitScalar(u8, owned_source, '\n');
    var line_no: usize = 0;
    var seen_binding = false;

    while (line_iter.next()) |raw_line| {
        line_no += 1;
        const line = stripSourceLine(raw_line);
        if (line.len == 0) continue;

        if (startsWithKeyword(line, "input")) {
            if (seen_binding) {
                return .{ .program = null, .diagnostic = .{ .line = line_no, .message = "inputs must appear before bindings" } };
            }
            const input_name = parseInputLine(line) orelse {
                return .{ .program = null, .diagnostic = .{ .line = line_no, .message = "invalid input declaration" } };
            };
            try inputs.append(allocator, input_name);
            continue;
        }

        const assignment = try parseAssignmentLine(allocator, line, line_no);
        switch (assignment) {
            .binding => |binding| {
                seen_binding = true;
                try bindings.append(allocator, binding);
            },
            .function => |function| {
                try functions.append(allocator, function);
            },
            .diagnostic => |diagnostic| return .{ .program = null, .diagnostic = diagnostic },
        }
    }

    const owned_functions = try functions.toOwnedSlice(allocator);
    const owned_inputs = try inputs.toOwnedSlice(allocator);
    const owned_bindings = try bindings.toOwnedSlice(allocator);
    parsed_ok = true;
    return .{
        .program = .{
            .functions = owned_functions,
            .inputs = owned_inputs,
            .bindings = owned_bindings,
            .source_storage = owned_source,
        },
        .diagnostic = null,
    };
}

pub fn validate(allocator: std.mem.Allocator, program: Program) !?Diagnostic {
    return validateWithAllocator(allocator, program);
}

fn validateWithAllocator(allocator: std.mem.Allocator, program: Program) !?Diagnostic {
    if (program.bindings.len == 0) {
        return .{ .line = 0, .message = "program must contain at least one binding" };
    }

    var function_defs = std.StringHashMap(FunctionDef).init(allocator);
    defer function_defs.deinit();
    var seen_functions = std.StringHashMap(void).init(allocator);
    defer seen_functions.deinit();
    for (program.functions) |function| {
        if (isKeyword(function.name)) return .{ .line = function.line, .message = "function name is reserved" };
        if (isBuiltin(function.name)) return .{ .line = function.line, .message = "function shadows a builtin" };
        if (isPrelude(function.name)) return .{ .line = function.line, .message = "function shadows a prelude function" };
        if (seen_functions.contains(function.name)) return .{ .line = function.line, .message = "duplicate function" };
        try seen_functions.put(function.name, {});
        try function_defs.put(function.name, function);
    }

    for (program.inputs) |name| {
        if (std.mem.eql(u8, name, "out")) return .{ .line = 0, .message = "input name 'out' is reserved for the final binding" };
        if (isKeyword(name)) return .{ .line = 0, .message = "input uses reserved keyword" };
        if (isBuiltin(name)) return .{ .line = 0, .message = "input shadows a builtin" };
        if (isPrelude(name)) return .{ .line = 0, .message = "input shadows a prelude function" };
        if (seen_functions.contains(name)) return .{ .line = 0, .message = "input duplicates a function" };
    }

    var defined = std.StringHashMap(void).init(allocator);
    defer defined.deinit();
    var seen_inputs = std.StringHashMap(void).init(allocator);
    defer seen_inputs.deinit();
    for (program.inputs) |name| {
        if (seen_inputs.contains(name)) return .{ .line = 0, .message = "duplicate input" };
        try seen_inputs.put(name, {});
        try defined.put(name, {});
    }

    var out_index: ?usize = null;
    var seen_bindings = std.StringHashMap(void).init(allocator);
    defer seen_bindings.deinit();
    for (program.bindings, 0..) |binding, index| {
        if (isBuiltin(binding.name)) return .{ .line = binding.line, .message = "binding shadows a builtin" };
        if (!std.mem.eql(u8, binding.name, "out") and isKeyword(binding.name)) {
            return .{ .line = binding.line, .message = "binding name is reserved" };
        }
        if (isPrelude(binding.name)) return .{ .line = binding.line, .message = "binding shadows a prelude function" };
        if (seen_functions.contains(binding.name)) return .{ .line = binding.line, .message = "binding duplicates a function" };
        if (seen_inputs.contains(binding.name)) return .{ .line = binding.line, .message = "binding duplicates an input" };
        if (seen_bindings.contains(binding.name)) return .{ .line = binding.line, .message = "duplicate binding" };
        if (std.mem.eql(u8, binding.name, "out")) {
            if (out_index != null) return .{ .line = binding.line, .message = "program may define 'out' only once" };
            out_index = index;
        }
        if (validateExpr(binding.expr, &defined, &function_defs)) |diag_msg| {
            return .{ .line = binding.line, .message = diag_msg };
        }
        try seen_bindings.put(binding.name, {});
        try defined.put(binding.name, {});
    }

    if (out_index == null) return .{ .line = 0, .message = "program must define 'out'" };
    if (out_index.? != program.bindings.len - 1) return .{ .line = 0, .message = "'out' must be the final binding" };

    for (program.functions) |function| {
        var function_scope = std.StringHashMap(void).init(allocator);
        defer function_scope.deinit();
        var seen_params = std.StringHashMap(void).init(allocator);
        defer seen_params.deinit();
        for (function.params) |param| {
            if (isKeyword(param)) return .{ .line = function.line, .message = "parameter is reserved" };
            if (isBuiltin(param)) return .{ .line = function.line, .message = "parameter shadows a builtin" };
            if (isPrelude(param)) return .{ .line = function.line, .message = "parameter shadows a prelude function" };
            if (seen_functions.contains(param)) return .{ .line = function.line, .message = "parameter duplicates a function" };
            if (seen_params.contains(param)) return .{ .line = function.line, .message = "duplicate parameter" };
            try seen_params.put(param, {});
            try function_scope.put(param, {});
        }
        if (validateExpr(function.expr, &function_scope, &function_defs)) |diag_msg| {
            return .{ .line = function.line, .message = diag_msg };
        }
    }

    if (try findFunctionCycle(allocator, program, &function_defs)) |diagnostic| {
        return diagnostic;
    }

    return null;
}

pub fn normalize(allocator: std.mem.Allocator, program: Program) !core.CoreProgram {
    if (try validateWithAllocator(allocator, program)) |diagnostic| {
        _ = diagnostic;
        return error.InvalidProgram;
    }

    var inputs = std.ArrayListUnmanaged([]const u8).empty;
    errdefer {
        for (inputs.items) |name| allocator.free(name);
        inputs.deinit(allocator);
    }
    for (program.inputs) |name| {
        try inputs.append(allocator, try allocator.dupe(u8, name));
    }

    var bindings: std.ArrayListUnmanaged(core.Binding) = .empty;
    errdefer {
        for (bindings.items) |binding| {
            binding.expr.deinit(allocator, true);
            allocator.free(binding.name);
        }
        bindings.deinit(allocator);
    }

    var function_defs = std.StringHashMap(FunctionDef).init(allocator);
    defer function_defs.deinit();
    for (program.functions) |function| {
        try function_defs.put(function.name, function);
    }

    var empty_env = std.StringHashMap(core.Expr).init(allocator);
    defer empty_env.deinit();

    for (program.bindings) |binding| {
        try bindings.append(allocator, .{
            .name = try allocator.dupe(u8, binding.name),
            .expr = try normalizeExpr(allocator, binding.expr, &empty_env, &function_defs),
        });
    }

    return .{
        .inputs = try inputs.toOwnedSlice(allocator),
        .bindings = try bindings.toOwnedSlice(allocator),
        .owned_names = true,
    };
}

pub fn compile(allocator: std.mem.Allocator, program: Program) !core.CompiledProgram {
    const normalized = try normalize(allocator, program);
    defer normalized.deinit(allocator);
    return core.compile(allocator, normalized);
}

pub fn render(
    allocator: std.mem.Allocator,
    program: Program,
    inputs: []const []const f64,
    frames: usize,
    sample_rate: f64,
) ![]f64 {
    const normalized = try normalize(allocator, program);
    defer normalized.deinit(allocator);
    return core.render(allocator, normalized, inputs, frames, sample_rate);
}

pub fn loadProgramFromFile(allocator: std.mem.Allocator, path: []const u8) !Program {
    const source = try std.fs.cwd().readFileAlloc(allocator, path, 1 << 20);
    defer allocator.free(source);
    const outcome = try parse(allocator, source);
    if (outcome.diagnostic != null) return error.ParseFailed;
    return outcome.program.?;
}

const AssignmentOutcome = union(enum) {
    binding: ParsedBinding,
    function: FunctionDef,
    diagnostic: Diagnostic,
};

fn deinitFunctionList(functions: []const FunctionDef, allocator: std.mem.Allocator) void {
    for (functions) |function| {
        function.expr.deinit(allocator, false);
        allocator.free(function.params);
    }
}

fn deinitBindingList(bindings: []const ParsedBinding, allocator: std.mem.Allocator) void {
    for (bindings) |binding| {
        binding.expr.deinit(allocator, false);
    }
}

fn parseInputLine(line: []const u8) ?[]const u8 {
    var iter = std.mem.tokenizeAny(u8, line, " \t\r");
    const keyword = iter.next() orelse return null;
    const name = iter.next() orelse return null;
    if (!std.mem.eql(u8, keyword, "input")) return null;
    if (iter.next() != null) return null;
    if (!isIdent(name)) return null;
    return name;
}

fn parseAssignmentLine(allocator: std.mem.Allocator, line: []const u8, line_no: usize) !AssignmentOutcome {
    const eq_index = std.mem.indexOfScalar(u8, line, '=') orelse {
        return .{ .diagnostic = .{ .line = line_no, .message = "expected binding or function declaration" } };
    };
    const lhs = std.mem.trim(u8, line[0..eq_index], " \t\r");
    const rhs = std.mem.trim(u8, line[eq_index + 1 ..], " \t\r");
    if (rhs.len == 0) return .{ .diagnostic = .{ .line = line_no, .message = "missing expression" } };
    const expr = try parseExpr(allocator, rhs, line_no);

    if (isIdent(lhs)) {
        return .{ .binding = .{ .name = lhs, .expr = expr, .line = line_no } };
    }

    const open_index = std.mem.indexOfScalar(u8, lhs, '(') orelse {
        return .{ .diagnostic = .{ .line = line_no, .message = "invalid binding or function name" } };
    };
    if (lhs[lhs.len - 1] != ')') return .{ .diagnostic = .{ .line = line_no, .message = "invalid binding or function name" } };
    const name = std.mem.trim(u8, lhs[0..open_index], " \t\r");
    if (!isIdent(name)) return .{ .diagnostic = .{ .line = line_no, .message = "invalid binding or function name" } };
    const params = try parseIdentifierList(allocator, lhs[open_index + 1 .. lhs.len - 1]);
    return .{ .function = .{ .name = name, .params = params, .expr = expr, .line = line_no } };
}

fn parseExpr(allocator: std.mem.Allocator, text: []const u8, line_no: usize) !core.Expr {
    var parser = ExprParser{ .allocator = allocator, .line_no = line_no, .text = text };
    try parser.tokenize();
    defer parser.tokens.deinit(allocator);
    return parser.parse();
}

const ExprParser = struct {
    allocator: std.mem.Allocator,
    line_no: usize,
    text: []const u8,
    tokens: std.ArrayListUnmanaged(Token) = .empty,
    index: usize = 0,

    fn tokenize(self: *ExprParser) !void {
        self.tokens = std.ArrayList(Token).empty;
        var pos: usize = 0;
        while (pos < self.text.len) {
            while (pos < self.text.len and isSpace(self.text[pos])) : (pos += 1) {}
            if (pos >= self.text.len) break;

            const c = self.text[pos];
            if (c == '(' or c == ')' or c == ',') {
                try self.tokens.append(self.allocator, .{ .kind = .symbol, .lexeme = self.text[pos .. pos + 1] });
                pos += 1;
                continue;
            }

            if (scanNumber(self.text, pos)) |end| {
                try self.tokens.append(self.allocator, .{ .kind = .number, .lexeme = self.text[pos..end] });
                pos = end;
                continue;
            }

            if (isIdentStart(c)) {
                var end = pos + 1;
                while (end < self.text.len and isIdentContinue(self.text[end])) : (end += 1) {}
                try self.tokens.append(self.allocator, .{ .kind = .ident, .lexeme = self.text[pos..end] });
                pos = end;
                continue;
            }

            return error.ParseFailed;
        }
    }

    fn parse(self: *ExprParser) !core.Expr {
        const expr = try self.parseExprInner();
        if (self.index != self.tokens.items.len) return error.ParseFailed;
        return expr;
    }

    fn parseExprInner(self: *ExprParser) !core.Expr {
        const token = self.peek() orelse return error.ParseFailed;
        switch (token.kind) {
            .number => {
                _ = self.consume();
                const value = try std.fmt.parseFloat(f64, token.lexeme);
                if (!std.math.isFinite(value)) return error.ParseFailed;
                return .{ .number = value };
            },
            .ident => {
                _ = self.consume();
                if (self.peek()) |next| {
                    if (next.kind == .symbol and std.mem.eql(u8, next.lexeme, "(")) {
                        _ = self.consume();
                        var args: std.ArrayListUnmanaged(core.Expr) = .empty;
                        defer args.deinit(self.allocator);
                        if (self.peek()) |peeked| {
                            if (!(peeked.kind == .symbol and std.mem.eql(u8, peeked.lexeme, ")"))) {
                                while (true) {
                                    try args.append(self.allocator, try self.parseExprInner());
                                    if (self.peek()) |comma| {
                                        if (comma.kind == .symbol and std.mem.eql(u8, comma.lexeme, ",")) {
                                            _ = self.consume();
                                            continue;
                                        }
                                    }
                                    break;
                                }
                            }
                        }
                        try self.expect(")");
                        return .{ .call = .{ .name = token.lexeme, .args = try args.toOwnedSlice(self.allocator) } };
                    }
                }
                return .{ .ref_ = token.lexeme };
            },
            .symbol => return error.ParseFailed,
        }
    }

    fn peek(self: *ExprParser) ?Token {
        if (self.index >= self.tokens.items.len) return null;
        return self.tokens.items[self.index];
    }

    fn consume(self: *ExprParser) Token {
        const token = self.tokens.items[self.index];
        self.index += 1;
        return token;
    }

    fn expect(self: *ExprParser, symbol: []const u8) !void {
        const token = self.peek() orelse return error.ParseFailed;
        if (token.kind != .symbol or !std.mem.eql(u8, token.lexeme, symbol)) return error.ParseFailed;
        _ = self.consume();
    }
};

fn normalizeExpr(
    allocator: std.mem.Allocator,
    expr: core.Expr,
    env: *const std.StringHashMap(core.Expr),
    function_defs: *const std.StringHashMap(FunctionDef),
) !core.Expr {
    return switch (expr) {
        .number => expr,
        .ref_ => |name| if (env.get(name)) |value| try value.clone(allocator, true) else .{ .ref_ = try allocator.dupe(u8, name) },
        .call => |call| blk: {
            var args: std.ArrayListUnmanaged(core.Expr) = .empty;
            var args_transferred = false;
            defer {
                if (!args_transferred) {
                    for (args.items) |arg| {
                        arg.deinit(allocator, true);
                    }
                }
                args.deinit(allocator);
            }
            for (call.args) |arg| {
                try args.append(allocator, try normalizeExpr(allocator, arg, env, function_defs));
            }
            if (isBuiltin(call.name)) {
                const result: core.Expr = .{ .call = .{ .name = try allocator.dupe(u8, call.name), .args = try args.toOwnedSlice(allocator) } };
                args_transferred = true;
                break :blk result;
            }
            if (std.mem.eql(u8, call.name, "mod")) {
                const result = try makeCall(allocator, "add", &.{
                    args.items[0],
                    try makeCall(allocator, "mul", &.{ args.items[1], args.items[2] }),
                });
                args_transferred = true;
                break :blk result;
            }
            if (std.mem.eql(u8, call.name, "lerp")) {
                const result = try makeCall(allocator, "add", &.{
                    args.items[1],
                    try makeCall(allocator, "mul", &.{
                        args.items[0],
                        try makeCall(allocator, "sub", &.{ args.items[2], args.items[1] }),
                    }),
                });
                args_transferred = true;
                break :blk result;
            }
            if (std.mem.eql(u8, call.name, "pos")) {
                const result = try makeCall(allocator, "mul", &.{
                    try makeCall(allocator, "add", &.{ args.items[0], .{ .number = 1.0 } }),
                    .{ .number = 0.5 },
                });
                args_transferred = true;
                break :blk result;
            }
            if (std.mem.eql(u8, call.name, "range")) {
                const result = try normalizeExpr(
                    allocator,
                    .{ .call = .{ .name = "lerp", .args = &.{
                        .{ .call = .{ .name = "pos", .args = &.{args.items[0]} } },
                        args.items[1],
                        args.items[2],
                    } } },
                    env,
                    function_defs,
                );
                args_transferred = true;
                break :blk result;
            }
            const function = function_defs.get(call.name) orelse return error.InvalidProgram;
            var local_env = std.StringHashMap(core.Expr).init(allocator);
            defer local_env.deinit();
            for (function.params, args.items) |param, arg| {
                try local_env.put(param, arg);
            }
            break :blk try normalizeExpr(allocator, function.expr, &local_env, function_defs);
        },
    };
}

fn makeCall(allocator: std.mem.Allocator, name: []const u8, args: []const core.Expr) !core.Expr {
    return .{ .call = .{ .name = try allocator.dupe(u8, name), .args = try allocator.dupe(core.Expr, args) } };
}

fn validateExpr(
    expr: core.Expr,
    defined: *const std.StringHashMap(void),
    function_defs: *const std.StringHashMap(FunctionDef),
) ?[]const u8 {
    return switch (expr) {
        .number => null,
        .ref_ => |name| if (defined.contains(name)) null else "unknown identifier",
        .call => |call| blk: {
            if (isBuiltin(call.name)) {
                const argc = call.args.len;
                if (std.mem.eql(u8, call.name, "mix")) {
                    if (argc < 1) break :blk "builtin 'mix' expects at least 1 argument";
                } else {
                    const expected: usize = if (std.mem.eql(u8, call.name, "lowpass")) 2 else if (std.mem.eql(u8, call.name, "adsr")) 5 else if (std.mem.eql(u8, call.name, "mtof") or std.mem.eql(u8, call.name, "phase") or std.mem.eql(u8, call.name, "sin")) 1 else 2;
                    if (argc != expected) break :blk "builtin arity mismatch";
                }
            } else if (isPrelude(call.name)) {
            } else {
                const function = function_defs.get(call.name) orelse break :blk "unknown callable";
                if (call.args.len != function.params.len) break :blk "function arity mismatch";
            }
            for (call.args) |arg| {
            if (validateExpr(arg, defined, function_defs)) |msg| break :blk msg;
        }
        break :blk null;
    },
    };
}

fn findFunctionCycle(
    allocator: std.mem.Allocator,
    program: Program,
    function_defs: *const std.StringHashMap(FunctionDef),
) anyerror!?Diagnostic {
    var marks = std.StringHashMap(VisitMark).init(allocator);
    defer marks.deinit();
    var stack = std.ArrayListUnmanaged([]const u8){};
    defer stack.deinit(allocator);

    for (program.functions) |function| {
        if (try visitFunction(allocator, function.name, function_defs, &marks, &stack)) |diagnostic| {
            return diagnostic;
        }
    }
    return null;
}

fn visitFunction(
    allocator: std.mem.Allocator,
    name: []const u8,
    function_defs: *const std.StringHashMap(FunctionDef),
    marks: *std.StringHashMap(VisitMark),
    stack: *std.ArrayListUnmanaged([]const u8),
) anyerror!?Diagnostic {
    if (marks.get(name)) |mark| {
        return switch (mark) {
            .visited => null,
            .visiting => .{ .line = 0, .message = "function call cycle detected" },
        };
    }

    try marks.put(name, .visiting);
    try stack.append(allocator, name);
    defer _ = stack.pop();

    const function = function_defs.get(name).?;
    if (try visitExpr(allocator, function.expr, function_defs, marks, stack)) |diagnostic| {
        return diagnostic;
    }

    try marks.put(name, .visited);
    return null;
}

fn visitExpr(
    allocator: std.mem.Allocator,
    expr: core.Expr,
    function_defs: *const std.StringHashMap(FunctionDef),
    marks: *std.StringHashMap(VisitMark),
    stack: *std.ArrayListUnmanaged([]const u8),
) anyerror!?Diagnostic {
    return switch (expr) {
        .number, .ref_ => null,
        .call => |call| blk: {
            if (!isBuiltin(call.name) and !isPrelude(call.name)) {
                if (try visitFunction(allocator, call.name, function_defs, marks, stack)) |diagnostic| {
                    break :blk diagnostic;
                }
            }
            for (call.args) |arg| {
                if (try visitExpr(allocator, arg, function_defs, marks, stack)) |diagnostic| {
                    break :blk diagnostic;
                }
            }
            break :blk null;
        },
    };
}

fn stripSourceLine(raw_line: []const u8) []const u8 {
    const comment_index = std.mem.indexOfScalar(u8, raw_line, '#') orelse raw_line.len;
    return std.mem.trim(u8, raw_line[0..comment_index], " \t\r");
}

fn startsWithKeyword(line: []const u8, keyword: []const u8) bool {
    return std.mem.eql(u8, line, keyword) or
        (line.len > keyword.len and std.mem.startsWith(u8, line, keyword) and isSpace(line[keyword.len]));
}

fn parseIdentifierList(allocator: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r");
    if (trimmed.len == 0) return allocator.alloc([]const u8, 0);

    var items: std.ArrayListUnmanaged([]const u8) = .empty;
    defer items.deinit(allocator);
    var iter = std.mem.splitScalar(u8, trimmed, ',');
    while (iter.next()) |item_raw| {
        const item = std.mem.trim(u8, item_raw, " \t\r");
        if (!isIdent(item)) return error.ParseFailed;
        try items.append(allocator, item);
    }
    return items.toOwnedSlice(allocator);
}

fn scanNumber(text: []const u8, start: usize) ?usize {
    var i = start;
    if (text[i] == '+' or text[i] == '-') {
        i += 1;
        if (i >= text.len) return null;
    }

    var digits_before = false;
    while (i < text.len and isDigit(text[i])) : (i += 1) {
        digits_before = true;
    }

    var digits_after = false;
    if (i < text.len and text[i] == '.') {
        i += 1;
        while (i < text.len and isDigit(text[i])) : (i += 1) {
            digits_after = true;
        }
    }

    if (!digits_before and !digits_after) return null;

    if (i < text.len and (text[i] == 'e' or text[i] == 'E')) {
        var j = i + 1;
        if (j < text.len and (text[j] == '+' or text[j] == '-')) j += 1;
        if (j >= text.len or !isDigit(text[j])) return null;
        i = j + 1;
        while (i < text.len and isDigit(text[i])) : (i += 1) {}
    }

    return i;
}

fn isKeyword(name: []const u8) bool {
    for (KEYWORDS) |keyword| {
        if (std.mem.eql(u8, name, keyword)) return true;
    }
    return false;
}

fn isBuiltin(name: []const u8) bool {
    for (BUILTIN_NAMES) |builtin| {
        if (std.mem.eql(u8, name, builtin)) return true;
    }
    return false;
}

fn isPrelude(name: []const u8) bool {
    for (PRELUDE_NAMES) |prelude| {
        if (std.mem.eql(u8, name, prelude)) return true;
    }
    return false;
}

fn isIdent(text: []const u8) bool {
    if (text.len == 0 or !isIdentStart(text[0])) return false;
    for (text[1..]) |c| {
        if (!isIdentContinue(c)) return false;
    }
    return true;
}

fn isIdentStart(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '_';
}

fn isIdentContinue(c: u8) bool {
    return isIdentStart(c) or isDigit(c);
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r';
}

test "parse and validate simple voice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\voice(freq, amp) = mul(sin(phase(freq)), amp)
        \\input note
        \\input gate
        \\freq = mtof(note)
        \\out = voice(freq, gate)
    ;

    const outcome = try parse(allocator, source);
    try std.testing.expect(outcome.diagnostic == null);
    const program = outcome.program.?;
    try std.testing.expectEqual(@as(usize, 1), program.functions.len);
    try std.testing.expectEqual(@as(usize, 2), program.inputs.len);
    try std.testing.expectEqual(@as(usize, 2), program.bindings.len);
    try std.testing.expect((try validate(allocator, program)) == null);
}

test "normalize expands user functions and prelude" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\voice(freq, amp) = mul(sin(phase(freq)), pos(amp))
        \\input freq
        \\input amp
        \\tone = voice(freq, amp)
        \\out = tone
    ;

    const outcome = try parse(allocator, source);
    const program = outcome.program.?;
    const normalized = try normalize(allocator, program);
    try std.testing.expectEqual(@as(usize, 2), normalized.bindings.len);
    switch (normalized.bindings[0].expr) {
        .call => |call| try std.testing.expect(std.mem.eql(u8, call.name, "mul")),
        else => return error.TestUnexpectedResult,
    }
}

test "render parsed phase sine voice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\input freq
        \\out = sin(phase(freq))
    ;
    const outcome = try parse(allocator, source);
    const program = outcome.program.?;
    const output = try render(allocator, program, &.{&.{ 1.0, 1.0, 1.0, 1.0 }}, 4, 4.0);
    defer allocator.free(output);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), output[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), output[1], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), output[2], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -1.0), output[3], 1e-9);
}

test "validate rejects function call cycle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\a(x) = b(x)
        \\b(x) = a(x)
        \\input x
        \\out = a(x)
    ;

    const outcome = try parse(allocator, source);
    const program = outcome.program.?;
    const diagnostic = try validate(allocator, program);
    try std.testing.expect(diagnostic != null);
    try std.testing.expect(std.mem.eql(u8, diagnostic.?.message, "function call cycle detected"));
}

test "validate reports allocator failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\voice(freq) = sin(phase(freq))
        \\input freq
        \\out = voice(freq)
    ;

    const outcome = try parse(allocator, source);
    const program = outcome.program.?;

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 0,
    });
    try std.testing.expectError(error.OutOfMemory, validate(failing_allocator.allocator(), program));
}

test "parse owns source and deinit releases recursive allocations" {
    const allocator = std.testing.allocator;
    const source =
        \\voice(freq, amp) = mul(sin(phase(freq)), pos(amp))
        \\input freq
        \\input amp
        \\tone = voice(freq, amp)
        \\out = tone
    ;

    const outcome = try parse(allocator, source);
    try std.testing.expect(outcome.diagnostic == null);
    var program = outcome.program.?;
    defer program.deinit(allocator);
}

test "normalized core owns its expression tree" {
    const allocator = std.testing.allocator;
    const source =
        \\voice(freq, amp) = mul(sin(phase(freq)), pos(amp))
        \\input freq
        \\input amp
        \\out = voice(freq, amp)
    ;

    const outcome = try parse(allocator, source);
    try std.testing.expect(outcome.diagnostic == null);
    var program = outcome.program.?;
    defer program.deinit(allocator);

    const normalized = try normalize(allocator, program);
    defer normalized.deinit(allocator);

    program.deinit(allocator);
    program = .{ .functions = &.{}, .inputs = &.{}, .bindings = &.{}, .source_storage = null };

    var compiled = try core.compile(allocator, normalized);
    defer compiled.deinit();
    try std.testing.expect(compiled.input_names.len == 2);
}

test "parse rejects non finite numeric literals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\input x
        \\out = add(1e309, x)
    ;

    try std.testing.expectError(error.ParseFailed, parse(allocator, source));
}
