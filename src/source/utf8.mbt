// Strict UTF-8 validation, and a decode that reports whether it had to be
// lossy.
//
// The source package reads file bytes and must tag items whose bytes were not
// valid UTF-8, because a lossy decode silently replaces bad bytes with the
// replacement character and downstream consumers cannot otherwise tell a real
// character from a repaired one. Doing the check in MoonBit (rather than
// trusting a C decoder that always succeeds) is what makes the tag honest.
//
// Kept backend-agnostic — it is a pure function over `Bytes` — so it also
// compiles and is testable on wasm-gc, separate from the native file reader
// that calls it.

///|
/// Whether `bytes` is a strictly valid UTF-8 encoding.
///
/// Rejects the cases a permissive decoder might accept: overlong encodings,
/// surrogate code points (D800..DFFF), values above U+10FFFF, and truncated
/// multi-byte sequences at end of input.
pub fn is_valid_utf8(bytes : Bytes) -> Bool {
  let n = bytes.length()
  let mut i = 0
  while i < n {
    let b0 = bytes[i].to_int()
    if b0 <= 0x7F {
      // ASCII: one byte.
      i = i + 1
    } else if b0 >= 0xC2 && b0 <= 0xDF {
      // Two-byte lead. 0xC0/0xC1 are always overlong, so excluded.
      if i + 1 >= n || !is_cont(bytes[i + 1].to_int()) {
        return false
      }
      i = i + 2
    } else if b0 == 0xE0 {
      // Three-byte, but the second byte must be A0..BF to avoid overlongs.
      if i + 2 >= n {
        return false
      }
      let b1 = bytes[i + 1].to_int()
      if b1 < 0xA0 || b1 > 0xBF || !is_cont(bytes[i + 2].to_int()) {
        return false
      }
      i = i + 3
    } else if (b0 >= 0xE1 && b0 <= 0xEC) || b0 == 0xEE || b0 == 0xEF {
      // Three-byte, ordinary range.
      if i + 2 >= n || !is_cont(bytes[i + 1].to_int()) ||
        !is_cont(bytes[i + 2].to_int()) {
        return false
      }
      i = i + 3
    } else if b0 == 0xED {
      // Three-byte lead that must not reach a surrogate: second byte 80..9F.
      if i + 2 >= n {
        return false
      }
      let b1 = bytes[i + 1].to_int()
      if b1 < 0x80 || b1 > 0x9F || !is_cont(bytes[i + 2].to_int()) {
        return false
      }
      i = i + 3
    } else if b0 == 0xF0 {
      // Four-byte, second byte 90..BF to avoid overlong.
      if i + 3 >= n {
        return false
      }
      let b1 = bytes[i + 1].to_int()
      if b1 < 0x90 || b1 > 0xBF || !is_cont(bytes[i + 2].to_int()) ||
        !is_cont(bytes[i + 3].to_int()) {
        return false
      }
      i = i + 4
    } else if b0 >= 0xF1 && b0 <= 0xF4 {
      // Four-byte, up to F4 (F4 max is limited to keep <= 10FFFF).
      if b0 == 0xF4 {
        if i + 3 >= n {
          return false
        }
        let b1 = bytes[i + 1].to_int()
        if b1 > 0x8F || !is_cont(bytes[i + 2].to_int()) ||
          !is_cont(bytes[i + 3].to_int()) {
          return false
        }
      } else {
        if i + 3 >= n || !is_cont(bytes[i + 1].to_int()) ||
          !is_cont(bytes[i + 2].to_int()) || !is_cont(bytes[i + 3].to_int()) {
          return false
        }
      }
      i = i + 4
    } else {
      // A continuation byte where a lead is expected, or 0xF5..0xFF.
      return false
    }
  }
  true
}

///|
/// A UTF-8 continuation byte: 10xxxxxx.
fn is_cont(b : Int) -> Bool {
  b >= 0x80 && b <= 0xBF
}

///|
/// The text plus whether decoding replaced any bytes.
pub(all) struct DecodedText {
  text : String
  lossy : Bool
} derive(Eq, Debug)

///|
/// Decode bytes to text, validating UTF-8 and marking a lossy repair.
///
/// Valid UTF-8 goes through the exact decoder; invalid bytes go through
/// `decode_lossy` (the replacement-character path) with `lossy` set, so the
/// caller both recovers a readable string and records that it is not the file's
/// true content. Never failing here is deliberate: a source that drops a whole
/// file over one bad byte loses more than the byte.
pub fn decode_text(bytes : Bytes) -> DecodedText {
  if is_valid_utf8(bytes) {
    // Validation passed, so decode cannot raise; the try is here because the
    // compiler cannot see that, and a raise must not escape this function.
    let text = try {
      @utf8.decode(bytes.view())
    } catch {
      _ => @utf8.decode_lossy(bytes.view())
    }
    DecodedText::{ text, lossy: false }
  } else {
    DecodedText::{
      text: @utf8.decode_lossy(bytes.view()),
      lossy: true,
    }
  }
}
