//! What a number is, for the parser (`checkPlus`) and for JSON output
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

/// `LeadingZeroIsNotAJsonNumber` and `HyphenIsNotAJsonNumber` are no longer
/// returned: `01` and `-foo` are text now. They stay in the set so a switch
/// over these errors keeps compiling.
pub const NumberError = error{ LeadingZeroIsNotAJsonNumber, HyphenIsNotAJsonNumber, BadNumber };

/// A word that is a JSON number is a number, and any other word is text (spec
/// L250, decided 2026-10-24/25). A word that starts with a digit starts with
/// the characters JSON reads as a number (`1.2` of `1.2.3`, `0` of `01`, `5` of
/// `5EB`), and what follows is text after it, as `10.0bar` is the number `10.0`
/// then `bar` (L260). So `127.0.0.1`, `1.2.3`, `01` and `1e` are text, which
/// the spec needs: `1.2.3` as a key is the path `1`, `2`, `3` (L502), and a key
/// is written as a value is (L478). A `-` begins no number before anything but
/// a digit, so `-foo`, `-` and `-.5` are text by L250 too.
///
/// What is left is `+`: in text it is reserved (L245), it stands only in the
/// exponent of a number. So a `+` has to be inside the number JSON reads at
/// the start of the word: `1e+5.x` is the number `1e+5` then `.x`, text as
/// `10.0bar` is (decided 2026-10-25), and `1e+5e+5` and `-.5e+1` are errors,
/// the first with its `+` after the number, the second with no number at all.
/// In a key and a `${…}` path too: `1e+5.5 = 1` is the path `1e+5`, `5`.
pub fn checkPlus(word: []const u8) NumberError!void {
    if (word.len == 0 or !(std.ascii.isDigit(word[0]) or word[0] == '-')) return;
    const end = std.mem.indexOfNone(u8, word, "0123456789+-.eE") orelse word.len;
    const run = word[0..end];
    // The number JSON reads there: the longest start of the run that is one.
    var number = run.len;
    while (number > 0 and !isJsonNumber(run[0..number])) number -= 1;
    if (std.mem.indexOfScalar(u8, run[number..], '+') != null) return error.BadNumber;
}
