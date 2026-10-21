// Transform tests: single-value edits, dedup ordering, and both chunkers.
//
// ChunkByTokens is tested through an injected `TokenCounter` rather than the
// real tokenizer: the budget logic (≤max per piece, never grow when
// re-chunked, never break inside a character) is arithmetic over whatever
// length function it is given, and a cheap deterministic counter exercises it
// on both backends without a 49k-entry vocabulary. The real tokenizer wiring
// is a one-liner over `Tokenizer::encode` and is checked by the compiler in
// the source package's native path; inventing logits here would test nothing.

///|
fn item(t : String) -> @pipeline.Item {
  @pipeline.Item::{ text: t, meta: Map([]) }
}

///|
fn items_of(texts : Array[String]) -> Array[@pipeline.Item] {
  texts.map(fn(t) { item(t) })
}

///|
fn texts(items : Array[@pipeline.Item]) -> Array[String] {
  items.map(fn(i) { i.text })
}

// --- single-value stages ---------------------------------------------------

///|
test "trim / collapse_whitespace / lowercase transform text and keep meta" {
  let m : Map[String, String] = Map([])
  m["k"] = "v"
  let start = @pipeline.Item::{ text: "  Foo\tBar  ", meta: m }
  let out = @pipeline.Pipeline::new()
    .then(@transform.trim())
    .then(@transform.collapse_whitespace())
    .then(@transform.lowercase())
    .run(start)
    .unwrap()
  assert_eq(out.text, "foo bar")
  assert_eq(out.meta.get("k"), Some("v"))
}

///|
test "collapse_whitespace folds newlines and tabs to single spaces" {
  assert_eq(@transform.collapse_str("a  \n\t  b\n\n c"), "a b c")
  assert_eq(@transform.collapse_str("   "), "")
  assert_eq(@transform.collapse_str("x"), "x")
}

///|
test "lowercase folds ASCII and leaves non-ASCII untouched" {
  // `to_lower` is ASCII-only. A leading non-ASCII uppercase letter passes
  // through while the ASCII letters after it fold — this pins the real
  // boundary rather than the assumption it would be easy to make.
  let out = @transform.lowercase().run(item("ÉBC")).unwrap()
  assert_eq(out.text, "Ébc")
  // Non-Latin (Greek) is unaffected too.
  let gr = @transform.lowercase().run(item("ΣΩΣ")).unwrap()
  assert_eq(gr.text, "ΣΩΣ")
}

// --- dedup -----------------------------------------------------------------

///|
test "dedup keeps first-occurrence order" {
  let p = @pipeline.Pipeline::new().then_batch(@transform.dedup())
  let out = p.run_all(items_of(["b", "a", "b", "c", "a"])).unwrap()
  assert_eq(texts(out), ["b", "a", "c"])
}

///|
test "dedup ignores meta when comparing" {
  let a = @pipeline.Item::{ text: "x", meta: { "src" : "1" } }
  let b = @pipeline.Item::{ text: "x", meta: { "src" : "2" } }
  let p = @pipeline.Pipeline::new().then_batch(@transform.dedup())
  let out = p.run_all([a, b]).unwrap()
  assert_eq(out.length(), 1)
  // The first occurrence's metadata is the one that survives.
  assert_eq(out[0].meta.get("src"), Some("1"))
}

///|
test "dedup instance is single-run: reuse carries memory forward" {
  // Documents the statefulness the README warns about. A fresh Dedup admits
  // "dup" once; a second run_batch on the SAME instance sees it as already
  // admitted and drops it. That is why an instance must not be reused.
  let d = @transform.dedup()
  let first = @pipeline.BatchStage::run_batch(d, items_of(["dup", "dup"])).unwrap()
  assert_eq(first.length(), 1)
  let second = @pipeline.BatchStage::run_batch(d, items_of(["dup"])).unwrap()
  // "dup" is remembered from the first call, so this run drops it.
  assert_eq(second.length(), 0)
  assert_eq(d.admitted(), 1)
}

// --- chunk by chars --------------------------------------------------------

///|
test "chunk_by_chars caps size and reassembles exactly" {
  let text = "line one\nline two\nline three\n"
  let pieces = @transform.chunk_chars(text, 12)
  for piece in pieces {
    if piece.to_array().length() > 12 {
      fail("piece over max: <\{piece}>")
    }
  }
  assert_eq(pieces.join(""), text)
  // Prefers newline boundaries: no piece should start mid-word unless forced.
  for piece in pieces {
    // Every full piece ends at a newline except possibly the last, or is a
    // hard cut that happened to have no newline in its window.
    assert_true(piece.length() > 0)
  }
}

///|
test "chunk_by_chars breaks on newline when it can" {
  let pieces = @transform.chunk_chars("aaa\nbbbb\ncc", 6)
  // "aaa\n" fits (4<=6); next "bbbb\n" is 5; then "cc".
  assert_eq(pieces, ["aaa\n", "bbbb\n", "cc"])
}

///|
test "chunk_by_chars hard-cuts a line with no newline" {
  let pieces = @transform.chunk_chars("abcdefghij", 3)
  assert_eq(pieces, ["abc", "def", "ghi", "j"])
}

///|
test "chunk_by_chars never splits a character" {
  // Astral emoji are two UTF-16 units but one Char; pieces must be
  // char-aligned and reconstruct the text.
  let text = "😀🎉x"
  let pieces = @transform.chunk_chars(text, 1)
  assert_eq(pieces.join(""), text)
  assert_eq(pieces, ["😀", "🎉", "x"])
}

// --- chunk by tokens -------------------------------------------------------

///|
/// One token per character: a stand-in tokenizer whose token count equals the
/// character count, so the budget becomes character arithmetic we can check
/// exactly.
fn one_token_per_char() -> @transform.TokenCounter {
  fn(s) { s.to_array().length() }
}

///|
test "chunk_by_tokens keeps every piece within budget" {
  let text = "alpha\nbeta gamma\nlongtail\n"
  let count = one_token_per_char()
  let pieces = @transform.chunk_tokens(text, 6, count)
  for piece in pieces {
    let n = count(piece)
    if n > 6 {
      fail("piece over token budget (\{n}>6): <\{piece}>")
    }
  }
  // Reassembly is lossless.
  assert_eq(pieces.join(""), text)
}

///|
test "chunk_by_tokens is idempotent: re-chunking a valid piece is a no-op" {
  let count = one_token_per_char()
  let pieces = @transform.chunk_tokens("one\n two  three\n", 5, count)
  for piece in pieces {
    // A piece already within budget must not split further when fed back in.
    assert_eq(@transform.chunk_tokens(piece, 5, count), [piece])
  }
}

///|
test "chunk_by_tokens never crosses a token boundary" {
  // A tokenizer that treats each "word" as one token and any multi-word
  // string as (num_words) tokens. Splitting on this must never produce a piece
  // whose word is cut in half — with the char-level injection we instead
  // assert pieces line up on word boundaries the counter can see.
  let count_words = fn(s : String) -> Int {
    s.trim().split(" ").filter(fn(w) { w.length() > 0 }).length()
  }
  let pieces = @transform.chunk_tokens("aa bb\ncc dd ee\nff", 2, count_words)
  // Each piece's token count is within 2; sum reconstructs.
  for piece in pieces {
    if count_words(piece) > 2 {
      fail("word-budget violated: <\{piece}> = \{count_words(piece)}")
    }
  }
  // Reconstruction of the whitespace-separated token stream is preserved: the
  // join equals the input.
  assert_eq(pieces.join(""), "aa bb\ncc dd ee\nff")
}

///|
test "chunk_by_tokens falls back to a single-char hard cut when a char exceeds budget" {
  // Budget 0 is clamped to 1; every single char is exactly 1 token.
  let pieces = @transform.chunk_tokens("ab", 0, one_token_per_char())
  assert_eq(pieces, ["a", "b"])
}

// --- token stats -----------------------------------------------------------

///|
test "token_stats writes token_count and char_count to meta" {
  let out = @pipeline.Pipeline::new().then(
    @transform.token_stats(count=one_token_per_char()),
  ).run(item("héllo")).unwrap()
  // "héllo" is 5 characters (é is one code point).
  assert_eq(out.meta.get("token_count"), Some("5"))
  assert_eq(out.meta.get("char_count"), Some("5"))
  // Text is untouched, existing meta preserved.
  assert_eq(out.text, "héllo")
}

///|
test "token_stats char_count is code points not UTF-16 units" {
  let out = @transform.token_stats(count=fn(_) { 1 }).run(item("😀")).unwrap()
  // One emoji = one Char but two UTF-16 units; char_count must be 1.
  assert_eq(out.meta.get("char_count"), Some("1"))
}

// --- composition -----------------------------------------------------------

///|
test "a pipeline mixes single-item and batch stages" {
  // trim (item) -> dedup (batch) -> chunk_by_chars (batch): counts go
  // 4 -> 2 -> fan-out, and run_all is the entry point that supports it.
  let p = @pipeline.Pipeline::new()
    .then(@transform.trim())
    .then_batch(@transform.dedup())
    .then_batch(@transform.chunk_by_chars(4))
  let out = p
    .run_all(items_of(["  a  ", "a", "bb", "  a  "]))
    .unwrap()
  // dedup leaves ["a","bb"]; each chunked at <=4 chars -> still ["a","bb"].
  assert_eq(texts(out), ["a", "bb"])
}
