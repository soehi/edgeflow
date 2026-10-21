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
/// `Step` is either a single-item stage or a whole-list stage; both are trait
/// objects, first-class in MoonBit (`&Stage` / `&BatchStage`), and the enum is
/// what lets one ordered list mix the two kinds.
pub(all) struct BoxedStage {
  inner : Step
}

///|
/// An ordered list of stages, run synchronously.
///
/// `run` (one item in, one out) and `run_all` (a list in, a list out) share
/// this list; batch stages and item stages compose through it.
pub(all) struct Pipeline {
  stages : Array[BoxedStage]
}

///|
/// An empty pipeline: `run` is the identity.
pub fn Pipeline::new() -> Pipeline {
  { stages: [] }
}

///|
/// Append a single-item stage, returning the pipeline for chaining.
///
/// Mutation in place rather than a copy per `then`: a pipeline is built once
/// and run many times, and copying the stage list at each `then` would be
/// O(n²) construction for no benefit.
pub fn Pipeline::then(self : Pipeline, stage : &Stage) -> Pipeline {
  self.stages.push({ inner: One(stage) })
  self
}

///|
/// Number of stages, for tests and for a caller that wants to report shape.
pub fn Pipeline::stage_count(self : Pipeline) -> Int {
  self.stages.length()
}

///|
/// Run the item through every stage, single-item contract.
///
/// Fails if any stage changes the item count: this entry point promises one
/// item out, and `Dedup` / the chunk stages legitimately do not honour that,
/// so the error points the caller at `run_all` instead of silently returning
/// the first chunk or discarding all but one.
pub fn Pipeline::run(self : Pipeline, item : Item) -> Result[Item, StageError] {
  let many = match self.run_all([item]) {
    Ok(r) => r
    Err(e) => return Err(e)
  }
  match many.length() {
    1 => Ok(many[0])
    n => Err(Failed(
      stage="pipeline",
      reason="\{n} items came out of a single-item run; a batch or chunk stage changed the count — use run_all",
    ))
  }
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

///|
/// A stage that sees the whole item list at once and may return a different
/// number of items.
///
/// `Stage` is one-in, one-out; that cannot express dropping (dedup) or
/// fanning out (chunking) without lying about the count. A batch stage is
/// given every item and returns the transformed list, so 0, 1, and N outputs
/// are all honest. Stages that need to remember what they have already seen
/// across a run — `Dedup` — hold that in a `mut` field and are therefore
/// stateful: an instance must not be reused across pipelines or runs, which
/// the transform package's README states where `Dedup` is defined.
pub(open) trait BatchStage {
  fn name(Self) -> String
  fn run_batch(Self, Array[Item]) -> Result[Array[Item], StageError]
}

///|
/// One position in a pipeline: either a per-item stage or a whole-list stage.
///
/// No `derive(Debug)`: a trait object carries no Debug instance, so the only
/// thing `BoxedStage` can report is that a stage is present.
pub(all) enum Step {
  One(&Stage)
  Many(&BatchStage)
}

///|
/// Apply one `Step` to a list of items.
///
/// A one-item stage maps over the list, keeping order; a batch stage replaces
/// the list wholesale. Failure from any item or batch short-circuits with the
/// step's name attached, so a batch error is located exactly like a single
/// stage error.
fn run_step(step : Step, items : Array[Item]) -> Result[Array[Item], StageError] {
  match step {
    One(stage) => {
      let stage_name = stage.name()
      let out : Array[Item] = []
      for item in items {
        match Stage::run(stage, item) {
          Ok(next) => out.push(next)
          Err(err) =>
            return Err(Failed(stage=stage_name, reason=err_message_body(err)))
        }
      }
      Ok(out)
    }
    Many(batch) => {
      let stage_name = batch.name()
      match BatchStage::run_batch(batch, items) {
        Ok(next) => Ok(next)
        Err(err) =>
          return Err(Failed(stage=stage_name, reason=err_message_body(err)))
      }
    }
  }
}

///|
/// Append a batch stage, returning the pipeline for chaining.
pub fn Pipeline::then_batch(self : Pipeline, stage : &BatchStage) -> Pipeline {
  self.stages.push({ inner: Many(stage) })
  self
}

///|
/// Run every item through every stage.
///
/// This is the whole-list entry point: single-item stages map over the list,
/// batch stages transform it. It is the one that supports dedup and chunking,
/// because those change how many items are in flight.
pub fn Pipeline::run_all(
  self : Pipeline,
  items : Array[Item],
) -> Result[Array[Item], StageError] {
  let mut current = items
  for b in self.stages {
    match run_step(b.inner, current) {
      Ok(next) => current = next
      Err(e) => return Err(e)
    }
  }
  Ok(current)
}
