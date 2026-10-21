// Tests for the tokenizer adapter: the real Tokenizer plugged into the
// injected-counter slots, through a tiny vocabulary built from GGUF metadata in
// memory. No model file and no I/O, so this runs on wasm-gc as well.

///|
/// A minimal tokenizer: the words "a", "b", "ab" and the merge "a b" -> "ab",
/// which makes token counts exactly countable by hand.
fn tiny_tokenizer() -> @tokenizer.Tokenizer {
  let metadata : Array[(String, @gguf.MetaValue)] = [
    ("tokenizer.ggml.model", @gguf.Str("gpt2")),
    (
      "tokenizer.ggml.tokens",
      @gguf.Array(
        @gguf.Materialized([
          @gguf.Str("<|endoftext|>"),
          @gguf.Str("a"),
          @gguf.Str("b"),
          @gguf.Str("ab"),
        ]),
      ),
    ),
    (
      "tokenizer.ggml.merges",
      @gguf.Array(@gguf.Materialized([@gguf.Str("a b")])),
    ),
  ]
  let f : @gguf.GgufFile = {
    version: 3U,
    alignment: 32U,
    tensors: [],
    metadata,
    data_start: 0L,
    buf: b"",
  }
  @tokenizer.load(f).unwrap()
}

///|
test "counter_of counts tokens the way the tokenizer does" {
  let tk = tiny_tokenizer()
  let count = @transform.counter_of(tk)
  // "ab" is one vocab token; "a b" merges to it; "aX" keeps a literal `X` byte
  // in its own pieces, so the exact numbers depend on the pre-tokenizer split.
  assert_eq(count("ab"), tk.encode("ab").length())
  assert_eq(count("a b"), tk.encode("a b").length())
  assert_eq(count(""), 0)
}

///|
test "token_stats_of writes real token counts" {
  let tk = tiny_tokenizer()
  let out = @pipeline.Pipeline::new()
    .then(@transform.token_stats_of(tk))
    .run(@pipeline.Item::{ text: "ab", meta: Map([]) })
    .unwrap()
  // "ab" encodes to the single vocab token, and the meta records it.
  assert_eq(out.meta.get("token_count"), Some("1"))
  assert_eq(out.meta.get("char_count"), Some("2"))
}

///|
test "chunk_by_model keeps every piece within the tokenizer's budget" {
  let tk = tiny_tokenizer()
  // Budget of 1 token per piece over "ab ab ab": each "ab" is one token, so
  // three pieces come out, none over budget, and reassembly is exact.
  let stage = @transform.chunk_by_model(1, tokenizer=tk)
  let pieces = @pipeline.BatchStage::run_batch(
    stage,
    [@pipeline.Item::{ text: "ab ab ab", meta: Map([]) }],
  ).unwrap()
  assert_true(pieces.length() >= 3)
  for p in pieces {
    let n = @tokenizer.Tokenizer::encode(tk, p.text).length()
    if n > 1 {
      fail("piece over budget (\{n}): <\{p.text}>")
    }
  }
  assert_eq(pieces.map(fn(p) { p.text }).join(""), "ab ab ab")
}
