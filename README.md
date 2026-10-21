# soehi/edgeflow

Relationship to moonlm: this is a separate module (`soehi/edgeflow`) that depends on
`soehi/moonlm`. It is neither a submodule nor a replacement; it consumes the engine's
output in a text pipeline.

Composable text-pipeline skeleton for on-device LLM applications, in pure
MoonBit. No FFI, no third-party dependencies; builds and tests on `native`
and `wasm-gc`.

The unit of work is an `Item` — text plus string metadata — that moves through
an ordered list of stages. Sources produce items (memory or sandboxed files),
transforms edit, dedup and chunk them, an inference stage can append a model
continuation, and sinks aggregate and render the result.

## Install

```bash
moon add soehi/edgeflow@0.1.3
```

```moonbit
// In a package that depends on edgeflow:
let p = @pipeline.Pipeline::new()
  .then(@transform.trim())
  .then_batch(@transform.dedup())
  .then_batch(@transform.chunk_by_chars(200))
let items = @source.memory_source([" hello ", "hello", "world"])
let out = p.run_all(items)          // 2 items: "hello", "world"
let report = @sink.to_json(out).stringify()
```

## Scope

- **Stage composition.** `Pipeline::new().then(a).then(b)` runs `a` then `b`
  on one `Item`, synchronously and in order, stopping at the first failure.
  The error names the stage that failed, from the pipeline's own reading of
  `Stage::name`, so a stage is always located even when its error text is
  terse.
- **Sources.** `memory_source(items)` turns plain strings into `Item`s.
  On native, `file_source(path)` reads one file and `dir_source(root,
  recursive)` walks a tree — both sandboxed. A source is any function
  producing `Array[Item]`, so there is no source trait.
- **Text transforms.** `trim`, `collapse_whitespace`, `lowercase` and
  `token_stats` map one item to one item, preserving `meta`. `dedup` and the
  two chunkers change the item count and are `BatchStage`s.
- **Engine wrapper (thin).** `src/infer` is a pipeline stage that calls a
  MoonLM `Engine`: encode, generate, decode, back into an `Item` with a
  `generated_tokens` entry in `meta`. It holds a `&@engine.Engine` — the trait
  the engine package exposes precisely so a caller can hold *an* engine — and
  touches nothing below it: no model internals, no block decoding, no sampler
  implementation, no model loading. Sampling is a value the stage is
  constructed with.

  The context budget is enforced *before* generating: if prompt tokens plus
  `max_tokens` exceed the engine's context length, the stage fails with both
  numbers in the message rather than letting generation stop early and return
  a short answer that reads like a complete one.
- **Result aggregation.** `sink::count`, `group_by_meta`, `top_k` (numeric on
  a metadata key, stable on ties) and `to_json`, which emits
  `{"items": [...], "summary": {"item_count", "total_tokens", "groups"}}`.

## CLI

`src/cli` builds `moonflow`, a native front end that runs the whole flow:

```
moonflow run --model <gguf> --input <dir|file> [--chunk-tokens N] [--max-tokens N] [--topk N] [--json]

dir_source -> trim -> dedup -> chunk_by_tokens -> infer -> top_k -> json
```

`--chunk-tokens` is measured with the loaded model's own tokenizer, so the
budget is the one the engine sees. Without `--model` the command exits 2 with
a usage error; a model path that cannot be read exits 1. Nothing is truncated
silently: an unreadable input, an over-cap file, or an over-context prompt is
an error.

```bash
moon build src/cli --target native --release
moonflow run --model model.gguf --input ./docs --chunk-tokens 64 --max-tokens 8
```

## Non-goals

- **Streaming and distributed engines.** No async, no futures, no fan-out.
  The model is one item through one list of stages. A scheduler is a different
  object with different correctness questions.
- **Visualization.** No graphs, no dashboards. A pipeline is data, not a
  diagram.
- **Plugin DSL.** Stages are MoonBit types implementing one trait. A
  user-facing pipeline language would need a parser, a type checker, and a
  versioned grammar — none of which a skeleton has earned.
- **Embedding training.** No vector store, no fine-tuning. If retrieval is
  added it will call something that already exists, not train one.
- **Agent orchestration.** The agent loop, tool-call parsing, schema
  validation, and sandboxing live in `soehi/moonlm`. edgeflow pipes text; it
  does not decide what to call or what is allowed.
- **Model-loading details.** GGUF parsing, dequantization and the forward pass
  are `soehi/gguf` and `soehi/moonlm`. An edgeflow stage receives an
  already-loaded engine and never opens a file.

## Development

**Dependencies resolve from the MoonBit registry.** `soehi/moonlm@0.1.0` and
`soehi/gguf@0.1.0` are both published, so a clone of this directory builds on
its own — no workspace file, no sibling checkout.

```bash
cd edgeflow
moon update
moon check --target native && moon check --target wasm-gc
moon test  --target native && moon test  --target wasm-gc
```

### Branch A vs branch B

This module resolves dependencies **from the registry (branch A)**: both
`soehi/moonlm@0.1.0` and `soehi/gguf@0.1.0` are published, `moon.mod` pins
them, and a fresh clone builds with `moon update` alone. CI asserts this: it
runs `moon update`, and fails if a `moon.work` workspace is present, because a
workspace could make the build pass on one machine while the published module
is broken.

While developing against an unreleased change in `moonlm`, you can opt into a
local workspace (branch B) in the parent directory:

```bash
cd ..                       # the directory containing both modules
moon work init && moon work use ./moonlm ./edgeflow
```

That is a local convenience only. If the dependency is ever resolved this way
permanently, it is no longer a publishable module, and CI will (correctly)
refuse it until the dependency is released.

## Layout

| Path | Contents |
|---|---|
| `src/pipeline/` | `Item`, `Stage`, `BatchStage`, `StageError`, `Pipeline`, and the test stages (trim, uppercase, replace, always-fail). |
| `src/source/` | `memory_source`; native `file_source` / `dir_source` with their own path sandbox. |
| `src/sink/` | `collect`, `count`, `group_by_meta`, `top_k`, `to_json`. |
| `src/transform/` | `trim` / `collapse_whitespace` / `lowercase` / `token_stats` (one-in-one-out); `dedup` and `chunk_by_chars` / `chunk_by_tokens` (whole-list). |
| `src/infer/` | `InferStage`: the MoonLM `Engine` as one pipeline stage. |
| `src/cli/` | `moonflow`: the native command-line front end. |
| `src/examples/infer_pipeline/` | Native example: `memory_source → InferStage → collect` on a real GGUF. |

## Measured

One run on the maintainer's machine (Windows 11, AMD64, MoonBit
`0.1.20260819`, native release, single-threaded), model
`SmolLM2-135M-Instruct-Q8_0.gguf` (138 MB). These are **not** performance
claims; they are what one run produced, recorded so the shape of a run is
visible. Throughput is host-dependent and no threshold is set.

Input: a directory of 3 small text files, one of which is a duplicate.

```
$ moonflow run --model SmolLM2-...Q8_0.gguf --input <dir> \
               --chunk-tokens 32 --max-tokens 8 --topk 3

items: 2, total tokens: 11, top 2 shown
  [6 tok] .../b.txt
    Water is composed of hydrogen and oxygen. The oxygen is released as a
  [5 tok] .../a.txt
    The capital of France is Paris. Paris is the largest city in
elapsed: 1744 ms
```

| Metric | Value |
|---|---|
| input files | 3 (2 after dedup) |
| items out | 2 |
| total tokens (prompt chunks) | 11 |
| wall clock | ~1.7–1.8 s |
| peak working set | 189.3 MB |

Dedup is visible in the item count: three files in, two out. Peak memory
matches the standalone benchmark for this model (189 MB), which is expected —
the pipeline adds chunk bookkeeping, not another model copy.

## Two kinds of stage

`Stage` is one item in, one item out. That cannot express dropping a duplicate
or fanning a document out into chunks, so those implement `BatchStage` (a whole
list in, a whole list out) and are added with `then_batch`:

```moonbit
let p = @pipeline.Pipeline::new()
  .then(@transform.trim())                 // item -> item
  .then_batch(@transform.dedup())          // list -> list, fewer items
  .then_batch(@transform.chunk_by_chars(200))
let out = p.run_all(items)                 // whole-list entry point
```

`run(item)` still exists for single-item pipelines; it refuses (rather than
silently truncating) if a batch or chunk stage changes the count, and points at
`run_all`. The two entry points share one stage list, so mixing is the normal
case.

### `Dedup` is stateful: do not reuse an instance

`Dedup` remembers which texts it has already admitted, in a `mut` field. That is
what lets it drop duplicates within a run, and it is also why **one instance
must not be shared between pipelines, or reused across runs**: the second run
would treat the first run's texts as already seen and drop items that were never
duplicates of *this* batch. Construct a fresh `dedup()` per pipeline. The
behavior is pinned by a test (`dedup instance is single-run: reuse carries memory
forward`), so it fails loudly rather than surprising you silently.

### Chunking never crosses a character or a token boundary

`ChunkByChars` splits on `Char` boundaries and prefers the last newline before
the budget. `ChunkByTokens` takes an injected token counter — `chunk_by_model`
wires the real tokenizer — and re-measures every piece, so no piece exceeds
`max` and re-chunking an already-valid piece returns it unchanged.

```bash
moon run src/examples/infer_pipeline -- <model.gguf> "The capital of France is" 24
```

## License

Apache-2.0. See [LICENSE](LICENSE).
