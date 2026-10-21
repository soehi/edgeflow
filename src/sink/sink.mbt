// Sinks: gather items, aggregate them, and render as JSON.
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
/// How many items there are.
pub fn count(items : Array[@pipeline.Item]) -> Int {
  items.length()
}

///|
/// Count items by the value of one metadata key.
///
/// Items that lack the key are counted under the empty string rather than
/// dropped: "how many items have no group" is a real answer, and silently
/// omitting them would make the grouped total disagree with the item count.
pub fn group_by_meta(
  items : Array[@pipeline.Item],
  key : String,
) -> Map[String, Int] {
  let groups : Map[String, Int] = Map([])
  for item in items {
    let g = item.meta.get(key).unwrap_or("")
    let n = groups.get(g).unwrap_or(0)
    groups[g] = n + 1
  }
  groups
}

///|
/// The `k` items with the largest numeric value of `meta[key]`.
///
/// Numeric, not lexicographic: `"10"` must outrank `"9"`, so values are parsed
/// as integers. An item whose value is missing or not an integer scores 0 and
/// stays in the result rather than vanishing — a ranking that silently drops
/// rows is hard to trust. Ties keep input order (`sort_by` is stable).
pub fn top_k(
  items : Array[@pipeline.Item],
  k : Int,
  by~ : String = "token_count",
) -> Array[@pipeline.Item] {
  if k <= 0 {
    return []
  }
  let scored = items.map(fn(item) {
    (parse_meta_int(item.meta.get(by).unwrap_or("")), item)
  })
  scored.sort_by(fn(a, b) {
    let (sa, _) = a
    let (sb, _) = b
    if sa > sb {
      -1
    } else if sa < sb {
      1
    } else {
      0
    }
  })
  let out : Array[@pipeline.Item] = []
  for i = 0; i < k && i < scored.length(); i = i + 1 {
    let (_, item) = scored[i]
    out.push(item)
  }
  out
}

///|
/// Parse a metadata value as an integer, defaulting to 0.
fn parse_meta_int(s : String) -> Int {
  let t = s.trim()
  if t == "" {
    return 0
  }
  try {
    @string.parse_int(t[:])
  } catch {
    _ => 0
  }
}

///|
/// Total `token_count` across items, ignoring items that do not carry it.
///
/// Reported next to the item count so a reader can tell "10 items, 0 tokens"
/// (no token stats ran) from "10 items, 400 tokens".
pub fn total_tokens(items : Array[@pipeline.Item]) -> Int {
  let mut sum = 0
  for item in items {
    sum = sum + parse_meta_int(item.meta.get("token_count").unwrap_or(""))
  }
  sum
}

///|
/// Render items and a summary as `{"items": [...], "summary": {...}}`.
///
/// The summary carries `item_count`, `total_tokens`, and `groups`. `groups` is
/// empty unless a grouping key is supplied: this renderer does not guess which
/// metadata key matters, so the caller states it.
pub fn to_json(
  items : Array[@pipeline.Item],
  group_by? : String,
) -> Json {
  let rows = Json::array(
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
  let groups : Map[String, Json] = Map([])
  match group_by {
    Some(key) =>
      for g, n in group_by_meta(items, key) {
        groups[g] = Json::number(Double::from_int(n))
      }
    None => ()
  }
  let summary : Map[String, Json] = Map([])
  summary["item_count"] = Json::number(Double::from_int(count(items)))
  summary["total_tokens"] = Json::number(Double::from_int(total_tokens(items)))
  summary["groups"] = Json::object(groups)
  let root : Map[String, Json] = Map([])
  root["items"] = rows
  root["summary"] = Json::object(summary)
  Json::object(root)
}
