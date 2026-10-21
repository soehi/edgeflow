// moonlm-infer: memory_source -> InferStage -> collect, on a real model.
//
// Usage: moon run examples/infer_pipeline -- <model.gguf> "<prompt>" [max_tokens]
//
// The file reading here is argv plumbing for a path the user typed, mirroring
// how moonlm's own CLI opens models; InferStage and the pipeline perform no
// I/O of their own.

///|
#external
priv type ExFile

///|
#borrow(path, mode)
extern "C" fn ex_fopen(path : Bytes, mode : Bytes) -> ExFile = "ex_fopen"

///|
extern "C" fn ex_fclose(f : ExFile) -> Int = "ex_fclose"

///|
extern "C" fn ex_size(f : ExFile) -> Int64 = "ex_size"

///|
extern "C" fn ex_is_null(f : ExFile) -> Int = "ex_is_null"

///|
#borrow(handle)
extern "C" fn ex_read_owned(handle : ExFile, n : Int64) -> Bytes = "ex_read_owned"

///|
extern "C" fn ex_exit(code : Int) -> Unit = "ex_exit"

///|
fn cstr(s : String) -> Bytes {
  @utf8.encode(s) + b"\x00"
}

///|
/// Read a whole file into memory, or report why it could not be read.
fn read_whole(path : String) -> Result[Bytes, String] {
  let f = ex_fopen(cstr(path), cstr("rb"))
  if ex_is_null(f) != 0 {
    return Err("cannot open \{path} (does it exist? is it readable?)")
  }
  let size = ex_size(f)
  if size < 0L {
    ex_fclose(f) |> ignore
    return Err("cannot determine the size of \{path}")
  }
  if size > 0x7FFFFFFFL {
    ex_fclose(f) |> ignore
    return Err("\{path} is \{size} bytes, above the 32-bit buffer limit")
  }
  let buf = ex_read_owned(f, size)
  ex_fclose(f) |> ignore
  if buf.length().to_int64() != size {
    return Err("short read on \{path}")
  }
  Ok(buf)
}

///|
fn usage() -> String {
  "usage: moon run examples/infer_pipeline -- <model.gguf> \"<prompt>\" [max_tokens]"
}

///|
/// Do the work and return the exit code, so every branch has one type and
/// the process exits exactly once.
fn run_main(model_path : String, prompt : String, max_tokens : Int) -> Int {
  let bytes = match read_whole(model_path) {
    Ok(b) => b
    Err(e) => {
      println("error: \{e}")
      return 1
    }
  }
  let engine = match @engine.PureEngine::load_bytes(bytes, model_path) {
    Ok(e) => e
    Err(e) => {
      println("error: loading model failed: \{e}")
      return 1
    }
  }
  // Compose the pipeline exactly like a library user would.
  let pipeline = @pipeline.Pipeline::new().then(
    @infer.InferStage::new(engine, max_tokens),
  )
  let items = @source.memory_source([prompt])
  // Timed around the whole pipeline run, which for this one-stage pipeline is
  // the generation itself. Reported rather than asserted: it is a local speed
  // indicator, not a gate (see the benchmark's CONFIG.md for why throughput is
  // never a threshold).
  let started = @env.now()
  let out = match pipeline.run(items[0]) {
    Ok(item) => item
    Err(e) => {
      println("error: \{e.message()}")
      return 1
    }
  }
  let elapsed_ms = @env.now() - started
  let collected = @sink.collect([out])
  println("output:")
  println(collected[0].text)
  let gen = collected[0].meta.get("generated_tokens").unwrap_or("0")
  let n = try {
    @string.parse_int(gen[:])
  } catch {
    _ => 0
  }
  let rate = if elapsed_ms > 0UL {
    Double::from_int(n) / (elapsed_ms.to_double() / 1000.0)
  } else {
    0.0
  }
  println(
    "[\{gen} generated tokens in \{elapsed_ms} ms (\{rate.to_string()} tok/s), ctx \{@engine.Engine::context_length(engine)}]",
  )
  0
}

fn main {
  let argv = @env.args()
  if argv.length() < 3 {
    println(usage())
    ex_exit(2)
  }
  let prompt = argv[2]
  let mut max_tokens = 64
  if argv.length() >= 4 {
    let parsed = try { @string.parse_int(argv[3][:]) } catch {
      _ => -1
    }
    if parsed <= 0 {
      println("error: max_tokens must be a positive integer")
      ex_exit(2)
    }
    max_tokens = parsed
  }
  let code = run_main(argv[1], prompt, max_tokens)
  ex_exit(code)
}
