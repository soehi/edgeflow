// UTF-8 validation tests. Backend-agnostic (pure function over Bytes), so
// these run on wasm-gc too, unlike the file sources.

///|
fn bs(v : Array[Int]) -> Bytes {
  Bytes::from_array(v.map(fn(x) { x.to_byte() })[:])
}

///|
test "valid sequences accept" {
  assert_true(is_valid_utf8(bs([0x41]))) // A
  assert_true(is_valid_utf8(bs([0xC3, 0xA9]))) // é
  assert_true(is_valid_utf8(bs([0xE4, 0xBD, 0xA0]))) // 你
  assert_true(is_valid_utf8(bs([0xF0, 0x9F, 0x98, 0x80]))) // 😀 (U+1F600)
  assert_true(is_valid_utf8(bs([0xED, 0x9F, 0xBF]))) // U+D7FF, just below surrogates
  assert_true(is_valid_utf8(bs([0xEE, 0x80, 0x80]))) // U+E000, just above
  assert_true(is_valid_utf8(bs([0xF4, 0x8F, 0xBF, 0xBF]))) // U+10FFFF, max
  assert_true(is_valid_utf8(bs([]))) // empty is valid
}

///|
test "invalid sequences reject" {
  // Lone continuation byte.
  assert_false(is_valid_utf8(bs([0x80])))
  // Truncated two-byte.
  assert_false(is_valid_utf8(bs([0xC3])))
  // Overlong encoding of '/' (would be accepted by careless decoders).
  assert_false(is_valid_utf8(bs([0xC0, 0xAF])))
  assert_false(is_valid_utf8(bs([0xE0, 0x80, 0x80])))
  // Surrogate D800 encodes as ED A0 80: must be rejected.
  assert_false(is_valid_utf8(bs([0xED, 0xA0, 0x80])))
  // Above U+10FFFF: F5 80 80 80.
  assert_false(is_valid_utf8(bs([0xF5, 0x80, 0x80, 0x80])))
  assert_false(is_valid_utf8(bs([0xFF, 0xFE, 0x78]))) // the fixture's junk
  // Truncated mid-sequence at end of input.
  assert_false(is_valid_utf8(bs([0xE4, 0xBD])))
  // Bad continuation byte inside a valid lead.
  assert_false(is_valid_utf8(bs([0xC2, 0x41])))
}

///|
test "decode_text reports lossiness honestly" {
  let good = decode_text(bs([0xF0, 0x9F, 0x98, 0x80]))
  assert_eq(good.text, "😀")
  assert_false(good.lossy)

  let bad = decode_text(bs([0xFF, 0xFE, 0x78]))
  // Lossy repair produced *a* string (replacement chars) — but the flag says
  // it is not the file's true content.
  assert_true(bad.lossy)
  assert_true(bad.text.length() > 0)
}
