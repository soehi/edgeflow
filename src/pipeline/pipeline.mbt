// Pipeline stages: a single item type, one trait, ordered composition.
//
// This package owns the shape of the problem — an `Item` moving through a
// sequence of `Stage`s — and nothing else. Sources and sinks live in sibling
// packages and are just functions over these types, which keeps the core free
// of any notion of where items come from or where they go.

///|
/// One unit of work: text plus string metadata.
///
/// Deliberately not generic. The pipeline's whole value is that a stage can
/// run after any other stage because they all speak the same type; a type
/// parameter would turn that composition check into a per-pairing concern and
/// is not earned by anything this skeleton has to express. If a future stage
/// genuinely needs structured payloads, `meta` is the escape hatch and the
/// `text` field is where a serialization goes.
pub(all) struct Item {
  text : String
  meta : Map[String, String]
} derive(Eq, Debug)

///|
/// A stage failed.
///
/// `stage` is the name of the stage that failed, filled in by the pipeline
/// rather than by the stage itself: a stage reports why, the pipeline adds
/// which, so the error a caller sees always names the stage even when the
/// stage's own error text does not.
pub(all) suberror StageError {
  Failed(stage~ : String, reason~ : String)
} derive(Eq, Debug)

///|
pub fn StageError::message(self : StageError) -> String {
  match self {
    Failed(stage~, reason~) => "stage \"\{stage}\" failed: \{reason}"
  }
}

///|
pub impl Show for StageError with fn to_string(self : StageError) {
  self.message()
}

///|
/// One step of a pipeline.
///
/// A stage transforms one `Item` and may fail; it cannot drop the item or
/// emit more than one, which is what makes `Pipeline::run` a straight loop
/// rather than a scheduler.
pub(open) trait Stage {
  fn name(self : Self) -> String
  fn run(self : Self, item : Item) -> Result[Item, StageError]
}

///|
/// A stage held by a pipeline.
///
/// A struct wrapping a trait reference: trait objects are first-class in
/// MoonBit (`&Stage`), but naming the field keeps the array's element type
/// explicit and gives the Debug instance a stable shape.
pub(all) struct BoxedStage {
  inner : &Stage
}

///|
/// An ordered list of stages, run synchronously.
///
/// `run` feeds the item through each stage in order and stops at the first
/// failure: later stages never see an item that did not get through the
/// earlier one, which is what the error tests assert.
pub(all) struct Pipeline {
  stages : Array[BoxedStage]
}

///|
/// An empty pipeline: `run` is the identity.
pub fn Pipeline::new() -> Pipeline {
  { stages: [] }
}

///|
/// Append a stage, returning the pipeline for chaining.
///
/// Mutation in place rather than a copy per `then`: a pipeline is built once
/// and run many times, and copying the stage list at each `then` would be
/// O(n²) construction for no benefit.
pub fn Pipeline::then(self : Pipeline, stage : &Stage) -> Pipeline {
  self.stages.push({ inner: stage })
  self
}

///|
/// Number of stages, for tests and for a caller that wants to report shape.
pub fn Pipeline::stage_count(self : Pipeline) -> Int {
  self.stages.length()
}

///|
/// Run the item through every stage in order.
///
/// On failure the error names the stage (from the stage's own `name`, taken
/// before running it, so a stage that fails without saying where is still
/// located) and the run stops — stages after the failure do not execute.
pub fn Pipeline::run(self : Pipeline, item : Item) -> Result[Item, StageError] {
  let mut current = item
  for b in self.stages {
    let stage = b.inner
    // Asked before `run`: if a stage fails, its name is already known.
    let stage_name = stage.name()
    match Stage::run(stage, current) {
      Ok(next) => current = next
      Err(err) =>
        return Err(Failed(
          stage=stage_name,
          reason=err_message_body(err),
        ))
    }
  }
  Ok(current)
}

///|
/// The reason text of a stage error.
///
/// StageError is the only error type in this interface, so a stage's `Err`
/// already carries a reason; this strips the failing stage's own name
/// annotation — the pipeline supplies the authoritative one — and keeps the
/// message body.
fn err_message_body(err : StageError) -> String {
  match err {
    Failed(reason~, ..) => reason
  }
}
