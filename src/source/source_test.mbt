///|
test "memory_source turns strings into items" {
  let items = memory_source([" alpha ", "beta"])
  assert_eq(items.length(), 2)
  assert_eq(items[0].text, " alpha ")
  assert_true(items[0].meta.is_empty())
}
