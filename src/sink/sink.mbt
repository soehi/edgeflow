// Sinks: gather items and render them as JSON.
//
// A sink is any function from `Array[Item]` outward; nothing runs after it, so
// these are plain functions rather than a trait.

///|
/// Collect items into an array, unchanged.
///
/// The identity sink exists so a caller can hand a pipeline's whole run to one
/// function and so the tests have an endpoint that cannot itself introduce a
/// difference worth debugging.
pub fn collect(items : Array[@pipeline.Item]) -> Array[@pipeline.Item] {
  items
}

///|
/// Render items as a JSON array of `{"text": ..., "meta": {...}}` objects.
///
/// Key order in `meta` is the map's iteration order, which is stable for a
/// given construction — callers who compare serialized output should build
/// metadata the same way, not re-sort it here.
pub fn to_json(items : Array[@pipeline.Item]) -> Json {
  Json::array(
    items.map(fn(item) {
      let meta : Map[String, Json] = Map([])
      for k, v in item.meta {
        meta[k] = Json::string(v)
      }
      let obj : Map[String, Json] = Map([])
      obj["text"] = Json::string(item.text)
      obj["meta"] = Json::object(meta)
      Json::object(obj)
    }),
  )
}
