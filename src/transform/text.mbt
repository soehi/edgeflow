// Single-item text transforms: trim, collapse whitespace, lowercase.
//
// Each one is a `Stage`: one item in, one item out, `meta` carried through
// unchanged. They are functions over text with a name attached, which is what
// makes them composable in a pipeline and reportable in an error.

///|
/// A named text transform run as a single-item stage.
pub(all) struct TextStage {
  stage_name : String
  transform : (String) -> String
} derive(Debug)

///|
pub impl @pipeline.Stage for TextStage with fn name(self : TextStage) -> String {
  self.stage_name
}

///|
pub impl @pipeline.Stage for TextStage with fn run(
  self : TextStage,
  item : @pipeline.Item,
) -> Result[@pipeline.Item, @pipeline.StageError] {
  Ok({ ..item, text: (self.transform)(item.text) })
}

///|
/// Trim leading and trailing whitespace.
pub fn trim() -> TextStage {
  TextStage::{
    stage_name: "trim",
    transform: fn(s) { s.trim().to_owned() },
  }
}

///|
/// Collapse every run of whitespace (spaces, tabs, newlines) to a single
/// space, and trim the ends.
///
/// The trailing trim is part of the contract: a document's final newline
/// would otherwise survive as a lone space, and downstream consumers compare
/// or hash the text.
pub fn collapse_whitespace() -> TextStage {
  TextStage::{
    stage_name: "collapse_whitespace",
    transform: collapse_str,
  }
}

///|
/// The collapse implemented once, reused by tests that need the raw function.
pub fn collapse_str(s : String) -> String {
  let sb = StringBuilder::new()
  let mut in_ws = false
  let mut seen_any = false
  for ch in s {
    if ch.is_whitespace() {
      in_ws = true
    } else {
      if seen_any && in_ws {
        sb.write_char(' ')
      }
      sb.write_char(ch)
      in_ws = false
      seen_any = true
    }
  }
  sb.to_string()
}

///|
/// ASCII lower-case.
///
/// `String::to_lower` folds ASCII letters only; accented and non-Latin
/// characters pass through unchanged (verified by test, not assumed — full
/// Unicode case folding is a locale-table job this skeleton does not carry).
pub fn lowercase() -> TextStage {
  TextStage::{
    stage_name: "lowercase",
    transform: fn(s) { s.to_lower() },
  }
}
