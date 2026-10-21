// Native file sources: one file by name, or a sandboxed directory walk.
//
// Threat model, stated because it shapes the two entry points differently:
// sources are configured by a human running the pipeline, not by model output
// (model text only ever flows through `Item`, never back into a path). So
// `file_source(path)` reads the single file the caller named — no sandbox to
// enforce against themselves — while `dir_source` must guarantee that a
// recursive walk cannot be led outside the root by a symlink or junction,
// which is what `Sandbox::resolve` provides: reject `..` segments, absolute
// and drive-relative paths lexically, then canonicalize and prefix-compare the
// real path.
//
// Read-only by construction: stubs.c opens files with "rb" only, and there is
// no write, delete, or rename entry point in this package.

///|
/// Per-file read cap in bytes (256 KB).
///
/// Exceeding it is an error rather than a truncation: a source that hands over
/// half a file silently produces half a pipeline.
pub let max_file_bytes : Int64 = 262144L

///|
/// The metadata key carrying the canonical source path of an item.
pub let meta_source_path : String = "source_path"

///|
/// The metadata key set to "true" when a file's bytes were not valid UTF-8 and
/// the text is a lossy repair.
pub let meta_encoding_lossy : String = "encoding_lossy"

///|
/// Canonical absolute path with symlinks and junctions resolved, as an
/// envelope (status byte + UTF-8 payload).
#borrow(path)
extern "C" fn ef_realpath(path : Bytes) -> Bytes = "ef_realpath"

///|
/// Newline-separated directory entry names (no "." / ".."), as an envelope.
#borrow(path)
extern "C" fn ef_list_dir(path : Bytes) -> Bytes = "ef_list_dir"

///|
/// 1 for a directory, 0 for a non-directory, negative on failure.
#borrow(path)
extern "C" fn ef_is_dir(path : Bytes) -> Int = "ef_is_dir"

///|
/// Raw file bytes up to `max_bytes`, as an envelope; over-cap is an error.
#borrow(path)
extern "C" fn ef_read_bytes(path : Bytes, max_bytes : Int64) -> Bytes = "ef_read_bytes"

///|
/// 1 on Windows, 0 elsewhere; decides path-prefix case folding.
extern "C" fn ef_is_windows() -> Int = "ef_is_windows"

fn cstr(s : String) -> Bytes {
  @utf8.encode(s) + b"\x00"
}

///|
/// Unpack a status-byte envelope from stubs.c.
fn unpack(kind : String, raw : Bytes) -> Result[String, String] {
  if raw.length() == 0 {
    return Err("\{kind}: malformed response from native layer")
  }
  let status = raw[0].to_int()
  let payload = @utf8.decode_lossy(raw.view(start=1))
  if status == 0 {
    Ok(payload)
  } else {
    Err(if payload == "" {
      "\{kind}: no message from OS"
    } else {
      payload
    })
  }
}

///|
/// Canonicalize a path that must already exist.
fn canonicalize(path : String) -> Result[String, @pipeline.StageError] {
  match unpack("realpath", ef_realpath(cstr(path))) {
    Ok(p) => Ok(p)
    Err(e) =>
      Err(@pipeline.Failed(
        stage="source",
        reason="realpath \{path}: \{e}",
      ))
  }
}

// --- sandbox ----------------------------------------------------------------

///|
/// A directory tree paths may be resolved inside.
pub(all) struct Sandbox {
  /// Canonical absolute root.
  root : String
  fold_case : Bool
} derive(Debug)

///|
/// Open `root` as a sandbox: it must exist and be a directory.
pub fn Sandbox::open(root : String) -> Result[Sandbox, @pipeline.StageError] {
  if root == "" {
    return Err(@pipeline.Failed(
      stage="source",
      reason="sandbox root is empty",
    ))
  }
  let canon = match canonicalize(root) {
    Ok(c) => c
    Err(e) => return Err(e)
  }
  match ef_is_dir(cstr(canon)) {
    1 => ()
    0 => {
      return Err(@pipeline.Failed(
        stage="source",
        reason="sandbox root is not a directory: \{canon}",
      ))
    }
    _ => {
      return Err(@pipeline.Failed(
        stage="source",
        reason="cannot stat sandbox root: \{canon}",
      ))
    }
  }
  Ok({ root: canon, fold_case: ef_is_windows() != 0 })
}

///|
/// Whether `child` is `root` itself or under it, segment-aware and optionally
/// ASCII-case-folded. `/tmp/ws2` is not inside `/tmp/ws`: the character after
/// the prefix must be a separator.
fn is_within(root : String, child : String, fold_case : Bool) -> Bool {
  let r = if fold_case { fold_ascii(root) } else { root }
  let c = if fold_case { fold_ascii(child) } else { child }
  if c == r {
    return true
  }
  if !c.has_prefix(r) {
    return false
  }
  if c.length() <= r.length() {
    return false
  }
  let sep = c[r.length()]
  sep == '/' || sep == '\\'
}

fn fold_ascii(s : String) -> String {
  let sb = StringBuilder::new()
  for ch in s {
    let v = ch.to_int()
    sb.write_char(if v >= 0x41 && v <= 0x5A {
      Int::unsafe_to_char(v + 0x20)
    } else {
      ch
    })
  }
  sb.to_string()
}

///|
/// Resolve `rel` (sandbox-relative) and return its canonical path.
///
/// Rejections, each with the rejected path in the error message: a `..`
/// segment, an absolute path (`/`, `\`, or a drive prefix like `C:`), a
/// non-existent path (realpath fails), and — the one only canonicalization
/// catches — a relative path that routes through a symlink or junction to
/// somewhere outside the root.
pub fn Sandbox::resolve(
  self : Sandbox,
  rel : String,
) -> Result[String, @pipeline.StageError] {
  let deny = fn(reason : String) -> @pipeline.StageError {
    @pipeline.Failed(
      stage="source",
      reason="sandbox denied \{rel}: \{reason}",
    )
  }
  if rel == "" {
    return Err(deny("empty path"))
  }
  if rel.has_prefix("/") || rel.has_prefix("\\") {
    return Err(deny("absolute paths are not allowed"))
  }
  if rel.length() >= 2 && rel[1] == ':' {
    let c = rel[0]
    if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') {
      return Err(deny("drive-relative paths are not allowed"))
    }
  }
  let normalized = rel.replace_all(old="\\", new="/")
  for segment in normalized.split("/") {
    if segment == ".." {
      return Err(deny("\"..\" is not allowed"))
    }
  }
  let joined =
    if self.root.has_suffix("/") || self.root.has_suffix("\\") {
      self.root + rel
    } else {
      "\{self.root}/\{rel}"
    }
  let canon = match canonicalize(joined) {
    Ok(c) => c
    Err(e) => return Err(e)
  }
  if !is_within(self.root, canon, self.fold_case) {
    return Err(deny("resolves outside the sandbox to \{canon}"))
  }
  Ok(canon)
}

// --- sources -----------------------------------------------------------------

///|
/// Read one file into a single item.
///
/// The path is whatever the pipeline's human caller configured; the canonical
/// form is recorded in `meta[source_path]` so downstream items carry
/// provenance. Failures: unreadable, is a directory, over the 256 KB cap.
pub fn file_source(path : String) -> Result[Array[@pipeline.Item], @pipeline.StageError] {
  let canon = match canonicalize(path) {
    Ok(c) => c
    Err(e) => return Err(e)
  }
  if ef_is_dir(cstr(canon)) == 1 {
    return Err(@pipeline.Failed(
      stage="file_source",
      reason="\{canon} is a directory; use dir_source",
    ))
  }
  match read_item(canon, "file_source") {
    Ok(item) => Ok([item])
    Err(e) => Err(e)
  }
}

///|
/// Walk `root` and read its files, sandboxed against `root`.
///
/// Directories recurse when `recursive`; non-directories are read. Two
/// deliberate behaviors, both about failure vs. skipping:
///
///   - An entry that resolves outside the root (a symlink or junction pointing
///     out) is SKIPPED, not fatal: the walk continues after refusing it, so one
///     planted escape cannot turn a directory read into an all-or-nothing
///     failure. resolve still denies it; only the walk moves on.
///   - A file that cannot be READ (missing, or over the 256 KB cap) is FATAL:
///     it is inside the sandbox, the caller chose to read this tree, and
///     dropping half a corpus without an error is the worse mistake.
pub fn dir_source(
  root : String,
  recursive : Bool,
) -> Result[Array[@pipeline.Item], @pipeline.StageError] {
  let sandbox = match Sandbox::open(root) {
    Ok(s) => s
    Err(e) => return Err(e)
  }
  let out : Array[@pipeline.Item] = []
  match walk(sandbox, sandbox.root, "", recursive, out) {
    Ok(_) => {
      // One sort at the exit, on the canonical source path. Sorting each
      // directory's names inside `walk` does not make the flattened output
      // globally ordered — a recursed subdirectory contributes a run in the
      // middle wherever the OS listed its parent — and relying on the OS
      // readdir order is exactly the non-determinism this stage must not
      // inherit. The contract "items are ordered by source_path" is guaranteed
      // here, independent of both.
      out.sort_by_key(fn(i : @pipeline.Item) {
        i.meta.get(meta_source_path).unwrap_or("")
      })
      Ok(out)
    }
    Err(e) => Err(e)
  }
}

///|
/// Depth-first, entry-name-sorted walk appending items to `out`.
fn walk(
  sandbox : Sandbox,
  dir : String,
  prefix : String,
  recursive : Bool,
  out : Array[@pipeline.Item],
) -> Result[Unit, @pipeline.StageError] {
  let entries = match unpack("list_dir", ef_list_dir(cstr(dir))) {
    Ok(body) => {
      let names : Array[String] = []
      if body != "" {
        for part in body.split("\n") {
          names.push(part.to_owned())
        }
        names.sort()
      }
      names
    }
    Err(e) =>
      return Err(@pipeline.Failed(
        stage="dir_source",
        reason="list \{dir}: \{e}",
      ))
  }
  for name in entries {
    let rel = if prefix == "" { name } else { "\{prefix}/\{name}" }
    // Re-resolve every entry rather than trusting the listing: the joined path
    // still has to pass the sandbox, which is what stops the walk following a
    // link out of the root.
    let canon = match Sandbox::resolve(sandbox, rel) {
      Ok(c) => c
      Err(_) => continue // escape or vanished entry: refused, skipped
    }
    if ef_is_dir(cstr(canon)) == 1 {
      if recursive {
        match walk(sandbox, canon, rel, true, out) {
          Ok(_) => ()
          Err(e) => return Err(e)
        }
      }
    } else {
      match read_item(canon, "dir_source") {
        Ok(item) => out.push(item)
        Err(e) => return Err(e)
      }
    }
  }
  Ok(())
}

///|
/// Read one canonical file into one item, tagging provenance and loss.
fn read_item(
  canon : String,
  stage : String,
) -> Result[@pipeline.Item, @pipeline.StageError] {
  let raw = ef_read_bytes(cstr(canon), max_file_bytes)
  if raw.length() == 0 || raw[0].to_int() != 0 {
    let msg = match unpack("read", raw) {
      Ok(_) => "read failed"
      Err(e) => e
    }
    return Err(@pipeline.Failed(stage=stage, reason="\{canon}: \{msg}"))
  }
  let bytes = Bytes::from_array(raw.view(start=1).to_array())
  let decoded = decode_text(bytes)
  let meta : Map[String, String] = Map([])
  meta[meta_source_path] = canon
  if decoded.lossy {
    meta[meta_encoding_lossy] = "true"
  }
  Ok(@pipeline.Item::{ text: decoded.text, meta })
}
