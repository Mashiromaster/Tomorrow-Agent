/**
 * DeepSeek Messages API passthrough (Anthropic-compatible endpoint).
 *
 * ## The byte-stability contract (IMPLEMENTATION.md R8)
 *
 * DeepSeek caches context on disk automatically, with no `cache_control`
 * markers — but a hit requires the request to **fully match** a persisted
 * *cache prefix unit* (`docs/DEEPSEEK.md`). So re-serialising the body here —
 * even producing semantically identical JSON — can reorder keys or change
 * number formatting and silently zero the cache. Every request would then pay
 * cache-miss price, which on `deepseek-v4-pro` is 30× the cache-hit rate, with
 * no error to notice.
 *
 * So the proxy forwards **the exact bytes it received**. It does parse a copy
 * to read `model` / `stream` / `max_tokens` for the allowlist and metadata
 * log, but that parsed object is never re-encoded: `fetch` is handed the
 * original `ArrayBuffer`. Keeping that invariant is the single most important
 * property of this file, and `test/cache-stability.test.ts` asserts it.
 */

import type { Env } from './env'
import { badRequest, tooLarge, upstreamUnavailable } from './errors'

/**
 * The models §4.3 budgets for. An allowlist bounds the cost of a stolen token.
 *
 * Only real DeepSeek names. The Anthropic-compatible endpoint also accepts
 * `claude-*` names and maps them (`claude-opus*` → v4-pro, other `claude*` →
 * flash), but relying on that would hide which model actually ran — and the
 * mapping is a convenience for tools with hardcoded Claude names, not a
 * contract.
 */
export const ALLOWED_MODELS: ReadonlySet<string> = new Set([
  'deepseek-v4-pro',
  'deepseek-flash',
])

/** Payload is a ≤500-token profile card plus task context — never media. */
export const MAX_REQUEST_BYTES = 2 * 1024 * 1024

/**
 * Above this, a non-streaming request risks an HTTP timeout before the model
 * finishes (§7.3). Failing fast here is kinder than a 524 that looks like a
 * proxy bug.
 */
export const NON_STREAMING_MAX_TOKENS_CEILING = 16_000

/**
 * Sent for compatibility, though DeepSeek ignores it (`docs/DEEPSEEK.md`).
 * Kept because it costs nothing and keeps the request valid if it is ever
 * pointed back at a real Anthropic endpoint.
 */
const DEFAULT_ANTHROPIC_VERSION = '2023-06-01' 

/** Response headers worth relaying. Everything else (cookies, CF internals) is dropped. */
const PASSTHROUGH_RESPONSE_HEADERS = [
  'content-type',
  'cache-control',
  'retry-after',
  'request-id',
  'anthropic-organization-id',
]

export interface MessagesRequestFacts {
  model: string
  stream: boolean
}

/**
 * Reads the request-shaping fields without mutating the body.
 * `body` stays the caller's original bytes.
 */
export function inspectMessagesRequest(body: ArrayBuffer): MessagesRequestFacts {
  if (body.byteLength === 0) throw badRequest('request body is empty')
  if (body.byteLength > MAX_REQUEST_BYTES) {
    throw tooLarge(`request body exceeds ${MAX_REQUEST_BYTES} bytes`)
  }

  let parsed: Record<string, unknown>
  try {
    parsed = JSON.parse(new TextDecoder().decode(body)) as Record<string, unknown>
  } catch {
    throw badRequest('request body is not valid JSON')
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    throw badRequest('request body must be a JSON object')
  }

  const { model, stream, max_tokens: maxTokens } = parsed
  if (typeof model !== 'string') throw badRequest('`model` is required and must be a string')
  if (!ALLOWED_MODELS.has(model)) {
    throw badRequest(`model \`${model}\` is not permitted by this proxy`)
  }

  const isStreaming = stream === true
  if (!isStreaming && typeof maxTokens === 'number' && maxTokens > NON_STREAMING_MAX_TOKENS_CEILING) {
    throw badRequest(
      `max_tokens above ${NON_STREAMING_MAX_TOKENS_CEILING} requires \`"stream": true\``,
    )
  }

  return { model, stream: isStreaming }
}

/**
 * Builds the upstream headers. The device token is **not** forwarded; the API
 * key is injected here and exists nowhere else in the system.
 *
 * `anthropic-beta` is relayed verbatim so the device controls its own beta
 * opt-ins without a proxy deploy, though DeepSeek ignores it for `/messages`.
 * Thinking and `output_config.effort` need no beta header on either model.
 */
export function buildUpstreamHeaders(clientHeaders: Headers, env: Env): Headers {
  const headers = new Headers({
    'content-type': 'application/json',
    'x-api-key': env.DEEPSEEK_API_KEY,
    'anthropic-version': clientHeaders.get('anthropic-version') ?? DEFAULT_ANTHROPIC_VERSION,
  })

  // DeepSeek ignores `anthropic-beta` for /messages (it matters only for the
  // Files API). Relayed anyway so the device keeps control of its own opt-ins
  // without a proxy deploy, and so nothing breaks if the upstream changes.
  const beta = clientHeaders.get('anthropic-beta')
  if (beta) headers.set('anthropic-beta', beta)

  const accept = clientHeaders.get('accept')
  if (accept) headers.set('accept', accept)

  return headers
}

export function buildClientResponseHeaders(upstream: Response, requestId: string): Headers {
  const headers = new Headers()
  for (const name of PASSTHROUGH_RESPONSE_HEADERS) {
    const value = upstream.headers.get(name)
    if (value) headers.set(name, value)
  }
  // Rate-limit headers let the client back off without guessing.
  upstream.headers.forEach((value, name) => {
    if (name.toLowerCase().startsWith('anthropic-ratelimit-')) headers.set(name, value)
  })
  headers.set('x-pagent-request-id', requestId)
  if (!upstream.ok) headers.set('x-pagent-error-source', 'upstream')
  return headers
}

/** Forwards the original bytes to the upstream `/v1/messages`. */
export async function forwardToUpstream(
  body: ArrayBuffer,
  clientHeaders: Headers,
  env: Env,
  signal: AbortSignal,
): Promise<Response> {
  try {
    return await fetch(`${env.UPSTREAM_BASE_URL}/v1/messages`, {
      method: 'POST',
      headers: buildUpstreamHeaders(clientHeaders, env),
      body, // original ArrayBuffer — never a re-serialised object
      signal,
    })
  } catch (cause) {
    throw upstreamUnavailable(`could not reach the DeepSeek API: ${(cause as Error).message}`)
  }
}
