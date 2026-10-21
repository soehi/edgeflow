// Engine-backed inference stage.
//
// One `Item` in, one generated continuation out. This package touches the
// MoonLM `Engine` trait and nothing below it: no model internals, no block
// decoding, no sampler implementation — sampling is a value the stage is
// constructed with.
//
// The `engine` field is a trait reference rather than a concrete
// `PureEngine`: the Engine trait exists exactly so callers and tests can hold
// *an* engine without naming which implementation, and the drift tests
// (src/infer/infer_wbtest.mbt) inject a scripted fake through the same seam the
// example uses for the real one.

///|
/// A pipeline stage that completes the item's text with the model.
pub(all) struct InferStage {
  engine : &@engine.Engine
  max_tokens : Int
  sampler : @sampler.Sampler
}

///|
/// Greedy stage with a token budget.
pub fn InferStage::new(engine : &@engine.Engine, max_tokens : Int) -> InferStage {
  { engine, max_tokens, sampler: @sampler.Greedy }
}

///|
pub impl @pipeline.Stage for InferStage with fn name(self : InferStage) -> String {
  let _ = self
  "infer"
}

///|
pub impl @pipeline.Stage for InferStage with fn run(
  self : InferStage,
  item : @pipeline.Item,
) -> Result[@pipeline.Item, @pipeline.StageError] {
  // Count the prompt in the same encoder the generation will use, so the
  // budget check below is about the same tokens the engine sees.
  let prompt_tokens = match @engine.Engine::encode(self.engine, item.text) {
    Ok(t) => t.length()
    Err(e) =>
      return Err(@pipeline.Failed(
        stage="infer",
        reason="could not encode the prompt: \{e}",
      ))
  }
  let ctx = @engine.Engine::context_length(self.engine)
  // Refuse up front rather than let the engine stop early at the context
  // boundary: a silently short answer reads like a complete one. The message
  // carries both numbers so the caller can decide which to lower.
  if prompt_tokens + self.max_tokens > ctx {
    return Err(@pipeline.Failed(
      stage="infer",
      reason="prompt is \{prompt_tokens} tokens and max_tokens is \{self.max_tokens}, which needs \{prompt_tokens + self.max_tokens} of a context limit of \{ctx}; refusing to truncate",
    ))
  }
  let generated : Array[Int] = []
  // Seed is fixed: greedy ignores it, and a sampling run stays reproducible.
  match @engine.Engine::generate(
    self.engine,
    item.text,
    self.max_tokens,
    self.sampler,
    42UL,
    fn(id, _) { generated.push(id) },
  ) {
    Err(e) =>
      return Err(@pipeline.Failed(
        stage="infer",
        reason="generation failed: \{e}",
      ))
    Ok(_) => ()
  }
  // Decoded once from the full token list: per-token pieces can split a
  // multi-byte character, and a mangled continuation is a silently wrong
  // answer.
  let out_text = match @engine.Engine::decode(self.engine, generated) {
    Ok(t) => t
    Err(e) =>
      return Err(@pipeline.Failed(
        stage="infer",
        reason="decoding the continuation failed: \{e}",
      ))
  }
  let meta : Map[String, String] = Map([])
  for k, v in item.meta {
    meta[k] = v
  }
  meta["generated_tokens"] = generated.length().to_string()
  // The stream is a continuation of the prompt, so the outgoing item carries
  // prompt + continuation: a pipeline that stops here still has a complete
  // string, and a sink that lists items sees the whole text.
  Ok({ text: item.text + out_text, meta })
}
