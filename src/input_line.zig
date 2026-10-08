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
