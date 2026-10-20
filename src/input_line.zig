//! Console sources may deliver CR, LF, or CRLF. Submit each line once.
pub const Normalizer = struct {
    after_cr: bool = false,

    pub fn accept(self: *Normalizer, byte: u8) ?u8 {
        const paired_lf = self.after_cr and byte == '\n';
        self.after_cr = byte == '\r';
        if (paired_lf) return null;
        return if (byte == '\r') '\n' else byte;
    }
};

pub fn checkExamples() bool {
    const input = "A\rB\nC\r\nD\r\r\n\n\x08\x03\x80Z";
    const expected = "A\nB\nC\nD\n\n\n\x08\x03\x80Z";
    var normalizer: Normalizer = .{};
    var index: usize = 0;
    // Individual calls also cover CR/LF split across input-buffer refills.
    for (input) |byte| {
        if (normalizer.accept(byte)) |value| {
            if (index == expected.len or value != expected[index]) return false;
            index += 1;
        }
    }
    return index == expected.len;
}

test "CR, LF and split CRLF submit once while edit/history bytes are preserved" {
    const std = @import("std");
    try std.testing.expect(checkExamples());
}

const r4os = @import("r4os");
const codec = @import("r4std").codec;
pub const Action = union(enum) { text: u32, key: u8 };

/// One stream per terminal instance, retained across API reads and SSH packets.
/// Native/desktop events are already typed; only stream-byte events use UTF-8
/// and bounded ANSI key parsing. Invalid prefixes are discarded explicitly;
/// retry their offending byte so valid following ASCII is retained.
pub const Decoder = struct {
    stream: codec.Stream = .{},
    normalizer: Normalizer = .{},
    escape: enum { none, esc, csi, ss3 } = .none,
    parameter: u16 = 0,
    digits: u8 = 0,
    invalid_prefixes: u64 = 0,

    pub fn accept(self: *Decoder, event: r4os.abi.ConsoleInputEvent) ?Action {
        if (!r4os.input_events.valid(event)) {
            self.invalid_prefixes +%= 1;
            return null;
        }
        if (event.kind == r4os.abi.console_input_event_utf8_byte) {
            const byte: u8 = @intCast(event.value);
            const decoded = self.stream.push(byte) catch {
                self.invalid_prefixes +%= 1;
                self.stream.reset();
                const retried = self.stream.push(byte) catch return null;
                return self.fromDecoded(retried);
            };
            return self.fromDecoded(decoded);
        }
        // Typed events are independent of the byte stream. A native key or
        // scalar between two stream bytes must not discard its valid prefix.
        if (event.kind == r4os.abi.console_input_event_key) return self.control(@intCast(event.value));
        return self.scalar(event.value);
    }
    fn fromDecoded(self: *Decoder, value: codec.Decoded) ?Action {
        return switch (value) {
            .incomplete => null,
            .complete => |v| self.ansi(v.value),
        };
    }
    fn scalar(self: *Decoder, value: u32) ?Action {
        if (value < 0x20 or value == 0x7f) return self.control(@intCast(value));
        self.normalizer.after_cr = false;
        return .{ .text = value };
    }
    fn control(self: *Decoder, value: u8) ?Action {
        const key = self.normalizer.accept(value) orelse return null;
        return .{ .key = if (key == 0x7f) 0x08 else key };
    }
    fn ansi(self: *Decoder, value: u32) ?Action {
        switch (self.escape) {
            .none => if (value == 0x1b) {
                self.escape = .esc;
                return null;
            },
            .esc => {
                self.escape = .none;
                if (value == '[' or value == 'O') {
                    self.escape = if (value == '[') .csi else .ss3;
                    self.parameter = 0;
                    self.digits = 0;
                    return null;
                }
            },
            .csi, .ss3 => {
                const state = self.escape;
                if (state == .csi and value >= '0' and value <= '9' and self.digits < 3) {
                    self.parameter = self.parameter * 10 + @as(u16, @intCast(value - '0'));
                    self.digits += 1;
                    return null;
                }
                self.escape = .none;
                return switch (value) {
                    'A' => self.control(@intCast(r4os.abi.console_input_key_up)),
                    'B' => self.control(@intCast(r4os.abi.console_input_key_down)),
                    'R' => if (state == .ss3) self.control(@intCast(r4os.abi.console_input_key_f3)) else null,
                    '~' => if (state == .csi and self.parameter == 13) self.control(@intCast(r4os.abi.console_input_key_f3)) else null,
                    else => null,
                };
            },
        }
        return self.scalar(value);
    }
};

pub fn appendScalar(buffer: []u8, len: *usize, value: u32) ?[]const u8 {
    var encoded: [4]u8 = undefined;
    const bytes = codec.encode(value, &encoded) catch return null;
    if (bytes.len > buffer.len - len.*) return null;
    const start = len.*;
    @memcpy(buffer[start..][0..bytes.len], bytes);
    len.* += bytes.len;
    return buffer[start..len.*];
}
pub fn removeLast(buffer: []const u8) usize {
    if (buffer.len == 0) return 0;
    var start = buffer.len - 1;
    while (start != 0 and buffer[start] & 0xc0 == 0x80) start -= 1;
    return start;
}
pub fn boundedPrefix(input: []const u8, capacity: usize) usize {
    var offset: usize = 0;
    while (offset < input.len) {
        const decoded = codec.decode(input[offset..]) catch break;
        const count = switch (decoded) {
            .incomplete => break,
            .complete => |v| v.byte_length,
        };
        if (count > capacity - offset) break;
        offset += count;
    }
    return offset;
}

pub fn checkEvents() bool {
    var mixed: Decoder = .{};
    if (mixed.accept(r4os.input_events.utf8Byte(0xd0)) != null) return false;
    const direct = mixed.accept(r4os.input_events.text(0x20ac).?) orelse return false;
    if (direct != .text or direct.text != 0x20ac) return false;
    const navigation = mixed.accept(r4os.input_events.key(0x80)) orelse return false;
    if (navigation != .key or navigation.key != 0x80) return false;
    const resumed = mixed.accept(r4os.input_events.utf8Byte(0x81)) orelse return false;
    if (resumed != .text or resumed.text != 0x401 or mixed.invalid_prefixes != 0) return false;
    const text = "\xc3\xbc\xe2\x82\xac\xd0\x81\xc4\x80\xf0\x9f\x98\x80";
    const scalars = [_]u32{ 0xfc, 0x20ac, 0x401, 0x100, 0x1f600 };
    var decoder: Decoder = .{};
    var buffer: [32]u8 = undefined;
    var len: usize = 0;
    var count: usize = 0;
    for (text) |byte| {
        if (decoder.accept(r4os.input_events.utf8Byte(byte))) |action| switch (action) {
            .key => return false,
            .text => |value| {
                if (count == scalars.len or scalars[count] != value) return false;
                _ = appendScalar(&buffer, &len, value) orelse return false;
                count += 1;
            },
        };
    }
    if (count != scalars.len or !@import("std").mem.eql(u8, text, buffer[0..len])) return false;
    var native: Decoder = .{};
    for (scalars) |value| {
        const action = native.accept(r4os.input_events.text(value).?) orelse return false;
        if (action != .text or action.text != value) return false;
    }
    for ([_]u8{ 0x80, 0x81, 0x82, 8 }) |key| {
        const action = decoder.accept(r4os.input_events.key(key)) orelse return false;
        if (action != .key or action.key != key) return false;
    }
    const old_len = len;
    if (appendScalar(buffer[0 .. len + 1], &len, 0x20ac) != null or len != old_len) return false;
    if (boundedPrefix(text, 3) != 2 or boundedPrefix(text, text.len - 1) != text.len - 4) return false;
    for (0..scalars.len) |_| len = removeLast(buffer[0..len]);
    if (len != 0) return false;
    if (decoder.accept(r4os.input_events.utf8Byte(0xd0)) != null) return false;
    const recovered = decoder.accept(r4os.input_events.utf8Byte('Q')) orelse return false;
    if (recovered != .text or recovered.text != 'Q' or decoder.invalid_prefixes != 1) return false;
    for ("\x1b[") |byte| if (decoder.accept(r4os.input_events.utf8Byte(byte)) != null) return false;
    const up = decoder.accept(r4os.input_events.utf8Byte('A')) orelse return false;
    if (up != .key or up.key != 0x80) return false;
    const enter = decoder.accept(r4os.input_events.key(13)) orelse return false;
    if (enter != .key or enter.key != 10 or decoder.accept(r4os.input_events.utf8Byte(10)) != null) return false;
    return true;
}
