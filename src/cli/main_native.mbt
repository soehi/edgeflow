// moonflow: run a text pipeline over a file or directory.
//
//   moonflow run --model <gguf> --input <dir|file>
//                [--chunk-tokens N] [--max-tokens N] [--topk N] [--json]
//
// Flow, exactly the stages below and in this order:
//
//   dir_source -> trim -> dedup -> chunk_by_tokens -> infer -> top_k -> json
//
// `chunk_by_tokens` counts with the loaded model's own tokenizer, so a chunk's
// budget is the budget the engine will actually see. Without `--model` the run
// stops before chunking with a clear error rather than producing chunks whose
// sizes mean nothing.

///|
#external
priv type MfFile

///|
#borrow(path, mode)
extern "C" fn mf_fopen(path : Bytes, mode : Bytes) -> MfFile = "mf_fopen"

///|
extern "C" fn mf_fclose(f : MfFile) -> Int = "mf_fclose"

///|
extern "C" fn mf_size(f : MfFile) -> Int64 = "mf_size"

///|
extern "C" fn mf_is_null(f : MfFile) -> Int = "mf_is_null"

///|
#borrow(handle)
extern "C" fn mf_read_owned(handle : MfFile, n : Int64) -> Bytes = "mf_read_owned"

///|
extern "C" fn mf_exit(code : Int) -> Unit = "mf_exit"

fn cstr(s : String) -> Bytes {
  @utf8.encode(s) + b"\x00"
}

///|
fn read_whole(path : String) -> Result[Bytes, String] {
  let f = mf_fopen(cstr(path), cstr("rb"))
  if mf_is_null(f) != 0 {
    return Err("cannot open \{path} (does it exist? is it readable?)")
  }
  let size = mf_size(f)
  if size < 0L {
    mf_fclose(f) |> ignore
    return Err("cannot determine the size of \{path}")
  }
  if size > 0x7FFFFFFFL {
    mf_fclose(f) |> ignore
    return Err("\{path} is \{size} bytes, above the 32-bit buffer limit")
  }
  let buf = mf_read_owned(f, size)
  mf_fclose(f) |> ignore
  if buf.length().to_int64() != size {
    return Err("short read on \{path}")
  }
  Ok(buf)
}

///|
fn usage() -> String {
  [
    "usage: moonflow run --model <model.gguf> --input <dir|file> [options]",
    "",
    "options:",
    "  --chunk-tokens N   token budget per chunk (default 256)",
    "  --max-tokens N     tokens generated per chunk (default 32)",
    "  --topk N           keep the N chunks with most tokens (default 5)",
    "  --json             print the JSON report instead of a summary",
  ].join("\n")
}

///|
struct Options {
  model : String
  input : String
  chunk_tokens : Int
  max_tokens : Int
  topk : Int
  json : Bool
}

///|
fn parse_args(argv : Array[String]) -> Result[Options, String] {
  if argv.length() < 2 || argv[1] != "run" {
    return Err("expected the `run` subcommand")
  }
  let mut model : String? = None
  let mut input : String? = None
  let mut chunk_tokens = 256
  let mut max_tokens = 32
  let mut topk = 5
  let mut json = false
  let mut i = 2
  while i < argv.length() {
    let flag = argv[i]
    if i + 1 >= argv.length() && flag != "--json" {
      return Err("\{flag} needs a value")
    }
    if flag == "--model" {
      model = Some(argv[i + 1])
      i = i + 2
    } else if flag == "--input" {
      input = Some(argv[i + 1])
      i = i + 2
    } else if flag == "--chunk-tokens" {
      match parse_pos(argv[i + 1], flag) {
        Ok(n) => chunk_tokens = n
        Err(e) => return Err(e)
      }
      i = i + 2
    } else if flag == "--max-tokens" {
      match parse_pos(argv[i + 1], flag) {
        Ok(n) => max_tokens = n
        Err(e) => return Err(e)
      }
      i = i + 2
    } else if flag == "--topk" {
      match parse_pos(argv[i + 1], flag) {
        Ok(n) => topk = n
        Err(e) => return Err(e)
      }
      i = i + 2
    } else if flag == "--json" {
      json = true
      i = i + 1
    } else {
      return Err("unknown option \"\{flag}\"")
    }
  }
  let model = match model {
    Some(m) => m
    None => return Err("--model <model.gguf> is required")
  }
  let input = match input {
    Some(v) => v
    None => return Err("--input <dir|file> is required")
  }
  Ok({ model, input, chunk_tokens, max_tokens, topk, json })
}

///|
fn parse_pos(v : String, flag : String) -> Result[Int, String] {
  let n = try {
    @string.parse_int(v[:])
  } catch {
    _ => -1
  }
  if n <= 0 {
    Err("\{flag} must be a positive integer, got \"\{v}\"")
  } else {
    Ok(n)
  }
}

///|
/// Load items from a directory (recursively) or from one file.
fn load_input(path : String) -> Result[Array[@pipeline.Item], String] {
  match @source.dir_source(path, true) {
    Ok(items) => Ok(items)
    Err(e) =>
      match @source.file_source(path) {
        Ok(items) => Ok(items)
        // Report the directory error: it names the path and the OS reason,
        // which is what a user who typed the wrong thing needs.
        Err(_) => Err(e.message())
      }
  }
}

///|
fn run(argv : Array[String]) -> Int {
  let opts = match parse_args(argv) {
    Ok(o) => o
    Err(e) => {
      println("error: \{e}\n")
      println(usage())
      return 2
    }
  }
  let started = @env.now()

  // Model first: without it there is no tokenizer, and a token budget measured
  // by some other tokenizer would be a different number pretending to be this
  // one's.
  let bytes = match read_whole(opts.model) {
    Ok(b) => b
    Err(e) => {
      println("error: \{e}")
      return 1
    }
  }
  let engine = match @engine.PureEngine::load_bytes(bytes, opts.model) {
    Ok(e) => e
    Err(e) => {
      println("error: loading \{opts.model}: \{e}")
      return 1
    }
  }
  let items = match load_input(opts.input) {
    Ok(v) => v
    Err(e) => {
      println("error: cannot read --input: \{e}")
      return 1
    }
  }
  let count = @transform.counter_of(engine.tokenizer)
  // The whole flow, in order. `dedup` drops duplicates before chunking so one
  // file pasted twice does not cost two generations; `chunk_by_tokens` uses the
  // model's tokenizer; `infer` appends a continuation; `top_k` keeps the
  // largest chunks.
  let pipeline = @pipeline.Pipeline::new()
    .then(@transform.trim())
    .then_batch(@transform.dedup())
    .then_batch(@transform.chunk_by_tokens(opts.chunk_tokens, count~))
    .then(@transform.token_stats(count~))
    .then(@infer.InferStage::new(engine, opts.max_tokens))
  let outputs = match pipeline.run_all(items) {
    Ok(v) => v
    Err(e) => {
      println("error: \{e.message()}")
      return 1
    }
  }
  let top = @sink.top_k(outputs, opts.topk, by="token_count")
  let elapsed = @env.now() - started
  if opts.json {
    println(@sink.to_json(top, group_by="source_path").stringify())
  } else {
    println(
      "items: \{@sink.count(outputs)}, total tokens: \{@sink.total_tokens(outputs)}, top \{top.length()} shown",
    )
    for item in top {
      let src = item.meta.get("source_path").unwrap_or("")
      let toks = item.meta.get("token_count").unwrap_or("?")
      println("  [\{toks} tok] \{src}")
      println("    \{first_line(item.text)}")
    }
    println("elapsed: \{elapsed} ms")
  }
  0
}

///|
fn first_line(text : String) -> String {
  let line = match text.split("\n").next() {
    Some(s) => s.to_owned()
    None => text
  }
  if line.length() > 80 {
    line[:80].to_owned() + "…"
  } else {
    line
  }
}

fn main {
  let code = run(@env.args())
  mf_exit(code)
}
