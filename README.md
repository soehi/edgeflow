# soehi/edgeflow

Composable text-pipeline skeleton for on-device LLM applications, in pure
MoonBit. No FFI, no third-party dependencies; builds and tests on `native`
and `wasm-gc`.

The unit of work is an `Item` — text plus string metadata — that moves through
an ordered list of `Stage`s. Sources produce items, sinks consume them, and
nothing in the skeleton reads a file, opens a socket, or loads a model. That
is the point: the composition rules can be tested and pinned before any
behavior worth the name is attached.

## Scope

- **Stage composition.** `Pipeline::new().then(a).then(b)` runs `a` then `b`
  on one `Item`, synchronously and in order, stopping at the first failure.
  The error names the stage that failed, from the pipeline's own reading of
  `Stage::name`, so a stage is always located even when its error text is
  terse.
- **In-memory source.** `memory_source(items)` turns plain strings into
  `Item`s. The shape any real source will match later; it carries no
  provenance yet because nothing consumes one.
- **Text transforms.** `trim`, `uppercase`, `replace` over `Item::text`,
  preserving `meta`. A stage maps one item to one item — it cannot drop or
  duplicate — which is what keeps `run` a straight loop rather than a
  scheduler.
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
- **Result aggregation.** Sinks collect items and render them as JSON.

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

While developing against an unreleased change in `moonlm`, point the dependency
at the local tree instead with a `moon.work` in the parent directory:

```bash
cd ..                       # the directory containing both modules
moon work init && moon work use ./moonlm ./edgeflow
```

That is a local-development convenience, not a requirement: without it the
registry versions above are used, which is what CI does.

## Layout

| Path | Contents |
|---|---|
| `src/pipeline/` | `Item`, `Stage`, `BatchStage`, `StageError`, `Pipeline`, and the test stages (trim, uppercase, replace, always-fail). |
| `src/source/` | `memory_source`; native `file_source` / `dir_source` with their own path sandbox. |
| `src/sink/` | `collect` and `to_json`. |
| `src/transform/` | `trim` / `collapse_whitespace` / `lowercase` / `token_stats` (one-in-one-out); `dedup` and `chunk_by_chars` / `chunk_by_tokens` (whole-list). |
| `src/infer/` | `InferStage`: the MoonLM `Engine` as one pipeline stage. |
| `src/examples/infer_pipeline/` | Native example: `memory_source → InferStage → collect` on a real GGUF. |

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
