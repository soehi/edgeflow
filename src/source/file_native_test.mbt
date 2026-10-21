// File-source and sandbox tests (native-only, real temporary tree).
//
// The fixture (ef_test_make_tree in stubs.c) creates:
//
//   <root>/ws/inside.txt       "hello"
//   <root>/ws/sub/nested.txt   "nested"
//   <root>/ws/binary.bin       invalid UTF-8 (FF FE 'x')
//   <root>/ws/escape -> <root>/outside
//   <root>/outside/secret.txt  "secret"
//   <root>/big/big.txt         262145 bytes, one over the 256 KB cap
//
// The symlink is what the sandbox exists for: every walk step canonicalizes
// before prefix-comparing, so an escape is refused whether it looks like it
// is inside the root or not.

///|
extern "C" fn ef_test_make_tree() -> Bytes = "ef_test_make_tree"

///|
/// The fixture root, or a failure that aborts the test.
fn tree_root() -> String raise {
  let raw = ef_test_make_tree()
  if raw.length() == 0 || raw[0].to_int() != 0 {
    fail("cannot create fixture tree")
  }
  @utf8.decode_lossy(raw.view(start=1))
}

fn ws_root() -> String raise {
  tree_root() + "/ws"
}

///|
/// The message of a failed resolve, or a marker showing it succeeded.
fn resolve_error(sb : Sandbox, rel : String) -> String {
  match sb.resolve(rel) {
    Ok(p) => "<resolved to \{p}>"
    Err(e) => e.message()
  }
}

fn source_paths(items : Array[@pipeline.Item]) -> Array[String] {
  items.map(fn(i) { i.meta.get("source_path").unwrap_or("") })
}

fn has_suffix_in(names : Array[String], suffix : String) -> Bool {
  for n in names {
    if n.has_suffix(suffix) {
      return true
    }
  }
  false
}

// --- sandbox rejections ------------------------------------------------------

///|
test "sandbox: .. segments are rejected, message names the path" {
  let sb = Sandbox::open(ws_root()).unwrap()
  for rel in ["../outside/secret.txt", "sub/../../outside", ".."] {
    let msg = resolve_error(sb, rel)
    assert_true(msg.contains("sandbox denied \{rel}"))
    assert_true(msg.contains(".."))
  }
}

///|
test "sandbox: absolute and drive-relative paths are rejected" {
  let sb = Sandbox::open(ws_root()).unwrap()
  for rel in ["/etc/passwd", "\\Windows\\win.ini"] {
    let msg = resolve_error(sb, rel)
    assert_true(msg.contains("sandbox denied \{rel}"))
    assert_true(msg.contains("absolute"))
  }
  for rel in ["C:/Windows/win.ini", "c:\\x"] {
    let msg = resolve_error(sb, rel)
    assert_true(msg.contains("sandbox denied \{rel}"))
    assert_true(msg.contains("drive-relative"))
  }
}

///|
test "sandbox: symlink escaping the root is refused" {
  let sb = Sandbox::open(ws_root()).unwrap()
  // The link itself points outside…
  let link = resolve_error(sb, "escape")
  assert_true(link.contains("sandbox denied escape"))
  assert_true(link.contains("outside the sandbox"))
  // …and so does routing through it.
  let through = resolve_error(sb, "escape/secret.txt")
  assert_true(through.contains("sandbox denied escape/secret.txt"))
  assert_true(through.contains("outside the sandbox"))
}

///|
test "sandbox: missing paths fail with realpath, not silently" {
  let sb = Sandbox::open(ws_root()).unwrap()
  let msg = resolve_error(sb, "missing.txt")
  assert_true(msg.contains("realpath"))
}

///|
test "sandbox: relative paths inside resolve" {
  let sb = Sandbox::open(ws_root()).unwrap()
  let inside = sb.resolve("inside.txt").unwrap()
  assert_true(inside.has_suffix("inside.txt"))
  let nested = sb.resolve("sub/nested.txt").unwrap()
  assert_true(nested.has_suffix("nested.txt"))
}

// --- sources -----------------------------------------------------------------

///|
test "file_source reads one file and records provenance" {
  let root = tree_root()
  let items = file_source("\{root}/ws/inside.txt").unwrap()
  assert_eq(items.length(), 1)
  assert_eq(items[0].text, "hello")
  // Canonical provenance, recorded for every item.
  assert_true(
    items[0].meta.get("source_path").unwrap_or("").has_suffix("inside.txt"),
  )
  // Clean UTF-8 is not tagged lossy.
  assert_false(items[0].meta.get("encoding_lossy") is Some(_))
}

///|
test "file_source tags invalid UTF-8 with encoding_lossy" {
  let root = tree_root()
  let items = file_source("\{root}/ws/binary.bin").unwrap()
  assert_eq(items[0].meta.get("encoding_lossy"), Some("true"))
  // A repaired string is still produced (the pipeline sees the content it
  // can, flagged as not the file's true text).
  assert_true(items[0].text.length() > 0)
}

///|
test "file_source refuses a directory with a pointer to dir_source" {
  let root = tree_root()
  match file_source("\{root}/ws") {
    Ok(_) => fail("a directory must not read as a file")
    Err(e) => {
      assert_true(e.message().contains("is a directory"))
      assert_true(e.message().contains("dir_source"))
    }
  }
}

///|
test "file_source is fatal over the 256 KB cap, never a truncation" {
  let root = tree_root()
  match file_source("\{root}/big/big.txt") {
    Ok(items) => fail("cap violated; got \{items[0].text.length()} chars")
    Err(e) => {
      assert_true(e.message().contains("262145"))
      assert_true(e.message().contains("cap"))
    }
  }
}

///|
test "dir_source non-recursive reads top-level files only" {
  let items = dir_source(ws_root(), false).unwrap()
  let paths = source_paths(items)
  paths.sort()
  // inside.txt and binary.bin at the top; sub is skipped (not recursive);
  // escape is skipped because resolving it leaves the sandbox.
  assert_eq(paths.length(), 2)
  assert_true(has_suffix_in(paths, "inside.txt"))
  assert_true(has_suffix_in(paths, "binary.bin"))
}

///|
/// The `.../<name>` tail of each canonical path, so assertions do not depend on
/// the per-run temporary directory's name. Everything after the last "/ws/"
/// (or "\"-equivalent) is the sandbox-relative path the walk produced.
fn relative_tails(items : Array[@pipeline.Item]) -> Array[String] {
  items.map(fn(i) {
    let p = i.meta.get("source_path").unwrap_or("")
    // Normalize the separator so the assertion reads the same on Windows
    // (canonical paths use `\`) and POSIX (`/`).
    after_ws(p).replace_all(old="\\", new="/")
  })
}

///|
/// Everything after the last `/ws/` or `\ws\` segment in a canonical path.
/// The fixture's sandbox root always ends in `ws`, but stubs.c normalizes to
/// backslashes on Windows and forward slashes elsewhere, so both separators
/// are matched; `ws` must be its own segment (delimited on both sides) so the
/// scan cannot be fooled by `ws` inside another name.
fn after_ws(path : String) -> String {
  let chars = path.to_array()
  let n = chars.length()
  let mut i = n
  while i >= 4 {
    // chars[i-1] is one past a candidate `\ws\` or `/ws/` ending at i-1.
    let c3 = chars[i - 1]
    let c2 = chars[i - 2]
    let c1 = chars[i - 3]
    let c0 = chars[i - 4]
    if is_sep(c3) && c2 == 's' && c1 == 'w' && is_sep(c0) {
      return path[i:].to_owned()
    }
    i = i - 1
  }
  path
}

fn is_sep(c : Char) -> Bool {
  c == '/' || c == '\\'
}

///|
test "dir_source recursive walks subdirectories but not symlinks, in sorted order" {
  let items = dir_source(ws_root(), true).unwrap()
  // Deterministic order, and the one the sandbox intends: entries sorted at
  // each directory, subdirectory recursed at its alphabetical position. binary
  // and inside are top-level files; `sub/nested` comes last because `sub` sorts
  // after `inside.txt`; `escape` is refused and produces no item.
  assert_eq(relative_tails(items), ["binary.bin", "inside.txt", "sub/nested.txt"])
  // No item's text is "secret": the walk never followed `escape` out of the
  // sandbox.
  for it in items {
    assert_false(it.text.contains("secret"))
  }
}

///|
test "sources feed a pipeline: dir -> transform" {
  // End-to-end: source items pass through transforms like any others, and
  // meta (source_path, encoding_lossy) rides along untouched.
  let items = dir_source(ws_root(), true).unwrap()
  let out = @pipeline.Pipeline::new()
    .then(@transform.trim())
    .run_all(items)
    .unwrap()
  assert_eq(out.length(), items.length())
  for it in out {
    assert_true(it.meta.get("source_path") is Some(_))
  }
}
