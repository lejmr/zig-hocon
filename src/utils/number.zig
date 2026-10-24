//! What a number is, for the parser (`checkNumber`) and for JSON output
//! (`isJsonNumber`).

const std = @import("std");

/// JSON's number grammar, all of the text or nothing:
/// `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`
/// So `.5`, `1.`, `01` and `1 2` are not numbers.
pub fn isJsonNumber(text: []const u8) bool {
    var i: usize = 0;
    if (i < text.len and text[i] == '-') i += 1;

    // Integer part: a lone 0, or a non-zero digit and any digits after it.
    if (i >= text.len or !std.ascii.isDigit(text[i])) return false;
    if (text[i] == '0') i += 1 else i = skipDigits(text, i);

    if (i < text.len and text[i] == '.') {
        const start = i + 1;
        i = skipDigits(text, start);
        if (i == start) return false;
    }

    if (i < text.len and (text[i] == 'e' or text[i] == 'E')) {
        i += 1;
        if (i < text.len and (text[i] == '+' or text[i] == '-')) i += 1;
        const start = i;
        i = skipDigits(text, start);
        if (i == start) return false;
    }

    return i == text.len;
}

fn skipDigits(text: []const u8, from: usize) usize {
    var i = from;
    while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
    return i;
}

pub const NumberError = error{ LeadingZeroIsNotAJsonNumber, HyphenIsNotAJsonNumber, BadNumber };

/// A word that starts with a digit or `-` starts with a number: the run of
/// characters JSON allows in one (`0-9 + - . e E`) is parsed as a number, with
/// no fallback to text. So `1e`, `01`, `1.`, `-.5` and `-foo` are errors.
///
/// Text after the run concatenates with the number it starts with, as in
/// `10.0bar` — which needs a number to be there: `-foo` and `1.2.3x` have
/// none. A unit that starts with `e` or `E` lends the run its first letter, so
/// `5EB` and `5exabytes` are the number 5 and the unit. Nor may the run hold a
/// `+` then: `1e+5.x`.
pub fn checkNumber(word: []const u8) NumberError!void {
    if (word.len == 0 or !(std.ascii.isDigit(word[0]) or word[0] == '-')) return;
    const end = std.mem.indexOfNone(u8, word, "0123456789+-.eE") orelse word.len;
    const run = word[0..end];
    if (isJsonNumber(run)) return;
    try checkPlus(word);
    const last = run[run.len - 1];
    if (end < word.len and (last == 'e' or last == 'E') and isJsonNumber(run[0 .. run.len - 1])) return;
    if (run.len == 1) return error.HyphenIsNotAJsonNumber;
    if (run[0] == '0' and std.ascii.isDigit(run[1])) return error.LeadingZeroIsNotAJsonNumber;
    return error.BadNumber;
}

/// In text `+` is reserved; it stands only in the exponent of a number. So a
/// word that starts with a run holding one (see `checkNumber`) needs the run to
/// be a number: `1e+5x` is the number and `x`, `1e+5.x` is an error where
/// `1e5.x` is text. In a key and a `${…}` path too, where nothing else about
/// numbers holds: `1e+5.5 = 1` is an error, `1.5 = 1` a path.
pub fn checkPlus(word: []const u8) NumberError!void {
    if (word.len == 0 or !(std.ascii.isDigit(word[0]) or word[0] == '-')) return;
    const end = std.mem.indexOfNone(u8, word, "0123456789+-.eE") orelse word.len;
    const run = word[0..end];
    if (std.mem.indexOfScalar(u8, run, '+') != null and !isJsonNumber(run)) return error.BadNumber;
}
