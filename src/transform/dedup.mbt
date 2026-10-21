// Dedup: drop items whose text was already seen, keeping first-occurrence order.
//
// This is a `BatchStage` because it *removes* items, which a one-in-one-out
// `Stage` cannot express honestly. It is also stateful: the set of seen texts
// lives in a `mut` field, which is how "already seen" survives from one item
// to the next within a run.
//
// Reuse contract (deliberate, not a defect to fix): a `Dedup` instance is
// single-run state. It remembers what it has dropped, so reusing the same
// instance across pipelines — or calling `run_batch` twice on one instance —
// carries that memory forward and drops text that was only "new" to the first
// run. Construct a fresh `Dedup` per pipeline. If cross-run memory is ever
// wanted, that is a different object with its own clear ownership; silently
// sharing one is how a dedup stage starts hiding items that were never
// duplicates of *this* batch.
//
// Comparison is exact on `text`; `meta` is ignored, because two items with the
// same content but different provenance are the same content for a dedup pass
// — which first one to keep is the first one that arrived, and its meta wins.

///|
/// A whole-list dedup stage.
pub(all) struct Dedup {
  // The seen-set. `mut` because membership grows as items are processed.
  mut seen : Set[String]
} derive(Debug)

///|
/// A fresh, empty dedup stage.
pub fn dedup() -> Dedup {
  { seen: Set([]) }
}

///|
pub impl @pipeline.BatchStage for Dedup with fn name(self : Dedup) -> String {
  let _ = self
  "dedup"
}

///|
pub impl @pipeline.BatchStage for Dedup with fn run_batch(
  self : Dedup,
  items : Array[@pipeline.Item],
) -> Result[Array[@pipeline.Item], @pipeline.StageError] {
  let _ = self
  let out : Array[@pipeline.Item] = []
  for item in items {
    // `add` returns whether it was newly inserted; a re-insert of a present
    // key is the duplicate we drop.
    if self.seen.add_and_check(item.text) {
      out.push(item)
    }
  }
  Ok(out)
}

///|
/// How many distinct texts the instance has admitted — exposed so a test can
/// confirm the memory is real (and therefore that reuse would leak across runs).
pub fn Dedup::admitted(self : Dedup) -> Int {
  self.seen.length()
}
