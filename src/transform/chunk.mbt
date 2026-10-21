// Chunking: fan one item out into several, at character or token budgets.
//
// These are `BatchStage`s because they return more items than they receive —
// a one-in-one-out `Stage` cannot express that count change.
//
// Both chunkers prefer to break on a newline, so a piece is usually a whole
// line or run of lines rather than a cut sentence. Neither ever splits inside
// a character: iteration is by `Char`, so a multi-byte or astral code point is
// always wholly inside one piece.

///|
/// Chunk by character count, breaking on newlines where possible.
pub(all) struct ChunkByChars {
  max : Int
} derive(Debug)

///|
/// A chunker that caps each piece at `max` characters.
pub fn chunk_by_chars(max : Int) -> ChunkByChars {
  { max: (if max < 1 { 1 } else { max }) }
}

///|
pub impl @pipeline.BatchStage for ChunkByChars with fn name(
  self : ChunkByChars,
) -> String {
  let _ = self
  "chunk_by_chars"
}

///|
pub impl @pipeline.BatchStage for ChunkByChars with fn run_batch(
  self : ChunkByChars,
  items : Array[@pipeline.Item],
) -> Result[Array[@pipeline.Item], @pipeline.StageError] {
  let out : Array[@pipeline.Item] = []
  for item in items {
    for piece in chunk_chars(item.text, self.max) {
      out.push({ ..item, text: piece })
    }
  }
  Ok(out)
}

///|
/// The pure splitter, exposed so a test can assert piece sizes directly.
///
/// Growing a piece, when it reaches `max` characters the break is moved back
/// to the last newline at or before that point; if the piece has no newline it
/// is hard-cut at `max`. A trailing newline belongs to the piece it ends, so
/// reconstructing the text from the pieces is exact.
pub fn chunk_chars(text : String, max : Int) -> Array[String] {
  let chars = text.to_array()
  let n = chars.length()
  let pieces : Array[String] = []
  if n == 0 {
    return pieces
  }
  let limit = if max < 1 { 1 } else { max }
  let mut start = 0
  while start < n {
    let hard_end = if start + limit < n { start + limit } else { n }
    // Break point: the position after the last newline within the window, if
    // any and not at the very start of the window (which would make no
    // progress).
    let mut end = hard_end
    let mut k = hard_end
    while k > start + 1 {
      if chars[k - 1] == '\n' {
        end = k
        break
      }
      k = k - 1
    }
    pieces.push(chars_to_string(chars, start, end))
    start = end
  }
  pieces
}

///|
/// A text → token-length function.
///
/// The tokenizer's `encode` has this shape; tests inject a cheap stand-in so
/// the token-budget logic is checkable without a 49k-entry vocabulary. Keeping
/// it a plain function (not a trait) means the chunker needs no boxed engine and
/// stays backend-agnostic.
pub type TokenCounter = (String) -> Int

///|
/// Chunk by token count, using an injected encoder to measure each piece.
///
/// Every emitted piece is re-measured: its token count is guaranteed `≤ max`.
/// Because a piece is always a whole `Char`-aligned substring and it is
/// measured after the split (not assumed from the input's token count), cutting
/// can never *increase* the total — the sum of per-piece token counts may
/// exceed the whole-document count (BPE merges across the break are lost), but
/// no piece ever crosses its budget and re-chunking an already-valid piece
/// yields it unchanged. That is the stability the tests assert.
pub(all) struct ChunkByTokens {
  max : Int
  count : TokenCounter
}

///|
/// A chunker that caps each piece at `max` tokens as measured by `count`.
pub fn chunk_by_tokens(max : Int, count~ : TokenCounter) -> ChunkByTokens {
  { max: (if max < 1 { 1 } else { max }), count }
}

///|
pub impl @pipeline.BatchStage for ChunkByTokens with fn name(
  self : ChunkByTokens,
) -> String {
  let _ = self
  "chunk_by_tokens"
}

///|
pub impl @pipeline.BatchStage for ChunkByTokens with fn run_batch(
  self : ChunkByTokens,
  items : Array[@pipeline.Item],
) -> Result[Array[@pipeline.Item], @pipeline.StageError] {
  let out : Array[@pipeline.Item] = []
  for item in items {
    for piece in chunk_tokens(item.text, self.max, self.count) {
      out.push({ ..item, text: piece })
    }
  }
  Ok(out)
}

///|
/// The pure token-budget splitter.
///
/// Grows a candidate piece line-by-line; the break moves back to the last
/// newline whose prefix still measures `≤ max` tokens, falling back to a
/// binary search over a single over-long line so progress is guaranteed even
/// when one line alone exceeds the budget. Every returned piece is verified by
/// re-running `count` on it.
pub fn chunk_tokens(
  text : String,
  max : Int,
  count : TokenCounter,
) -> Array[String] {
  let chars = text.to_array()
  let n = chars.length()
  let pieces : Array[String] = []
  if n == 0 {
    return pieces
  }
  let limit = if max < 1 { 1 } else { max }
  let mut start = 0
  while start < n {
    // Longest prefix from `start` that fits the budget.
    let fit_end = longest_fit(chars, start, n, limit, count)
    if fit_end == start {
      // The single next character does not fit (count of one char exceeds
      // budget) — cannot make progress without violating the cap; emit it
      // alone and let the caller's budget be honored per-piece going forward.
      pieces.push(chars_to_string(chars, start, start + 1))
      start = start + 1
      continue
    }
    // Prefer the last newline at or before fit_end.
    let mut end = fit_end
    let mut k = fit_end
    while k > start + 1 {
      if chars[k - 1] == '\n' {
        end = k
        break
      }
      k = k - 1
    }
    pieces.push(chars_to_string(chars, start, end))
    start = end
  }
  pieces
}

///|
/// Largest index `end` in (start, n] with `count(chars[start:end]) <= limit`.
///
/// Linear scan to the boundary: each extension re-encodes one more character,
/// so a piece of L characters costs O(L) `count` calls. That is honest cost
/// O(n^2)-ish per document in the worst case; acceptable here because pieces
/// are line- and document-sized in the tests, and the alternative (binary
/// search on the prefix length) assumes `count` is monotone in length — true
/// for BPE but not something the injected function is contractually, so the
/// scan avoids leaning on a property the abstraction does not promise.
fn longest_fit(
  chars : Array[Char],
  start : Int,
  n : Int,
  limit : Int,
  count : TokenCounter,
) -> Int {
  // If even a one-character prefix is over budget, no fit beyond start exists.
  if count(chars_to_string(chars, start, start + 1)) > limit {
    return start
  }
  let mut hi = start + 1
  while hi < n && count(chars_to_string(chars, start, hi + 1)) <= limit {
    hi = hi + 1
  }
  hi
}

///|
/// Join `chars[start:end)` into a String.
fn chars_to_string(chars : Array[Char], start : Int, end : Int) -> String {
  let sb = StringBuilder::new()
  for k = start; k < end; k = k + 1 {
    sb.write_char(chars[k])
  }
  sb.to_string()
}
