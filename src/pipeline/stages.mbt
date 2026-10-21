// Stages over `Item`: one `text` transform plus a `meta` writer.
//
// The text transform is any function from String to String — the same type
// works for trimming, case mapping and search-replace — so no per-transform
// trait is needed; the struct is where the "what stage is this" name lives.

///|
/// A named text transform, run as a pipeline stage.
pub(all) struct TextStage {
  stage_name : String
  transform : (String) -> String
} derive(Debug)

///|
pub impl Stage for TextStage with fn name(self : TextStage) -> String {
  self.stage_name
}

///|
pub impl Stage for TextStage with fn run(
  self : TextStage,
  item : Item,
) -> Result[Item, StageError] {
  let _ = self
  Ok({ ..item, text: (self.transform)(item.text) })
}

///|
/// Trim leading and trailing whitespace.
pub fn trim_stage() -> TextStage {
  TextStage::{ stage_name: "trim", transform: fn(s) { s.trim().to_owned() } }
}

///|
/// ASCII upper-case.
///
/// ASCII only rather than locale-aware case folding: the pipeline's jobs are
/// identifiers and ASCII text, and a full Unicode case table is a dependency
/// this skeleton has no reason to carry.
pub fn uppercase_stage() -> TextStage {
  TextStage::{ stage_name: "uppercase", transform: fn(s) { s.to_upper() } }
}

///|
/// Replace one literal substring everywhere it occurs.
pub fn replace_stage(
  old~ : String,
  new~ : String,
  name~ : String = "replace",
) -> TextStage {
  TextStage::{
    stage_name: name,
    transform: fn(s) { s.replace_all(old=old, new=new) },
  }
}

///|
/// A stage that always fails, to exercise short-circuiting.
///
/// Public because the source and sink packages use it in their own tests; a
/// test helper every package re-implements is how tests drift.
pub(all) struct FailStage {
  stage_name : String
  reason : String
  /// Bumped on each invocation so a test can assert a later stage never ran.
  hits : Ref[Int]
} derive(Debug)

///|
/// A stage named `name` whose run always fails with `reason`.
pub fn fail_stage(name~ : String, reason~ : String) -> FailStage {
  { stage_name: name, reason, hits: Ref(0) }
}

///|
pub impl Stage for FailStage with fn name(self : FailStage) -> String {
  self.stage_name
}

///|
pub impl Stage for FailStage with fn run(
  self : FailStage,
  item : Item,
) -> Result[Item, StageError] {
  let _ = item
  self.hits.val = self.hits.val + 1
  Err(Failed(stage=self.stage_name, reason=self.reason))
}

///|
/// How many times the stage ran.
pub fn FailStage::run_count(self : FailStage) -> Int {
  self.hits.val
}
