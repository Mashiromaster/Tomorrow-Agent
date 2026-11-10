/**
 * PAgent stateless proxy.
 *
 * Job description, in full (IMPLEMENTATION.md §8):
 *   1. authenticate the device (App Attest → short-lived token)
 *   2. enforce quota
 *   3. inject the API key and forward
 *   4. log metadata only
 *
 * What it deliberately does not do: parse request content, persist any
 * request or response body, manage conversations, or understand anything
 * about calendars, locations, or interest tags. The agent loop lives on the
 * device (§3.1); this file is a doorway.
 */

import { Hono } from 'hono'
import {
  deviceKvKey,
  verifyAssertion,
  verifyAttestation,
  type DeviceRecord,
} from './appattest'
import { issueChallenge, verifyChallenge, CHALLENGE_TTL_SECONDS } from './challenge'
import type { Env } from './env'
import { ProxyError, badRequest, unauthorized } from './errors'
import { issueDeviceToken, verifyDeviceToken } from './jwt'
import { deviceLabel, logMetrics, type RequestMetrics } from './metrics'
import { consume } from './quota'
import { observeUsage, type StreamUsage } from './sse'
import {
  buildClientResponseHeaders,
  forwardToUpstream,
  inspectMessagesRequest,
} from './upstream'

interface Variables {
  requestId: string
  startedAt: number
  metrics: Partial<RequestMetrics>
}

const app = new Hono<{ Bindings: Env; Variables: Variables }>()

app.use('*', async (c, next) => {
  c.set('requestId', crypto.randomUUID())
  c.set('startedAt', Date.now())
  c.set('metrics', {})
  await next()
})

app.onError((error, c) => {
  const requestId = c.get('requestId') ?? crypto.randomUUID()
  const proxyError =
    error instanceof ProxyError
      ? error
      : new ProxyError(500, 'api_error', 'the proxy failed to handle this request')

  logMetrics({
    requestId,
    route: new URL(c.req.url).pathname,
    status: proxyError.status,
    latencyMs: Date.now() - (c.get('startedAt') ?? Date.now()),
    errorSource: 'proxy',
    errorType: proxyError.errorType,
    ...c.get('metrics'),
  })

  // An unexpected throw must not leak a stack trace or internal detail to the
  // client; the generic ProxyError above is what goes out.
  if (!(error instanceof ProxyError)) {
    console.log(
      JSON.stringify({ kind: 'pagent.internal_error', requestId, message: (error as Error).message }),
    )
  }

  return proxyError.toResponse(requestId)
})

async function readJsonBody(request: Request): Promise<Record<string, unknown>> {
  let parsed: unknown
  try {
    parsed = await request.json()
  } catch {
    throw badRequest('request body is not valid JSON')
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    throw badRequest('request body must be a JSON object')
  }
  return parsed as Record<string, unknown>
}

function requireString(body: Record<string, unknown>, field: string): string {
  const value = body[field]
  if (typeof value !== 'string' || value.length === 0) {
    throw badRequest(`\`${field}\` is required and must be a non-empty string`)
  }
  return value
}

// ── Health ──────────────────────────────────────────────────────────────────

app.get('/healthz', (c) => c.json({ status: 'ok' }))

// ── Enrollment: one-time, when the app generates a Secure Enclave key ───────

app.post('/v1/attest/challenge', async (c) => {
  const challenge = await issueChallenge(c.env, 'attest')
  logMetrics({
    requestId: c.get('requestId'),
    route: '/v1/attest/challenge',
    status: 200,
    latencyMs: Date.now() - c.get('startedAt'),
  })
  return c.json({ challenge, expires_in: CHALLENGE_TTL_SECONDS })
})

app.post('/v1/attest', async (c) => {
  const body = await readJsonBody(c.req.raw)
  const keyId = requireString(body, 'key_id')
  const attestation = requireString(body, 'attestation')
  const challenge = requireString(body, 'challenge')

  c.set('metrics', { device: await deviceLabel(keyId) })

  const clientData = await verifyChallenge(c.env, challenge, 'attest')

  // Enrolling an existing keyId again would reset its replay counter, so the
  // first attestation for a key wins. A reinstalled app generates a new key
  // and therefore a new keyId, so this costs legitimate clients nothing.
  if (await c.env.DEVICES.get(deviceKvKey(keyId))) {
    throw badRequest('this key is already enrolled')
  }

  const { publicKey, signCount } = await verifyAttestation({
    keyId,
    attestation,
    challenge: clientData,
    env: c.env,
  })

  const record: DeviceRecord = {
    publicKey,
    signCount,
    attestedAt: new Date().toISOString(),
    // Subscription state arrives in Phase 4 (StoreKit 2, §10 Phase 4). Until
    // then every device is on the free allowance; promotion will be a
    // server-side write to this field after receipt validation.
    tier: 'free',
  }
  await c.env.DEVICES.put(deviceKvKey(keyId), JSON.stringify(record))

  logMetrics({
    requestId: c.get('requestId'),
    route: '/v1/attest',
    status: 201,
    latencyMs: Date.now() - c.get('startedAt'),
    ...c.get('metrics'),
  })
  return c.json({ enrolled: true, tier: record.tier }, 201)
})

// ── Token exchange: an assertion in, a few minutes of access out ────────────

app.post('/v1/token/challenge', async (c) => {
  const challenge = await issueChallenge(c.env, 'assert')
  logMetrics({
    requestId: c.get('requestId'),
    route: '/v1/token/challenge',
    status: 200,
    latencyMs: Date.now() - c.get('startedAt'),
  })
  return c.json({ challenge, expires_in: CHALLENGE_TTL_SECONDS })
})

app.post('/v1/token', async (c) => {
  const body = await readJsonBody(c.req.raw)
  const keyId = requireString(body, 'key_id')
  const assertion = requireString(body, 'assertion')
  const challenge = requireString(body, 'challenge')

  c.set('metrics', { device: await deviceLabel(keyId) })

  const clientData = await verifyChallenge(c.env, challenge, 'assert')

  const stored = await c.env.DEVICES.get(deviceKvKey(keyId))
  if (!stored) throw unauthorized('device is not enrolled; attest first')
  const device = JSON.parse(stored) as DeviceRecord

  const { signCount } = await verifyAssertion({ assertion, clientData, device, env: c.env })

  // Persisting the advanced counter is what makes the next replay fail. KV is
  // eventually consistent, so two assertions racing across colos can briefly
  // see the same stored value — the window is small and bounded by the 15
  // minute token TTL. Move this record to a Durable Object when the replay
  // guarantee needs to be strict.
  await c.env.DEVICES.put(deviceKvKey(keyId), JSON.stringify({ ...device, signCount }))

  const { token, expiresAt } = await issueDeviceToken(c.env, keyId, device.tier)

  logMetrics({
    requestId: c.get('requestId'),
    route: '/v1/token',
    status: 200,
    latencyMs: Date.now() - c.get('startedAt'),
    ...c.get('metrics'),
  })
  return c.json({ token, expires_at: expiresAt, tier: device.tier })
})

// ── Messages passthrough ────────────────────────────────────────────────────

app.post('/v1/messages', async (c) => {
  const authorization = c.req.header('authorization')
  if (!authorization?.startsWith('Bearer ')) {
    throw unauthorized('missing device token; send `Authorization: Bearer <token>`')
  }
  const claims = await verifyDeviceToken(c.env, authorization.slice('Bearer '.length).trim())

  const requestId = c.get('requestId')
  const startedAt = c.get('startedAt')
  const device = await deviceLabel(claims.sub)

  // The body is read once, as bytes, and forwarded unchanged. `inspect` only
  // reads a decoded copy — see the byte-stability contract in upstream.ts.
  const body = await c.req.arrayBuffer()
  const facts = inspectMessagesRequest(body)

  const quota = await consume(c.env, claims.sub, claims.tier)

  const base: RequestMetrics = {
    requestId,
    route: '/v1/messages',
    status: 0,
    latencyMs: 0,
    device,
    model: facts.model,
    stream: facts.stream,
    quotaUsed: quota.used,
    quotaLimit: quota.limit,
  }

  const upstream = await forwardToUpstream(body, c.req.raw.headers, c.env, c.req.raw.signal)
  const headers = buildClientResponseHeaders(upstream, requestId)
  const latencyMs = Date.now() - startedAt

  if (!upstream.body) {
    logMetrics({ ...base, status: upstream.status, latencyMs, errorSource: 'upstream' })
    return new Response(null, { status: upstream.status, headers })
  }

  if (facts.stream && upstream.ok) {
    // Token accounting is scraped off the SSE frames as they pass. Chunks are
    // re-enqueued untouched, so the client sees Anthropic's bytes verbatim.
    const observed = upstream.body.pipeThrough(
      observeUsage((usage: StreamUsage) => {
        logMetrics({ ...base, status: upstream.status, latencyMs, usage })
      }),
    )
    return new Response(observed, { status: upstream.status, headers })
  }

  // Non-streaming (and error) responses: read usage from a clone so the client
  // still gets the original stream. Only the numeric usage fields are kept —
  // the parsed body is discarded with this closure and never logged.
  const mirror = upstream.clone()
  c.executionCtx.waitUntil(
    (async () => {
      let usage: StreamUsage | undefined
      try {
        const parsed = (await mirror.json()) as { usage?: StreamUsage }
        usage = parsed.usage
      } catch {
        usage = undefined
      }
      logMetrics({
        ...base,
        status: upstream.status,
        latencyMs,
        ...(upstream.ok ? {} : { errorSource: 'upstream' as const }),
        ...(usage ? { usage } : {}),
      })
    })(),
  )

  return new Response(upstream.body, { status: upstream.status, headers })
})

app.all('*', () => {
  throw new ProxyError(404, 'not_found_error', 'no such endpoint')
})

export default app
