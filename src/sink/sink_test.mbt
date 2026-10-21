///|
fn items_of(texts : Array[String]) -> Array[@pipeline.Item] {
  texts.map(fn(s) { @pipeline.Item::{ text: s, meta: Map([]) } })
}

///|
test "collect returns the items unchanged" {
  let items = items_of(["a", "b"])
  let out = @sink.collect(items)
  assert_eq(out.length(), 2)
  assert_eq(out[0].text, "a")
}

///|
test "to_json renders text and meta" {
  let j = @sink.to_json(items_of(["one", "two"]))
  assert_eq(
    j.stringify(),
    "[{\"text\":\"one\",\"meta\":{}},{\"text\":\"two\",\"meta\":{}}]",
  )
}
