// Pipeline tests: happy path, error short-circuit, and stage naming.
//
// The stages under test are the in-package fakes (trim, uppercase, the
// always-failing stage); they exist only so the pipeline's composition and
// error semantics can be checked without any real transform or I/O.

///|
fn item(text : String) -> @pipeline.Item {
  @pipeline.Item::{ text, meta: Map([]) }
}

///|
test "memory -> trim -> uppercase -> collect runs end to end" {
  let p = @pipeline.Pipeline::new().then(@pipeline.trim_stage()).then(@pipeline.uppercase_stage())
  assert_eq(p.stage_count(), 2)
  let out = p.run(item("  hello world  ")).unwrap()
  assert_eq(out.text, "HELLO WORLD")
}

///|
test "a stage preserves the item's metadata" {
  let m : Map[String, String] = Map([])
  m["origin"] = "memory"
  let start = @pipeline.Item::{ text: "  pad  ", meta: m }
  let out = @pipeline.Pipeline::new().then(@pipeline.trim_stage()).run(start).unwrap()
  assert_eq(out.meta.get("origin"), Some("memory"))
}

///|
test "empty pipeline is the identity" {
  let out = @pipeline.Pipeline::new().run(item("as is")).unwrap()
  assert_eq(out.text, "as is")
}

///|
test "the second stage failing stops the third and names the failure" {
  // A reference to the last stage's hit counter, so the test can prove the
  // third stage's `run` was never called, not just that its output is absent.
  let third = @pipeline.fail_stage(name="third", reason="should not run")
  let p = @pipeline.Pipeline::new()
    .then(@pipeline.trim_stage())
    .then(@pipeline.fail_stage(name="second", reason="boom"))
    .then(third)
  match p.run(item("  x  ")) {
    Ok(_) => fail("expected the pipeline to fail")
    Err(e) =>
      match e {
        @pipeline.Failed(stage~, reason~) => {
          assert_eq(stage, "second")
          assert_eq(reason, "boom")
        }
      }
  }
  // The short-circuit is real: the stage after the failure never executed.
  assert_eq(third.run_count(), 0)
}

///|
test "the failing stage's name is reported even if the stage omits it" {
  // A stage whose error text does not repeat its name is still located,
  // because the pipeline reads `name()` before running it.
  let p = @pipeline.Pipeline::new().then(@pipeline.fail_stage(name="solo", reason="only a reason"))
  match p.run(item("x")) {
    Ok(_) => fail("expected failure")
    Err(e) =>
      match e {
        @pipeline.Failed(stage~, ..) => assert_eq(stage, "solo")
      }
  }
}

///|
test "replace stage rewrites text" {
  let p = @pipeline.Pipeline::new().then(@pipeline.replace_stage(old="foo", new="bar"))
  assert_eq(p.run(item("foo and foo")).unwrap().text, "bar and bar")
}

///|
test "StageError message names the stage and reason" {
  let e = @pipeline.Failed(stage="k", reason="r")
  assert_eq(e.message(), "stage \"k\" failed: r")
}
