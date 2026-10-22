# Changelog

Tags are vX.Y.Z on the commit whose moon.mod carries that version.
Publish order: soehi/gguf -> soehi/moonlm -> soehi/edgeflow.

## 0.1.4 — 2026-10-22

- Consume `soehi/moonlm@0.1.2` and `soehi/gguf@0.1.1`.
- Run CI on MoonBit `0.1.20261020`; the `0.1.20260819` baseline still builds.
- Point `repository` at `soehi/edgeflow`.
- Drop the "pure MoonBit" claim from the module description: native file
  sources use a libc stub (see README).
- State the relationship to moonlm in the README: a separate module that
  depends on the engine, not a submodule or a replacement.

## 0.1.3 — 2026-10-21

- Result aggregation (`count`, `group_by_meta`, `top_k`, `to_json` with a
  summary), the `moonflow` CLI, CI, and a measured run.

## 0.1.2 — 2026-10-21

- Text transforms (trim, collapse whitespace, lowercase, dedup, chunking by
  chars or tokens, token statistics) and sandboxed native file sources.

## 0.1.1 — 2026-10-21

- `InferStage`: the MoonLM engine as one pipeline stage, plus a native example.

## 0.1.0 — 2026-10-21

- Pipeline skeleton: `Item`, `Stage`/`BatchStage`, `Pipeline`, an in-memory
  source, and collect/JSON sinks.
