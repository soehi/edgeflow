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
fn item_with(text : String, meta : Array[(String, String)]) -> @pipeline.Item {
  let m : Map[String, String] = Map([])
  for pair in meta {
    let (k, v) = pair
    m[k] = v
  }
  @pipeline.Item::{ text, meta: m }
}

///|
test "count reports the item count" {
  assert_eq(@sink.count(items_of(["a", "b", "c"])), 3)
  assert_eq(@sink.count([]), 0)
}

///|
test "group_by_meta counts by a key, including the missing-key group" {
  let items = [
    item_with("x", [("lang", "en")]),
    item_with("y", [("lang", "zh")]),
    item_with("z", [("lang", "en")]),
    item_with("w", []), // no key: counted under ""
  ]
  let g = @sink.group_by_meta(items, "lang")
  assert_eq(g.get("en"), Some(2))
  assert_eq(g.get("zh"), Some(1))
  assert_eq(g.get(""), Some(1))
}

///|
test "top_k is numeric, descending, stable, and keeps unparsable rows" {
  let items = [
    item_with("two", [("token_count", "2")]),
    item_with("ten", [("token_count", "10")]),
    item_with("nine", [("token_count", "9")]),
    item_with("none", []),
    item_with("bad", [("token_count", "x")]),
  ]
  let top2 = @sink.top_k(items, 2, by="token_count")
  assert_eq(top2.map(fn(i) { i.text }), ["ten", "nine"])
  let all = @sink.top_k(items, 99, by="token_count")
  assert_eq(all.map(fn(i) { i.text }), ["ten", "nine", "two", "none", "bad"])
  assert_eq(@sink.top_k(items, 0, by="token_count").length(), 0)
}

///|
test "to_json renders items plus a summary" {
  let items = [
    item_with("one", [("token_count", "3"), ("lang", "en")]),
    item_with("two", [("token_count", "4"), ("lang", "en")]),
  ]
  let j = @sink.to_json(items, group_by="lang")
  let s = j.stringify()
  // Shape: an object with items and summary, not the old bare array.
  assert_true(s.has_prefix("{\"items\":["))
  assert_true(s.contains("\"summary\":"))
  assert_true(s.contains("\"item_count\":2"))
  assert_true(s.contains("\"total_tokens\":7"))
  assert_true(s.contains("\"groups\":{\"en\":2}"))
}

///|
test "to_json summary reports zero tokens when no stats ran" {
  let s = @sink.to_json(items_of(["a", "b", "c"])).stringify()
  assert_true(s.contains("\"item_count\":3"))
  // No token_count anywhere: the total is honestly 0, not omitted.
  assert_true(s.contains("\"total_tokens\":0"))
  assert_true(s.contains("\"groups\":{}"))
}
