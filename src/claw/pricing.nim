## pricing — token → dollars for the LLM models this gateway calls.
##
## Rates are per million tokens, expressed in USD. Input and output are
## priced separately because providers charge output at 2-4× the input
## rate; a single blended rate would be off by a meaningful factor.
##
## Sourced from each provider's official pricing page. Update when the
## provider does. For models not in the table, `estimateCost` returns 0
## (unknown price) — the caller can show "—" in the cost column.

import std/[tables, strutils, strformat]

type
  ModelPricing* = object
    inPerM*: float   ## USD per 1M prompt_tokens
    outPerM*: float  ## USD per 1M completion_tokens

const ModelPrices*: Table[string, ModelPricing] = {
  # DeepSeek (https://platform.deepseek.com/api-docs/pricing)
  "deepseek-chat":     ModelPricing(inPerM: 0.27, outPerM: 1.10),
  "deepseek-reasoner": ModelPricing(inPerM: 0.55, outPerM: 2.19),

  # OpenAI
  "gpt-4o":       ModelPricing(inPerM: 2.50, outPerM: 10.00),
  "gpt-4o-mini":  ModelPricing(inPerM: 0.15, outPerM: 0.60),
  "gpt-4.1":      ModelPricing(inPerM: 2.00, outPerM: 8.00),
  "gpt-4.1-mini": ModelPricing(inPerM: 0.40, outPerM: 1.60),
  "o1":           ModelPricing(inPerM: 15.00, outPerM: 60.00),
  "o1-mini":      ModelPricing(inPerM: 1.10, outPerM: 4.40),
  "o3-mini":      ModelPricing(inPerM: 1.10, outPerM: 4.40),

  # Anthropic
  "claude-sonnet-4-5": ModelPricing(inPerM: 3.00, outPerM: 15.00),
  "claude-opus-4-1":   ModelPricing(inPerM: 15.00, outPerM: 75.00),
  "claude-haiku-4-5":  ModelPricing(inPerM: 1.00, outPerM: 5.00),

  # Groq — free tier currently
  "llama-3.3-70b-versatile": ModelPricing(inPerM: 0.59, outPerM: 0.79),
}.toTable

proc estimateCost*(tokensIn, tokensOut: int, model: string): float =
  ## USD cost for a given (prompt_tokens, completion_tokens, model)
  ## triple. Returns 0 when the model isn't in the price table —
  ## distinguishable from a real $0 by checking `knownModel` separately.
  let key = model.toLowerAscii
  if key notin ModelPrices: return 0.0
  let p = ModelPrices[key]
  (tokensIn.float * p.inPerM + tokensOut.float * p.outPerM) / 1_000_000.0

proc knownModel*(model: string): bool =
  model.toLowerAscii in ModelPrices

proc fmtCost*(usd: float): string =
  ## Compact display: "$0.001" / "$1.23" / "$12.34K" (rare but possible).
  if usd == 0.0: "$0"
  elif usd < 0.01: fmt"${usd:.4f}"
  elif usd < 1.0: fmt"${usd:.3f}"
  elif usd < 1000.0: fmt"${usd:.2f}"
  else: fmt"${usd/1000.0:.2f}K"
