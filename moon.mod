name = "soehi/edgeflow"

version = "0.1.2"

readme = "README.md"

repository = "https://github.com/soehi/moonlm"

license = "Apache-2.0"

keywords = [
  "pipeline",
  "llm",
  "edge",
]

description = "Composable text-pipeline skeleton for on-device LLM applications, in pure MoonBit"

preferred_target = "wasm-gc"

source = "src"

import {
  "soehi/gguf@0.1.0",
  "soehi/moonlm@0.1.0",
}
