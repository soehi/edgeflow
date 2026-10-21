// In-memory item source.
//
// The pipeline core deliberately does not know where items come from; a
// source is any code that produces `Array[Item]`. This package holds the
// trivial one — strings already in memory — so the skeleton runs end to end
// with no I/O, and it is the shape any real source (a file walk, a request
// queue) will match later.

///|
/// Turn plain strings into pipeline items.
///
/// Each item gets an empty `meta` map: a source that knows provenance (file
/// path, line number) is a later phase, and inventing metadata keys here
/// without a consumer would be speculation.
pub fn memory_source(items : Array[String]) -> Array[@pipeline.Item] {
  items.map(fn(s) { @pipeline.Item::{ text: s, meta: Map([]) } })
}
