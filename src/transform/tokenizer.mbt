// Adapting the real MoonLM tokenizer to the injected `TokenCounter`.
//
// `ChunkByTokens` and `token_stats` take a length function, not a tokenizer, so
// the budget logic is testable on every backend without a 49k-entry vocabulary.
// These are the two lines that make the real tokenizer the normal caller's
// counter, keeping the abstraction honest: the same function the tests drive
// with a stand-in is what a pipeline passes `Tokenizer::encode` into.

///|
/// A token counter backed by a real model tokenizer.
pub fn counter_of(tk : @tokenizer.Tokenizer) -> TokenCounter {
  fn(s) { @tokenizer.Tokenizer::encode(tk, s).length() }
}

///|
/// Chunk by tokens using the model's own tokenizer: each piece re-encodes to at
/// most `max` tokens, and pieces break on newlines where the budget allows.
pub fn chunk_by_model(max : Int, tokenizer~ : @tokenizer.Tokenizer) -> ChunkByTokens {
  chunk_by_tokens(max, count=counter_of(tokenizer))
}

///|
/// Token statistics using the model's own tokenizer.
pub fn token_stats_of(tokenizer : @tokenizer.Tokenizer) -> TokenStats {
  token_stats(count=counter_of(tokenizer))
}
