name = "soehi/edgeflow"

version = "0.1.4"

readme = "README.md"

repository = "https://github.com/soehi/edgeflow"

license = "Apache-2.0"

keywords = [
  "pipeline",
  "llm",
  "edge",
]

description = "Composable text-pipeline skeleton for on-device LLM applications, in MoonBit"

preferred_target = "wasm-gc"

source = "src"

import {
  "soehi/gguf@0.1.1",
  "soehi/moonlm@0.1.2",
}
