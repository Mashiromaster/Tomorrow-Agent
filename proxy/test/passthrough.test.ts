/**
 * Passthrough behaviour and the privacy boundary.
 *
 * Two things are under test:
 *
 *   1. The narrow job description in IMPLEMENTATION.md §8 — authenticate,
 *      enforce quota, inject the key, forward. Anything outside that (an
 *      unlisted model, a body large enough to be media, a non-streaming
 *      request that will outlive the HTTP timeout) is refused at the door.
 *   2. The §4.2 logging commitment: **only metadata**. The privacy narrative
 *      in §9 rests on it, so `does not log any request or response content`
 *      asserts it directly against every line this Worker emits.
 */

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  ALLOWED_MODELS,
  NON_STREAMING_MAX_TOKENS_CEILING,
  buildUpstreamHeaders,
  inspectMessagesRequest,
} from '../src/upstream'
import {
  callWorker,
  clearKv,
  env,
  messagesRequest,
  messagesResponse,
  sseFrame,
  sseResponse,
  stubUpstream,
  type UpstreamStub,
} from './helpers'

const bodyOf = (overrides: Record<string, unknown> = {}) =>
  JSON.stringify({
    model: 'deepseek-v4-pro',
    max_tokens: 1024,
    messages: [{ role: 'user', content: 'hi' }],
    ...overrides,
  })

let upstream: UpstreamStub

beforeEach(async () => {
  await clearKv()
})

afterEach(() => {
  upstream?.restore()
  vi.restoreAllMocks()
})

describe('authentication gate', () => {
  it('refuses a request with no device token', async () => {
    upstream = stubUpstream(() => messagesResponse())

    const response = await callWorker(
      new Request('https://proxy.test/v1/messages', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: bodyOf(),
      }),
    )

    expect(response.status).toBe(401)
    expect(upstream.calls).toHaveLength(0)
  })

  it('refuses a forged token', async () => {
    upstream = stubUpstream(() => messagesResponse())

    const response = await callWorker(
      await messagesRequest({ body: bodyOf(), token: 'aaa.bbb.ccc' }),
    )

    expect(response.status).toBe(401)
    expect(upstream.calls).toHaveLength(0)
  })
})

describe('request validation', () => {
  it('permits only the two models §4.3 budgets for', async () => {
    // Two, not three. §7.1's Sonnet and Haiku roles both land on
    // `deepseek-flash`, so the allowlist shrank with the tiering.
    expect([...ALLOWED_MODELS].sort()).toEqual(['deepseek-flash', 'deepseek-v4-pro'])
  })

  it('rejects a claude-* name even though the upstream would map it', async () => {
    // The Anthropic-compatible endpoint accepts `claude-*` and maps it
    // (`claude-opus*` → v4-pro, other `claude*` → flash). Allowing that
    // through would mean the proxy's cost ceiling no longer matches the model
    // that actually ran, and `metrics.model` would log a name DeepSeek never
    // served (`docs/DEEPSEEK.md`).
    upstream = stubUpstream(() => messagesResponse())

    const response = await callWorker(
      await messagesRequest({ body: bodyOf({ model: 'claude-opus-4-8' }) }),
    )

    expect(response.status).toBe(400)
    expect(upstream.calls).toHaveLength(0)
  })

  it('rejects an unlisted model before spending the API key', async () => {
    upstream = stubUpstream(() => messagesResponse())

    const response = await callWorker(
      await messagesRequest({ body: bodyOf({ model: 'deepseek-reasoner' }) }),
    )

    expect(response.status).toBe(400)
    const body = (await response.json()) as { error: { message: string } }
    expect(body.error.message).toMatch(/not permitted by this proxy/)
    expect(upstream.calls).toHaveLength(0)
  })

  it('requires streaming above the non-streaming max_tokens ceiling', async () => {
    upstream = stubUpstream(() => messagesResponse())

    const tooBig = await callWorker(
      await messagesRequest({ body: bodyOf({ max_tokens: 64_000 }) }),
    )
    expect(tooBig.status).toBe(400)
    const body = (await tooBig.json()) as { error: { message: string } }
    expect(body.error.message).toMatch(/requires/)
    expect(upstream.calls).toHaveLength(0)

    // The same max_tokens is fine once the client asks for a stream.
    const streamed = await callWorker(
      await messagesRequest({ body: bodyOf({ max_tokens: 64_000, stream: true }) }),
    )
    expect(streamed.status).toBe(200)
  })

  it('accepts the ceiling itself', () => {
    const facts = inspectMessagesRequest(
      new TextEncoder().encode(bodyOf({ max_tokens: NON_STREAMING_MAX_TOKENS_CEILING })).buffer as ArrayBuffer,
    )
    expect(facts).toEqual({ model: 'deepseek-v4-pro', stream: false })
  })

  it('rejects a body that is empty, not JSON, or not an object', async () => {
    upstream = stubUpstream(() => messagesResponse())

    for (const body of ['', 'not json', '[1,2,3]']) {
      const response = await callWorker(await messagesRequest({ body }))
      expect(response.status).toBe(400)
    }
    expect(upstream.calls).toHaveLength(0)
  })

  it('rejects a body with no model', async () => {
    upstream = stubUpstream(() => messagesResponse())
    const response = await callWorker(
      await messagesRequest({ body: JSON.stringify({ max_tokens: 10, messages: [] }) }),
    )
    expect(response.status).toBe(400)
    const body = (await response.json()) as { error: { message: string } }
    expect(body.error.message).toMatch(/`model` is required/)
  })
})

describe('header handling', () => {
  it('injects the API key and never forwards the device token', () => {
    const headers = buildUpstreamHeaders(
      new Headers({ authorization: 'Bearer device-token', 'anthropic-beta': 'some-beta-2026-01-01' }),
      env,
    )

    expect(headers.get('x-api-key')).toBe('sk-ant-test-key')
    expect(headers.get('authorization')).toBeNull()
    expect(headers.get('anthropic-version')).toBe('2023-06-01')
  })

  it('relays anthropic-beta verbatim so beta opt-ins need no proxy deploy', () => {
    const headers = buildUpstreamHeaders(
      new Headers({ 'anthropic-beta': 'task-budgets-2026-03-13,context-management-2025-06-27' }),
      env,
    )
    expect(headers.get('anthropic-beta')).toBe(
      'task-budgets-2026-03-13,context-management-2025-06-27',
    )
  })

  it('honours a client-supplied anthropic-version', () => {
    const headers = buildUpstreamHeaders(new Headers({ 'anthropic-version': '2099-01-01' }), env)
    expect(headers.get('anthropic-version')).toBe('2099-01-01')
  })

  it('relays rate-limit and request-id headers back to the client', async () => {
    upstream = stubUpstream(
      () =>
        new Response(JSON.stringify({ usage: {} }), {
          status: 200,
          headers: {
            'content-type': 'application/json',
            'request-id': 'req_abc',
            'anthropic-ratelimit-requests-remaining': '42',
            'set-cookie': 'should-not-be-relayed=1',
          },
        }),
    )

    const response = await callWorker(await messagesRequest({ body: bodyOf() }))

    expect(response.headers.get('request-id')).toBe('req_abc')
    expect(response.headers.get('anthropic-ratelimit-requests-remaining')).toBe('42')
    expect(response.headers.get('x-pagent-request-id')).toBeTruthy()
    expect(response.headers.get('set-cookie')).toBeNull()
  })
})

describe('upstream errors', () => {
  it('passes an upstream error through and labels its source', async () => {
    upstream = stubUpstream(
      () =>
        new Response(
          JSON.stringify({
            type: 'error',
            error: { type: 'overloaded_error', message: 'Overloaded' },
          }),
          { status: 529, headers: { 'content-type': 'application/json' } },
        ),
    )

    const response = await callWorker(await messagesRequest({ body: bodyOf() }))

    expect(response.status).toBe(529)
    expect(response.headers.get('x-pagent-error-source')).toBe('upstream')
    const body = (await response.json()) as { error: { type: string } }
    expect(body.error.type).toBe('overloaded_error')
  })

  it('reports an unreachable upstream as a 502 in the error envelope', async () => {
    upstream = stubUpstream(() => {
      throw new Error('connection refused')
    })

    const response = await callWorker(await messagesRequest({ body: bodyOf() }))

    expect(response.status).toBe(502)
    expect(response.headers.get('x-pagent-error-source')).toBe('proxy')
    const body = (await response.json()) as {
      type: string
      error: { type: string }
      request_id: string
    }
    expect(body.type).toBe('error')
    expect(body.error.type).toBe('api_error')
    expect(body.request_id).toBeTruthy()
  })

  it('returns the Anthropic error envelope on an unknown route', async () => {
    const response = await callWorker(new Request('https://proxy.test/nope'))
    expect(response.status).toBe(404)
    const body = (await response.json()) as { error: { type: string } }
    expect(body.error.type).toBe('not_found_error')
  })

  it('answers the health check without authentication', async () => {
    const response = await callWorker(new Request('https://proxy.test/healthz'))
    expect(response.status).toBe(200)
    expect(await response.json()).toEqual({ status: 'ok' })
  })
})

describe('privacy boundary', () => {
  it('does not log any request or response content', async () => {
    const logged = vi.spyOn(console, 'log').mockImplementation(() => {})

    // Distinctive strings that would be unmistakable if they leaked.
    const promptMarker = 'SECRET_PROFILE_CARD_口味川菜_7a3f'
    const completionMarker = 'SECRET_COMPLETION_TEXT_9b2e'

    upstream = stubUpstream(
      () =>
        new Response(
          JSON.stringify({
            id: 'msg_1',
            content: [{ type: 'text', text: completionMarker }],
            usage: { input_tokens: 1, output_tokens: 1 },
          }),
          { status: 200, headers: { 'content-type': 'application/json' } },
        ),
    )

    const response = await callWorker(
      await messagesRequest({
        body: bodyOf({ messages: [{ role: 'user', content: promptMarker }] }),
      }),
    )
    // The client still receives the completion in full.
    expect(await response.text()).toContain(completionMarker)

    const allOutput = logged.mock.calls.map(([line]) => String(line)).join('\n')
    expect(allOutput).not.toContain(promptMarker)
    expect(allOutput).not.toContain(completionMarker)
    expect(allOutput).not.toContain('口味')
    // Nor the API key, which would be just as bad in a log aggregator.
    expect(allOutput).not.toContain('sk-ant-test-key')
  })

  it('identifies the device pseudonymously, never by keyId', async () => {
    const logged = vi.spyOn(console, 'log').mockImplementation(() => {})
    upstream = stubUpstream(() => messagesResponse())

    const keyId = 'raw-key-id-that-must-not-appear'
    await callWorker(await messagesRequest({ body: bodyOf(), keyId }))

    const allOutput = logged.mock.calls.map(([line]) => String(line)).join('\n')
    expect(allOutput).not.toContain(keyId)

    const entry = logged.mock.calls
      .map(([line]) => JSON.parse(String(line)) as Record<string, unknown>)
      .find((e) => e.route === '/v1/messages')
    // A stable 64-bit prefix: groupable for cost attribution, not reversible.
    expect(entry?.device).toMatch(/^[0-9a-f]{16}$/)
  })

  it('logs latency, model, status, and stream flag for cost attribution', async () => {
    const logged = vi.spyOn(console, 'log').mockImplementation(() => {})
    upstream = stubUpstream(() =>
      sseResponse([
        sseFrame('message_start', {
          type: 'message_start',
          message: { usage: { input_tokens: 7, output_tokens: 1 } },
        }),
        sseFrame('message_delta', {
          type: 'message_delta',
          delta: { stop_reason: 'end_turn' },
          usage: { output_tokens: 11 },
        }),
      ]),
    )

    const response = await callWorker(
      await messagesRequest({ body: bodyOf({ stream: true, model: 'deepseek-flash' }) }),
    )
    await response.text()

    const entry = logged.mock.calls
      .map(([line]) => JSON.parse(String(line)) as Record<string, unknown>)
      .find((e) => e.route === '/v1/messages')

    expect(entry).toMatchObject({
      kind: 'pagent.request',
      status: 200,
      model: 'deepseek-flash',
      stream: true,
    })
    expect(typeof entry?.latencyMs).toBe('number')
    expect(entry?.usage).toMatchObject({ input_tokens: 7, output_tokens: 11 })
  })
})
