// TokenStats: record token and character counts into an item's meta.
//
// A `Stage` (one-in, one-out): it measures the text it is handed and writes
// the two counts to `meta`, leaving `text` untouched. The token count comes
// from an injected counter for the same reason `ChunkByTokens` takes one — the
// real number needs the model's tokenizer, and a test wants the arithmetic
// without it.

///|
/// A statistics stage that annotates items with their token/char counts.
pub(all) struct TokenStats {
  count : TokenCounter
}

///|
/// A stats stage measuring token length with `count`.
pub fn token_stats(count~ : TokenCounter) -> TokenStats {
  { count, }
}

///|
pub impl @pipeline.Stage for TokenStats with fn name(self : TokenStats) -> String {
  let _ = self
  "token_stats"
}

///|
pub impl @pipeline.Stage for TokenStats with fn run(
  self : TokenStats,
  item : @pipeline.Item,
) -> Result[@pipeline.Item, @pipeline.StageError] {
  let _ = self
  let meta : Map[String, String] = Map([])
  for k, v in item.meta {
    meta[k] = v
  }
  meta["token_count"] = (self.count)(item.text).to_string()
  // Character count, not code-unit count: `String::length` counts UTF-16
  // units, which doubles for astral characters. `to_array().length()` is the
  // number of code points, which is what "characters" means to a reader.
  meta["char_count"] = item.text.to_array().length().to_string()
  Ok({ ..item, meta })
}
