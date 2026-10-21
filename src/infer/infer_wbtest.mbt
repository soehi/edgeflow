// Tests for InferStage, driven by a scripted fake engine.
//
// The Engine trait is the seam: the fake implements the same four methods
// PureEngine does, so these tests exercise exactly the call path the example
// runs against a real model — including the budget refusal and the meta
// bookkeeping — without loading a 138 MB file or inventing logits. Token
// "encoding" here is one token per character, which makes the arithmetic in
// the budget assertions readable.

///|
/// An engine that replies with a fixed continuation and can be told to fail.
struct FakeEngine {
  /// The completion the generate call produces, as "tokens" (chars).
  reply : String
  /// Advertised context window.
  ctx : Int
  /// When set, generate fails with this message.
  fail_with : String?
  mut calls : Int
} derive(Debug)

///|
impl @engine.Engine for FakeEngine with fn encode(
  self : FakeEngine,
  text : String,
) -> Result[Array[Int], String] {
  let _ = self
  Ok(text.to_array().map(fn(_) { 1 }))
}

///|
impl @engine.Engine for FakeEngine with fn decode(
  self : FakeEngine,
  tokens : Array[Int],
) -> Result[String, String] {
  let _ = self
  // Consistent with generate: the number of tokens emitted caps the reply,
  // so a caller cannot see more text than was streamed.
  let end = if tokens.length() < self.reply.length() {
    tokens.length()
  } else {
    self.reply.length()
  }
  Ok(self.reply[:end].to_owned())
}

///|
impl @engine.Engine for FakeEngine with fn context_length(
  self : FakeEngine,
) -> Int {
  self.ctx
}

///|
impl @engine.Engine for FakeEngine with fn generate(
  self : FakeEngine,
  prompt : String,
  max_tokens : Int,
  sampler : @sampler.Sampler,
  seed : UInt64,
  on_token : (Int, String) -> Unit,
) -> Result[@engine.GenerationStats, String] {
  let _ = (prompt, sampler, seed)
  self.calls = self.calls + 1
  match self.fail_with {
    Some(msg) => Err(msg)
    None => {
      // Emit at most max_tokens characters of the reply; decode returns the
      // whole reply, so keep the two consistent by capping here and having
      // decode see the same list length.
      let n = if self.reply.length() < max_tokens {
        self.reply.length()
      } else {
        max_tokens
      }
      for i = 0; i < n; i = i + 1 {
        on_token(i, "")
      }
      Ok({
        prompt_tokens: 0,
        generated_tokens: n,
        hit_eos: false,
        prefill_seconds: 0.0,
        decode_seconds: 0.0,
      })
    }
  }
}

///|
fn stage_with(
  fake : FakeEngine,
  max_tokens : Int,
) -> InferStage {
  InferStage::{ engine: fake, max_tokens, sampler: @sampler.Greedy }
}

///|
test "infer appends the continuation and records generated_tokens" {
  let stage = stage_with(
    FakeEngine::{ reply: "!", ctx: 1000, fail_with: None, calls: 0 },
    16,
  )
  let meta : Map[String, String] = Map([])
  meta["path"] = "notes.md"
  let item = @pipeline.Item::{ text: "hi", meta }
  let out = @pipeline.Stage::run(stage, item).unwrap()
  // Continuation of the prompt, and the incoming meta survived.
  assert_eq(out.text, "hi!")
  assert_eq(out.meta.get("path"), Some("notes.md"))
  assert_eq(out.meta.get("generated_tokens"), Some("1"))
}

///|
test "over-budget prompt is refused before generating, with both numbers" {
  // encode counts characters: "12345" is 5 tokens. Budget is 5 + 10 > 8.
  // generate must not run at all — the refusal is the whole point.
  let fake = FakeEngine::{
    reply: "xxxx",
    ctx: 8,
    fail_with: None,
    calls: 0,
  }
  let stage = stage_with(fake, 10)
  let e = @pipeline.Stage::run(
    stage,
    @pipeline.Item::{ text: "12345", meta: Map([]) },
  ).unwrap_err()
  match e {
    @pipeline.Failed(stage~, reason~) => {
      assert_eq(stage, "infer")
      assert_true(reason.contains("5 tokens"))
      assert_true(reason.contains("10"))
      assert_true(reason.contains("8"))
      assert_true(reason.contains("refusing to truncate"))
    }
  }
  // Exact fit (5 + 3 = 8 = ctx) is allowed; one over is not.
  let stage_fit = stage_with(
    FakeEngine::{ reply: "abc", ctx: 8, fail_with: None, calls: 0 },
    3,
  )
  let _ = @pipeline.Stage::run(
    stage_fit,
    @pipeline.Item::{ text: "12345", meta: Map([]) },
  ).unwrap()
}

///|
test "engine failure becomes a stage error naming infer" {
  let stage = stage_with(
    FakeEngine::{
      reply: "",
      ctx: 1000,
      fail_with: Some("kv cache exploded"),
      calls: 0,
    },
    8,
  )
  let e = @pipeline.Stage::run(
    stage,
    @pipeline.Item::{ text: "go", meta: Map([]) },
  ).unwrap_err()
  match e {
    @pipeline.Failed(stage~, reason~) => {
      assert_eq(stage, "infer")
      assert_true(reason.contains("kv cache exploded"))
    }
  }
}

///|
test "infer composes in a pipeline: trim then infer then collect" {
  let stage = stage_with(
    FakeEngine::{ reply: "?", ctx: 1000, fail_with: None, calls: 0 },
    4,
  )
  let p = @pipeline.Pipeline::new()
    .then(@pipeline.trim_stage())
    .then(stage)
  let out = p.run(@pipeline.Item::{ text: " ok ", meta: Map([]) }).unwrap()
  assert_eq(out.text, "ok?")
  assert_eq(out.meta.get("generated_tokens"), Some("1"))
}
