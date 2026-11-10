/**
 * R8 — prompt caching must not be silently broken by the proxy.
 *
 * DeepSeek caches automatically, but a hit requires the request to **fully
 * match** a persisted cache prefix unit (`docs/DEEPSEEK.md`). A proxy that
 * parses and re-encodes the body can change key order, collapse whitespace,
 * renormalise numbers, or unescape non-ASCII — all semantically identical, all
 * cache-destroying, and none of it reported as an error. The failure mode is a
 * silent 30× input cost on `deepseek-v4-pro`.
 *
 * So these tests assert the strongest available property: the bytes leaving
 * the proxy are *the same bytes* that arrived, and two identical client
 * requests produce two identical upstream bodies.
 *
 * The other half of R8 — that a live `cache_read_input_tokens` is actually
 * > 0 on the second call — needs the real API and belongs in an integration
 * check, not here. What is testable offline is that the proxy observes and
 * reports that field when upstream sends it; `reports cache_read_input_tokens`
 * below covers that.
 */

import { beforeEach, afterEach, describe, expect, it, vi } from 'vitest'
import {
  callWorker,
  clearKv,
  messagesRequest,
  messagesResponse,
  sseFrame,
  sseResponse,
  stubUpstream,
  UPSTREAM_MESSAGES_URL,
  type UpstreamStub,
} from './helpers'

/**
 * Deliberately adversarial: every feature here survives `JSON.parse` →
 * `JSON.stringify` *semantically* but not *byte-for-byte*.
 *
 *   · 2-space indentation and newlines → collapsed by re-encoding
 *   · `1.0` and `2.0e1`                → renormalised to `1` and `20`
 *   · `川` escapes                 → emitted as literal characters
 *   · `max_tokens` before `model`      → order is load-bearing for the hash
 */
const ADVERSARIAL_BODY = `{
  "max_tokens": 4096,
  "model": "deepseek-v4-pro",
  "stream": false,
  "temperature_placeholder": 1.0,
  "scaled": 2.0e1,
  "system": [
    {
      "type": "text",
      "text": "\\u53e3\\u5473\\uff1a\\u5ddd\\u83dc",
      "cache_control": { "type": "ephemeral" }
    }
  ],
  "messages": [{ "role": "user", "content": "now: 2026-11-10T09:00:00Z" }]
}`

let upstream: UpstreamStub

beforeEach(async () => {
  await clearKv()
})

afterEach(() => {
  upstream?.restore()
  vi.restoreAllMocks()
})

describe('byte stability', () => {
  it('forwards the request body byte-for-byte', async () => {
    upstream = stubUpstream(() => messagesResponse())

    const response = await callWorker(await messagesRequest({ body: ADVERSARIAL_BODY }))
    expect(response.status).toBe(200)

    const forwarded = new TextDecoder().decode(upstream.bodyBytes(0))
    expect(forwarded).toBe(ADVERSARIAL_BODY)
  })

  it('does not renormalise numbers, whitespace, or unicode escapes', async () => {
    upstream = stubUpstream(() => messagesResponse())
    await callWorker(await messagesRequest({ body: ADVERSARIAL_BODY }))

    const forwarded = new TextDecoder().decode(upstream.bodyBytes(0))

    // Each of these would hold if the proxy had re-serialised the body.
    expect(forwarded).toContain('1.0')
    expect(forwarded).toContain('2.0e1')
    expect(forwarded).toContain('\\u5ddd')
    expect(forwarded).toContain('\n  "max_tokens"')
    expect(forwarded).not.toContain('口味')
    expect(forwarded).not.toBe(JSON.stringify(JSON.parse(ADVERSARIAL_BODY)))
  })

  it('sends identical bytes for two identical requests', async () => {
    upstream = stubUpstream(() => messagesResponse())

    await callWorker(await messagesRequest({ body: ADVERSARIAL_BODY }))
    await callWorker(await messagesRequest({ body: ADVERSARIAL_BODY }))

    expect(upstream.calls).toHaveLength(2)
    expect(upstream.bodyBytes(1)).toEqual(upstream.bodyBytes(0))
  })

  it('preserves the cacheable prefix when only the trailing user turn differs', async () => {
    upstream = stubUpstream(() => messagesResponse())

    // The volatile part — current time — lives in the user turn. Everything
    // before it has to be byte-identical or the prefix unit will not match.
    const withTime = (now: string) =>
      ADVERSARIAL_BODY.replace('2026-11-10T09:00:00Z', now)

    await callWorker(await messagesRequest({ body: withTime('2026-11-10T09:00:00Z') }))
    await callWorker(await messagesRequest({ body: withTime('2026-11-10T17:45:12Z') }))

    const prefixOf = (index: number) => {
      const text = new TextDecoder().decode(upstream.bodyBytes(index))
      const breakpoint = text.indexOf('"messages"')
      expect(breakpoint).toBeGreaterThan(0)
      return text.slice(0, breakpoint)
    }

    expect(prefixOf(1)).toBe(prefixOf(0))
  })

  it('posts to /v1/messages with the injected API key and no device token', async () => {
    upstream = stubUpstream(() => messagesResponse())
    await callWorker(await messagesRequest({ body: ADVERSARIAL_BODY }))

    const sent = upstream.calls[0]!
    expect(sent.url).toBe(UPSTREAM_MESSAGES_URL)
    expect(sent.method).toBe('POST')
    expect(sent.headers.get('x-api-key')).toBe('sk-ant-test-key')
    expect(sent.headers.get('anthropic-version')).toBe('2023-06-01')
    // The device token must never reach the upstream.
    expect(sent.headers.get('authorization')).toBeNull()
  })
})

describe('cache accounting', () => {
  it('reports cache_read_input_tokens from a non-streaming response', async () => {
    const logged = vi.spyOn(console, 'log').mockImplementation(() => {})
    upstream = stubUpstream(() =>
      messagesResponse({ cache_read_input_tokens: 12_288, cache_creation_input_tokens: 0 }),
    )

    await callWorker(await messagesRequest({ body: ADVERSARIAL_BODY }))

    const entry = logged.mock.calls
      .map(([line]) => JSON.parse(String(line)) as Record<string, unknown>)
      .find((e) => e.kind === 'pagent.request' && e.route === '/v1/messages')

    expect(entry?.usage).toMatchObject({ cache_read_input_tokens: 12_288 })
  })

  it('reports cache_read_input_tokens from a streamed message_start', async () => {
    const logged = vi.spyOn(console, 'log').mockImplementation(() => {})
    upstream = stubUpstream(() =>
      sseResponse([
        sseFrame('message_start', {
          type: 'message_start',
          message: {
            id: 'msg_1',
            usage: {
              input_tokens: 3_000,
              cache_creation_input_tokens: 0,
              cache_read_input_tokens: 12_288,
              output_tokens: 1,
            },
          },
        }),
        sseFrame('content_block_delta', {
          type: 'content_block_delta',
          index: 0,
          delta: { type: 'text_delta', text: 'hi' },
        }),
        sseFrame('message_delta', {
          type: 'message_delta',
          delta: { stop_reason: 'end_turn' },
          usage: { output_tokens: 2_950 },
        }),
      ]),
    )

    const response = await callWorker(
      await messagesRequest({ body: ADVERSARIAL_BODY.replace('"stream": false', '"stream": true') }),
    )
    // The log only fires once the body has been drained by the client.
    await response.text()

    const entry = logged.mock.calls
      .map(([line]) => JSON.parse(String(line)) as Record<string, unknown>)
      .find((e) => e.kind === 'pagent.request' && e.route === '/v1/messages')

    expect(entry?.usage).toMatchObject({
      input_tokens: 3_000,
      cache_read_input_tokens: 12_288,
      output_tokens: 2_950,
    })
  })
})
