//! Explicit diagnostic modes. All mutations belong to freshly spawned private
//! console instances; the normal shell/other windows keep their own streams.
const r4os = @import("r4os");
const r4std = @import("r4std");
const std = @import("std");
const path = "C:\\R4OS\\SOFTWARE\\TERMINAL\\TERMINAL.R4X";
fn own(sys: r4os.r4sys.Context) ?r4os.abi.ProgramProcessHandle {
    const bundle = sys.base.bundle orelse return null;
    var handle: r4os.abi.ProgramProcessHandle = .{};
    if (sys.programOpenHandle(@intCast(bundle.raw.instance_id), &handle) != r4os.abi.program_handle_ok) return null;
    return handle;
}
fn snapshot(sys: r4os.r4sys.Context, id: u32, expected: []const u8) bool {
    var bytes: [16385]u8 = undefined;
    const count = sys.consoleOutput(id,&bytes);
    return count == expected.len and std.mem.eql(u8,bytes[0..@intCast(@max(0,count))],expected);
}
fn stateIs(sys: r4os.r4sys.Context, id: u32, x: i32, y: i32) bool {
    var state: r4os.abi.ConsoleState = .{};
    return sys.consoleState(id,&state) == 0 and state.cursor_x == x and state.cursor_y == y;
}
pub fn probe(sys: r4os.r4sys.Context) i32 {
    const handle = own(sys) orelse return 1;
    const id = handle.instance_id;
    if (sys.consoleSetMetrics(id,8,4) != 0) return 2;
    var info: r4os.abi.ConsoleTextInfo = .{};
    if (sys.consoleTextInfo(handle,&info) != 0 or info.version != 1 or info.size != 32 or info.encoding != 65001 or info.transcript_encoding != 65001) return 3;
    var invalid = handle;
    invalid.reserved = 1;
    var untouched: r4os.abi.ConsoleTextInfo = .{ .decode_errors = 0xfeed1234 };
    if (sys.consoleTextInfo(invalid,&untouched) != -1 or untouched.decode_errors != 0xfeed1234 or sys.consoleSetEncoding(invalid,437) != -1) return 23;
    if (sys.consoleSetEncoding(handle,437) != 0) return 4;
    sys.write("\xc4\x81");
    if (!snapshot(sys,id,"\xe2\x94\x80\xc3\xbc") or !stateIs(sys,id,2,0)) return 5;
    if (sys.consoleSetEncoding(handle,1252) != 0) return 6;
    sys.write("\x80\x81");
    if (!snapshot(sys,id,"\xe2\x94\x80\xc3\xbc\xe2\x82\xac\xef\xbf\xbd")) return 7;
    if (sys.consoleSetEncoding(handle,65001) != 0) return 8;
    for ([_][]const u8{ "\xc3\xbc", "\xe2\x82\xac", "\xf0\x9f\x98\x80" }) |scalar| {
        for (0..scalar.len + 1) |split| {
            sys.write("\x0c");
            sys.write(scalar[0..split]);
            if (!snapshot(sys,id,if (split == scalar.len) scalar else "")) return 9;
            sys.write(scalar[split..]);
            if (!snapshot(sys,id,scalar) or !stateIs(sys,id,1,0)) return 10;
        }
    }
    sys.write("\x0c\xc3");
    if (sys.consoleTextInfo(handle,&info) != 0 or info.pending_bytes != 1 or !snapshot(sys,id,"")) return 11;
    if (sys.consoleSetEncoding(handle,437) != -2 or sys.consoleSetEncoding(handle,850) != -1) return 12;
    if (sys.base.stderr("A") != 1) return 13;
    sys.write("\xbc");
    if (!snapshot(sys,id,"A\xc3\xbc") or !stateIs(sys,id,2,0)) return 14;
    sys.write("\x0c\xc3Q");
    if (!snapshot(sys,id,"\xef\xbf\xbdQ")) return 15;
    if (sys.consoleTextInfo(handle,&info) != 0 or info.pending_bytes != 0 or info.decode_errors != 2) return 16;
    sys.write("\x0c1234567\xc3\xbc");
    if (!stateIs(sys,id,8,0)) return 17;
    sys.write("\xe2\x94\x80");
    if (!stateIs(sys,id,1,1)) return 18;
    sys.write("\x08\x08");
    if (!snapshot(sys,id,"1234567") or !stateIs(sys,id,7,0)) return 19;
    sys.write("\x0c");
    var chunk: [1024]u8 = undefined;
    for (0..512) |index| { chunk[index*2] = 0xc3; chunk[index*2+1] = 0xbc; }
    for (0..17) |_| sys.write(&chunk);
    sys.write("Z");
    var ring: [16385]u8 = undefined;
    const count = sys.consoleOutput(id,&ring);
    if (count != 16383 or ring[0] != 0xc3 or ring[1] != 0xbc or ring[16382] != 'Z' or !std.unicode.utf8ValidateSlice(ring[0..16383])) return 20;
    var state: r4os.abi.ConsoleState = .{};
    if (sys.consoleState(id,&state) != 0 or state.output_len != 16383 or state.output_dropped_bytes != 1026) return 21;
    for (1..6) |capacity| {
        @memset(ring[0..8],0xa5);
        const length = sys.consoleOutput(id,ring[0..capacity]);
        if (length < 0 or !std.unicode.utf8ValidateSlice(ring[0..@intCast(length)]) or ring[@intCast(length)] != 0 or ring[capacity] != 0xa5) return 22;
    }
    _ = r4std; // Production decoder binding remains initialized by Terminal.
    return 0;
}
pub fn closeProbe(sys: r4os.r4sys.Context) i32 {
    sys.write("\xc3");
    return 0;
}
pub fn run(sys: r4os.r4sys.Context) i32 {
    for ([_][*:0]const u8{ "/TEXTPROBE", "/TEXTCLOSE" },0..) |args,index| {
        var handle: r4os.abi.ProgramProcessHandle = .{};
        if (sys.programSpawnWithConsoleHostHandle(path,args,.console,.terminal_window,&handle) != r4os.abi.program_handle_ok) return 1;
        var completion: r4os.abi.ProgramProcessCompletion = .{};
        var reaped = false;
        defer if (!reaped) {
            _ = sys.programHandleKill(&handle);
            _ = sys.programHandleWait(&handle,r4os.abi.thread_wait_forever,&completion);
            _ = sys.programHandleReap(&handle,&completion);
        };
        if (sys.programHandleWait(&handle,3000,&completion) != r4os.abi.program_handle_ok) return 2;
        if (completion.exit_code != 0) {
            sys.write("Console text child failure="); sys.printI32(completion.exit_code); sys.println(""); return 3;
        }
        var info: r4os.abi.ConsoleTextInfo = .{};
        if (sys.consoleTextInfo(handle,&info) != 0 or info.pending_bytes != 0 or info.flags != 1) return 4;
        if (sys.consoleSetEncoding(handle,437) != -2) return 9;
        if (index == 1) {
            if (info.truncated_sequences != 1 or !snapshot(sys,handle.instance_id,"\xef\xbf\xbd")) return 5;
            var raw: [1]u8 = .{0};
            var read: u32 = 0;
            if (sys.programCompletionRead(&handle,1,&raw,&read) != r4os.abi.program_handle_ok or read != 1 or raw[0] != 0xbf) return 6;
        }
        if (sys.programHandleReap(&handle,&completion) != r4os.abi.program_handle_ok) return 7;
        reaped = true;
        if (sys.consoleTextInfo(handle,&info) >= 0) return 8;
    }
    sys.println("Console text: CP437 C4/81,1252, every UTF8 split, independent streams, scalar backspace/wrap, ring/small snapshots, close and raw completion: OK");
    return 0;
}
