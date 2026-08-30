// TinyCC (tcc) bindings for Bun's FFI.
const std = @import("std");
const bun = @import("bun");
const Allocator = std.mem.Allocator;

pub const Error = error{
    InvalidOptions,
    InvalidIncludePath,
    CompileError,
    // output
    InvalidOutputType,
    SyntaxError,
    InvalidLibraryPath,
    InvalidSymbol,
    ExecError,
    /// Could not get a symbol for some reason
    RelocationError,
    /// TCC is not available on this platform
    Unsupported,
};

pub const OutputFormat = enum(c_int) {
    /// Output will be run in memory
    Memory = 1,
    /// Executable file
    Exe = 2,
    /// Dynamic library
    Dll = 3,
    /// Object file
    Obj = 4,
    /// Only preprocess
    Preprocess = 5,
};

/// Nominal type for some registered symbol.
pub const Symbol = opaque {
    const Callback = fn (?*anyopaque, [*:0]const u8, ?*const Symbol) void;
};

// ============================================================
// TCC is available on all platforms including Android (aarch64)
// ============================================================
pub const tcc_available = true;

pub const TCCState = State;

pub const State = NativeState;

// ---------- Native (non-Android) implementation ----------
const TCCErrorFunc = ?*const fn (?*anyopaque, [*:0]const u8) callconv(.C) void;
fn ErrorFunc(Ctx: type) type {
    return fn (ctx: ?*Ctx, msg: [*:0]const u8) callconv(.C) void;
}

extern fn tcc_new() ?*NativeState;
extern fn tcc_delete(s: *NativeState) void;
extern fn tcc_set_lib_path(s: *NativeState, path: [*:0]const u8) void;
extern fn tcc_set_error_func(s: *NativeState, error_opaque: ?*anyopaque, error_func: TCCErrorFunc) void;
extern fn tcc_get_error_func(s: *NativeState) TCCErrorFunc;
extern fn tcc_get_error_opaque(s: *NativeState) ?*anyopaque;
extern fn tcc_set_options(s: *NativeState, str: [*:0]const u8) c_int;
extern fn tcc_add_include_path(s: *NativeState, pathname: [*:0]const u8) c_int;
extern fn tcc_add_sysinclude_path(s: *NativeState, pathname: [*:0]const u8) c_int;
extern fn tcc_define_symbol(s: *NativeState, sym: [*:0]const u8, value: [*:0]const u8) void;
extern fn tcc_undefine_symbol(s: *NativeState, sym: [*:0]const u8) void;
extern fn tcc_add_file(s: *NativeState, filename: [*:0]const u8) c_int;
extern fn tcc_compile_string(s: *NativeState, buf: [*:0]const u8) c_int;
extern fn tcc_set_output_type(s: *NativeState, output_type: c_int) c_int;
extern fn tcc_add_library_path(s: *NativeState, pathname: [*:0]const u8) c_int;
extern fn tcc_add_library(s: *NativeState, libraryname: [*:0]const u8) c_int;
extern fn tcc_add_symbol(s: *NativeState, name: [*:0]const u8, val: *const anyopaque) c_int;
extern fn tcc_output_file(s: *NativeState, filename: [*:0]const u8) c_int;
extern fn tcc_run(s: *NativeState, argc: c_int, argv: [*c][*c]u8) c_int;
extern fn tcc_relocate(s1: *NativeState, ptr: ?*anyopaque) c_int;
extern fn tcc_get_symbol(s: *NativeState, name: [*:0]const u8) ?*anyopaque;
extern fn tcc_list_symbols(s: *NativeState, ctx: ?*anyopaque, symbol_cb: ?*const fn (?*anyopaque, [*:0]const u8, ?*const anyopaque) callconv(.C) void) void;

const TCC_OUTPUT_MEMORY = @as(c_int, 1);
const TCC_OUTPUT_EXE = @as(c_int, 2);
const TCC_OUTPUT_DLL = @as(c_int, 3);
const TCC_OUTPUT_OBJ = @as(c_int, 4);
const TCC_OUTPUT_PREPROCESS = @as(c_int, 5);
const TCC_RELOCATE_AUTO: ?*anyopaque = @ptrCast(&1);

const NativeState = opaque {
    pub fn Config(ErrCtx: type) type {
        return struct {
            options: ?[:0]const u8 = null,
            output_type: OutputFormat = .Memory,
            err: struct {
                ctx: ?*ErrCtx = null,
                handler: *const ErrorFunc(ErrCtx),
            },
        };
    }

    /// Create a new TCC compilation context
    pub fn new() Allocator.Error!*NativeState {
        return tcc_new() orelse error.OutOfMemory;
    }

    /// Create and initialize a new TCC compilation context
    pub fn init(ErrCtx: type, config: Config(ErrCtx), comptime validate_options: bool) (Allocator.Error || Error)!*NativeState {
        var state = try NativeState.new();
        errdefer state.deinit();

        if (comptime !validate_options) {
            if (config.options) |options| state.setOptions(options) catch if (comptime @import("builtin").mode == .Debug) {
                @panic("Failed to set options");
            };
        }

        state.setErrorFunc(ErrCtx, config.err.ctx, config.err.handler);

        if (comptime validate_options) {
            if (config.options) |options| try state.setOptions(options);
        }

        try state.setOutputType(config.output_type);

        return state;
    }

    /// Free a TCC compilation context
    pub fn deinit(s: *NativeState) void {
        tcc_delete(s);
    }

    /// Set `CONFIG_TCCDIR` at runtime
    pub fn setLibPath(s: *NativeState, path: [:0]const u8) void {
        tcc_set_lib_path(s, path.ptr);
    }

    /// Set error/warning display callback
    pub fn setErrorFunc(s: *NativeState, Context: type, errorOpaque: ?*Context, errorFunc: *const ErrorFunc(Context)) void {
        tcc_set_error_func(s, errorOpaque, @ptrCast(errorFunc));
    }

    /// Return error/warning callback
    pub fn getErrorFunc(s: *NativeState) ?*const ErrorFunc(anyopaque) {
        return tcc_get_error_func(s);
    }

    /// Return error/warning callback opaque pointer
    pub fn getErrorOpaque(s: *NativeState) ?*anyopaque {
        return tcc_get_error_opaque(s);
    }

    /// Set options as from command line (multiple supported)
    pub fn setOptions(s: *NativeState, str: [:0]const u8) Error!void {
        if (tcc_set_options(s, str.ptr) != 0) {
            @branchHint(.unlikely);
            return error.InvalidOptions;
        }
    }

    pub fn addIncludePath(s: *NativeState, pathname: [:0]const u8) Error!void {
        if (tcc_add_include_path(s, pathname.ptr) != 0) {
            @branchHint(.unlikely);
            return error.InvalidIncludePath;
        }
    }

    pub fn addSysIncludePath(s: *NativeState, pathname: [:0]const u8) Error!void {
        if (tcc_add_sysinclude_path(s, pathname.ptr) != 0) {
            @branchHint(.unlikely);
            return error.InvalidIncludePath;
        }
    }

    pub fn defineSymbol(s: *NativeState, sym: [:0]const u8, value: [:0]const u8) void {
        tcc_define_symbol(s, sym.ptr, value.ptr);
    }

    pub fn defineSymbolsComptime(s: *NativeState, symbols: anytype) void {
        const info = @typeInfo(@TypeOf(symbols));
        var buf: [256]u8 = undefined;

        inline for (info.@"struct".fields) |field| {
            const value = @field(symbols, field.name);
            switch (@typeInfo(field.type)) {
                .int, .comptime_int => {
                    s.defineSymbol(
                        field.name,
                        std.fmt.bufPrintZ(&buf, "{d}", .{value}) catch unreachable,
                    );
                },
                .pointer => {
                    s.defineSymbol(s, field.name, value);
                },
                else => @compileError("Macro '" ++ field.name ++ "' has unsupported symbol type: " ++ @typeName(@TypeOf(value))),
            }
        }
    }

    pub fn undefineSymbol(s: *NativeState, sym: [:0]const u8) void {
        tcc_undefine_symbol(s, sym.ptr);
    }

    pub fn addFile(s: *NativeState, filename: [:0]const u8) Error!void {
        if (tcc_add_file(s, filename.ptr) != 0) {
            @branchHint(.unlikely);
            return error.CompileError;
        }
    }

    pub fn compileString(s: *NativeState, buf: [:0]const u8) Error!void {
        if (tcc_compile_string(s, buf.ptr) != 0) {
            @branchHint(.unlikely);
            return error.CompileError;
        }
    }

    pub fn setOutputType(s: *NativeState, outputType: OutputFormat) Error!void {
        if (tcc_set_output_type(s, @intFromEnum(outputType)) == -1) {
            @branchHint(.unlikely);
            return error.InvalidOutputType;
        }
    }

    pub fn addLibraryPath(s: *NativeState, pathname: [:0]const u8) Error!void {
        if (tcc_add_library_path(s, pathname.ptr) != 0) {
            @branchHint(.unlikely);
            return error.InvalidLibraryPath;
        }
    }

    pub fn addLibrary(s: *NativeState, libraryname: [:0]const u8) Error!void {
        if (tcc_add_library(s, libraryname.ptr) != 0) {
            @branchHint(.unlikely);
            return error.InvalidLibraryPath;
        }
    }

    pub fn addSymbol(s: *NativeState, name: [:0]const u8, val: *const anyopaque) Error!void {
        if (tcc_add_symbol(s, name.ptr, val) != 0) {
            @branchHint(.unlikely);
            return error.InvalidSymbol;
        }
    }

    pub fn addSymbolsComptime(s: *NativeState, symbols: anytype) Error!void {
        const info = @typeInfo(@TypeOf(symbols));
        inline for (info.@"struct".fields) |field| {
            const value = @field(symbols, field.name);
            try s.addSymbol(field.name, value);
        }
    }

    pub fn outputFile(s: *NativeState, filename: [:0]const u8) Error!void {
        if (tcc_output_file(s, filename.ptr) == -1) {
            @branchHint(.unlikely);
            return error.OutputError;
        }
    }

    pub fn run(s: *NativeState, argc: c_int, argv: [*:0]const [*:0]const u8) c_int {
        return tcc_run(s, argc, argv);
    }

    pub fn relocate(s: *NativeState, ptr: ?*anyopaque) Error!usize {
        const size = tcc_relocate(s, ptr);
        if (size < 0) {
            @branchHint(.unlikely);
            return error.RelocationError;
        }
        return @intCast(size);
    }

    pub fn getSymbol(s: *NativeState, name: [:0]const u8) ?*Symbol {
        return @ptrCast(tcc_get_symbol(s, name.ptr));
    }

    pub fn listSymbols(s: *NativeState, ctx: ?*anyopaque, symbolCb: ?*const Symbol.Callback) void {
        tcc_list_symbols(s, ctx, symbolCb);
    }
};
