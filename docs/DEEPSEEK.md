# DeepSeek API — verified facts

> Fetched 2026-11-11 from `api-docs.deepseek.com` (raw `.md` sources, not the
> client-rendered HTML — the HTML pages collapse to a single page without JS).
>
> Everything here was read from the live docs, not recalled. Re-verify before
> relying on any of it: the pricing page states DeepSeek reserves the right to
> change prices, and the compatibility surface is evolving.

## Why this file exists

The migration from Anthropic to DeepSeek turns on a handful of specific
behaviours — automatic caching, ignored `cache_control`, a different
`stop_reason` set. Each one either deletes code we wrote or silently changes
what it means. Writing them down once, with sources, keeps the migration from
being argued from memory.

## Endpoints

| | |
|---|---|
| OpenAI format | `https://api.deepseek.com` |
| **Anthropic format** (chosen) | `https://api.deepseek.com/anthropic` |
| Auth | `x-api-key: <KEY>` **or** `Authorization: Bearer <KEY>` |

Source: `quick_start/your_first_api_call.md`, `api_guides/anthropic_api.md`.

## Models

| Model | Context | Max output | Vision | Notes |
|---|---|---|---|---|
| `deepseek-flash` | 1M | 384K | ✓ | Served by DeepSeek-V4.1-Flash-1017 |
| `deepseek-v4-pro` | 1M | 384K | ✗ | Served by DeepSeek-V4-Pro-0813 |

Thinking mode is **on by default** on both, with default effort `high`.

`claude-*` model names are also accepted on the Anthropic endpoint and mapped:
`claude-opus*` → `deepseek-v4-pro`, any other `claude*` → `deepseek-flash`. A
non-`claude` unknown name returns 400. **We send real DeepSeek names** — the
mapping exists for tools with hardcoded Claude names, and relying on it would
hide which model actually ran.

Source: `quick_start/pricing.md`, `api_guides/anthropic_api.md`.

## Pricing (USD per 1M tokens)

Peak hours are **01:00–04:00 and 06:00–10:00 UTC, Mon–Fri**, excluding Chinese
public holidays. Off-peak is half price and covers all other hours, weekends,
and Chinese public holidays in full.

| | `deepseek-flash` | `deepseek-v4-pro` |
|---|---|---|
| Input, cache hit — off-peak | $0.003 | $0.022 |
| Input, cache hit — peak | $0.006 | $0.044 |
| Input, cache miss — off-peak | $0.15 | $0.66 |
| Input, cache miss — peak | $0.30 | $1.32 |
| Output — off-peak | $0.60 | $1.98 |
| Output — peak | $1.20 | $3.96 |

For scale: Opus 4.8 was $5 / $25 per MTok. V4-Pro off-peak is **~7.6× cheaper
on input and ~12.6× cheaper on output**; a cache hit is ~227× cheaper than an
Opus uncached input token.

Cache-hit input is **50× cheaper than cache-miss** on both models, so caching
still matters — just not enough to justify architectural contortions.

Source: `quick_start/pricing.md`.

## Context caching — the big architectural difference

**Enabled by default for all users. No code, no markers, no `cache_control`.**

Caching is on disk and prefix-based, but the unit is a *persisted cache prefix
unit*, and a request hits the cache only if it **fully matches** one.

Units get persisted three ways:

1. **At request boundaries** — every request persists a unit at the end of the
   user input and at the end of the model output.
2. **By common-prefix detection** — when the system notices a prefix shared
   across requests, it persists that prefix as its own unit.
3. **At fixed token intervals** — for long inputs/outputs, so a long prefix is
   not uncacheable merely for never reaching a boundary.

Worked example from the docs: round 1 is `A + B`, round 2 is `A + B + C` → hit
on `A + B`. But round 1 `A + B` followed by round 2 `A + C` → **miss**, because
`A + C` does not fully match the unit `A + B`. The system then persists `A`,
so a later `A + D` hits.

**Consequences for this project:**

- `cache_control` is **ignored** on the Anthropic endpoint. The second
  breakpoint added on 2026-11-10 (for Opus's 4,096-token minimum) was inert
  here and **has been removed**, along with `cachesConversation`,
  `BreakpointBlock`, and `CacheablePrefix.cachingIsViable`.
- There is **no documented minimum prefix length**. The ~1,710-token static
  prefix that was too short for Opus is fine here.
- Byte stability still matters, and arguably more: matching is exact and
  full-unit. Every R8 guarantee on the static prefix stays worth having.
- Multi-round agent loops are the ideal shape — each round's history is a
  persisted unit the next round fully matches.
- Caching is **best-effort**; no 100% hit guarantee. Construction takes
  seconds; entries are cleared "within a few hours to a few days" of disuse.
  So a cache-hit assertion must tolerate a cold first call.

Source: `guides/kv_cache.md`.

### Cache telemetry field names

| Format | Hit | Miss / uncached |
|---|---|---|
| OpenAI (native) | `prompt_cache_hit_tokens` | `prompt_cache_miss_tokens` |
| **Anthropic compat** | `cache_read_input_tokens` | `input_tokens` |

In compat mode `cache_creation_input_tokens` is **always 0** — there is no
explicit write step to report. Total input = `input_tokens +
cache_read_input_tokens + cache_creation_input_tokens`.

Read usage from the **final `message_delta.usage`**, not by summing it with
`message_start`. This matches what `SSEParser` already does.

Source: `guides/kv_cache.md`, `api_guides/anthropic_api.md`.

## Thinking mode

| | Anthropic format |
|---|---|
| Toggle | `{"thinking": {"type": "enabled" \| "disabled"}}` |
| Effort | `{"output_config": {"effort": "low" \| "high" \| "max"}}` |

`adaptive` is accepted and **treated as `enabled`**. `budget_tokens` is
ignored. Default is enabled at effort `high`.

Effort values are mapped, not rejected:

| Requested | Actual |
|---|---|
| `minimal`, `low` | low |
| `medium`, `high`, `xhigh` | high |
| `max`, `ultra` | max |

So `medium` and `xhigh` are silently indistinguishable from `high` — worth
knowing before tuning effort, since sweeping those three values would measure
noise.

**In thinking mode:** `temperature` has no effect (set without error),
`tool_choice: {"type": "tool"}` returns **400**, and `top_p` is clamped or
ignored depending on model.

**Thinking blocks must be replayed when `tools` is present.** The docs: preserve
and pass back the assistant's complete `content` array including `thinking`
blocks; the service *may* recover them from tool-call IDs, but "do not rely on
automatic recovery" — if recovery is needed and fails, the request 400s. Our
`AgentLoop` already replays them verbatim.

Source: `guides/thinking_mode.md`, `api_guides/anthropic_api.md`.

## `stop_reason` — narrower than Anthropic's

```
["end_turn", "max_tokens", "stop_sequence", "tool_use", "refusal", null]
```

**Absent:** `pause_turn` (no server-side tool iteration limit to resume from)
and `model_context_window_exceeded`. `refusal` **is** present.

Our `StopReason` enum models the Anthropic set and was left intact. Keeping the
extra cases is harmless — they decode if they ever arrive and cost nothing
otherwise — and keeps the code portable. The `pause_turn` branch in `AgentLoop`
is dead code against DeepSeek; it stays rather than being deleted and
re-derived later, since the loop is correct either way.

Source: `api/create-message.md`.

## Content blocks

| Block | Status |
|---|---|
| `text` | ✓ (`cache_control`, `citations` ignored) |
| `thinking` | ✓ |
| `tool_use` | ✓ (`cache_control` ignored) |
| `tool_result` | ✓ — **`is_error` ignored** |
| `image` | flash only, user messages and `tool_result`; v4-pro substitutes `[Unsupported Image]` |
| `redacted_thinking`, `document`, `search_result` | ✗ |
| `mcp_tool_use`, `container_upload`, `code_execution_tool_result` | ✗ |
| `server_tool_use`, `web_search_tool_result` | ✓ (server-side web search) |

**`is_error` being ignored matters.** `AgentLoop` returns a failed tool as
`tool_result` with `is_error: true` so the model can route around it. DeepSeek
drops the flag — so the *text* of the result has to carry the failure, which it
already does (`"tool failed: …"`). No code change, but the error signal is now
prose rather than structure.

## Tools

Client tools: provide `name`, `input_schema`, optional `description`, and
**omit `type`**. Passing `type: "custom"` returns **422** — `type` selects a
*server* tool.

Our `ToolDefinition` already omits `type`. Worth an assertion.

`tool_choice`: `none` and `auto` supported; `any` treated as `auto` (does not
force a call); `tool` works only in non-thinking mode. `disable_parallel_tool_use`
is ignored throughout.

After an assistant message with `tool_use` blocks, the next message must be
`user` and contain a `tool_result` for **every** call, with all `tool_result`
blocks **before** any text. Our loop sends results in one user message with no
trailing text, which satisfies this.

## Ignored headers and fields

`anthropic-version` — ignored. `anthropic-beta` — ignored for `/messages`
(required only for the Files API and `file`-sourced images). `container`,
`mcp_servers`, `service_tier`, `top_k` — ignored. `metadata.user_id` is
supported and feeds rate-limit isolation.

The proxy currently sends `anthropic-version` and relays `anthropic-beta`.
Both become no-ops rather than errors, so they can stay — but the proxy should
not *require* them.

## Rate limits

Concurrency: `deepseek-flash` 2,500, `deepseek-v4-pro` 500. See
`quick_start/rate_limit.md` for isolation via `metadata.user_id` — relevant
because our proxy already identifies devices and could pass a pseudonymous id
through.

## What was not verified

- Whether Chinese public holidays are resolved server-side for peak/off-peak
  billing, and against which calendar. Cost estimates below assume they are.
- Exact behaviour when a cached unit expires mid-conversation.
- Whether `refusal` carries a `stop_details` equivalent.
- Token-count ratios for Chinese text. The docs give ~0.6 token per Chinese
  character and ~0.3 per English character as rough guides, and ship an offline
  tokenizer (`deepseek_tokenizer.zip`) — worth using before trusting any
  estimate in this repo.

## Cost model — §4.3 recomputed

§4.3's figures were sized against Anthropic (Opus $5/$25, Sonnet $3/$15 per
MTok). They are obsolete by roughly 18×. Recomputed here from the rates above
and from the **measured** prefix size, not an estimate:

| Component | Measured tokens |
|---|---:|
| System prompt (`PAgentPrompt.v1`) | ~670 |
| Tool schemas (5 tools) | ~889 |
| Profile card (§6.3 example) | ~150 |
| **Stable prefix total** | **~1,710** |

Measured via `swift test --filter PrefixSize` using DeepSeek's own ratios
(~0.6 tok per Chinese character, ~0.3 per ASCII). Note the shape: the tool
schemas cost **more** than the prompt despite the prompt being denser prose,
because ASCII JSON tokenises at half the rate of Chinese. **Trimming tool
descriptions is the cheaper lever** — the reverse of the Anthropic-era
intuition.

### Per planning turn

Assumes the stable prefix is a cache hit (it is, from the second request
onward) and the task context is fresh.

| Turn | Model | Off-peak | Peak |
|---|---|---:|---:|
| Single-day (1.7k cached + 3k fresh + 2k out) | flash | $0.0017 | $0.0033 |
| Multi-day (1.7k cached + 6k fresh + 4k out) | v4-pro | $0.0119 | $0.0238 |

### Per month, heavy user

§4.3's benchmark: 20 plans, 16 single-day + 4 multi-day.

| | Monthly |
|---|---:|
| All off-peak | **$0.074** |
| All peak | **$0.148** |
| §4.3's Anthropic figure | $1.31 |

### What this does to the quota

§4.3 concluded a subscription needs to be ≥$6.99/mo for healthy margin, and
sized the free tier at 20 requests because Opus made them expensive. Both
premises are gone.

Quota is now **100 free / 2,000 pro** per month (`wrangler.jsonc`). The
worst-case cost of the free tier — 100 plans, all routed to v4-pro, all during
peak hours — is **~$2.38/mo**, and the realistic figure is a fraction of that
because most plans route to flash and most hours are off-peak.

The cap still exists, and still matters: it bounds the damage from a leaked
device token. It is no longer the thing standing between the product and a
loss per user.

### What this does to R5

R5 was "the router misroutes a Sonnet task to Opus and costs 1.65×". The
equivalent misroute now costs **~7×** (flash → v4-pro, $0.0017 → $0.0119), so
the *ratio* got worse while the absolute numbers became small enough that the
risk is no longer material at this scale. The `modelUsed` and
`routingRationale` columns stay — they are how the claim gets checked against
real traffic rather than assumed.
