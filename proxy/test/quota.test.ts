/**
 * Monthly quota enforcement (IMPLEMENTATION.md §4.2, R5).
 *
 * The cap exists to bound the cost of a leaked device token and to make the
 * per-user unit economics in §4.3 enforceable. It is deliberately a *soft*
 * cap — KV has no atomic increment — so the tests assert the properties that
 * actually hold: sequential requests are counted exactly, the limit is per
 * device and per tier, exhaustion produces a 429 with a usable `retry-after`,
 * and no upstream call is made once the allowance is gone.
 */

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  billingPeriod,
  consume,
  quotaKvKey,
  secondsUntilPeriodEnd,
} from '../src/quota'
import {
  callWorker,
  clearKv,
  env,
  messagesRequest,
  messagesResponse,
  stubUpstream,
  type UpstreamStub,
} from './helpers'

const BODY = JSON.stringify({
  model: 'deepseek-v4-pro',
  max_tokens: 1024,
  messages: [{ role: 'user', content: 'hi' }],
})

let upstream: UpstreamStub

beforeEach(async () => {
  await clearKv()
})

afterEach(() => {
  upstream?.restore()
  vi.restoreAllMocks()
})

describe('period keys', () => {
  it('buckets by UTC calendar month', () => {
    expect(billingPeriod(new Date('2026-11-10T09:00:00Z'))).toBe('2026-11')
    expect(billingPeriod(new Date('2026-01-01T00:00:00Z'))).toBe('2026-01')
    // A local-time December in UTC+9 is still UTC November.
    expect(billingPeriod(new Date('2026-11-30T23:59:59Z'))).toBe('2026-11')
    expect(billingPeriod(new Date('2026-12-01T00:00:00Z'))).toBe('2026-12')
  })

  it('reports seconds remaining until the next month boundary', () => {
    const oneDayOut = secondsUntilPeriodEnd(new Date('2026-11-30T00:00:00Z'))
    expect(oneDayOut).toBe(86_400)
    expect(secondsUntilPeriodEnd(new Date('2026-11-30T23:59:59Z'))).toBe(1)
  })

  it('namespaces counters per device and period', () => {
    expect(quotaKvKey('abc', '2026-11')).toBe('q:abc:2026-11')
    expect(quotaKvKey('abc', '2026-12')).not.toBe(quotaKvKey('abc', '2026-11'))
  })
})

describe('consume', () => {
  it('counts up to the tier limit, then refuses', async () => {
    // FREE_MONTHLY_REQUESTS is 3 in the test bindings.
    for (let n = 1; n <= 3; n++) {
      const usage = await consume(env, 'device-a', 'free')
      expect(usage).toMatchObject({ used: n, limit: 3 })
    }

    await expect(consume(env, 'device-a', 'free')).rejects.toThrow(/quota exhausted/)
  })

  it('applies the pro allowance independently of free', async () => {
    for (let n = 0; n < 4; n++) await consume(env, 'device-pro', 'pro')
    const usage = await consume(env, 'device-pro', 'pro')
    expect(usage).toMatchObject({ used: 5, limit: 10 })
  })

  it('keeps counters separate per device', async () => {
    await consume(env, 'device-a', 'free')
    await consume(env, 'device-a', 'free')
    const other = await consume(env, 'device-b', 'free')
    expect(other.used).toBe(1)
  })

  it('starts a fresh allowance in a new period', async () => {
    const november = new Date('2026-11-10T00:00:00Z')
    for (let n = 0; n < 3; n++) await consume(env, 'device-a', 'free', november)
    await expect(consume(env, 'device-a', 'free', november)).rejects.toThrow(/exhausted/)

    const december = new Date('2026-12-01T00:00:00Z')
    const usage = await consume(env, 'device-a', 'free', december)
    expect(usage).toMatchObject({ used: 1, period: '2026-12' })
  })

  it('treats a corrupted counter as zero rather than failing open on a huge value', async () => {
    await env.QUOTA.put(quotaKvKey('device-a', billingPeriod()), 'not-a-number')
    const usage = await consume(env, 'device-a', 'free')
    expect(usage.used).toBe(1)
  })
})

describe('/v1/messages quota enforcement', () => {
  it('returns 429 with retry-after and makes no upstream call once exhausted', async () => {
    upstream = stubUpstream(() => messagesResponse())

    // Free tier: 3 allowed.
    for (let n = 0; n < 3; n++) {
      const ok = await callWorker(
        await messagesRequest({ body: BODY, keyId: 'device-limited', tier: 'free' }),
      )
      expect(ok.status).toBe(200)
    }
    expect(upstream.calls).toHaveLength(3)

    const blocked = await callWorker(
      await messagesRequest({ body: BODY, keyId: 'device-limited', tier: 'free' }),
    )

    expect(blocked.status).toBe(429)
    expect(Number(blocked.headers.get('retry-after'))).toBeGreaterThan(0)
    expect(blocked.headers.get('x-pagent-error-source')).toBe('proxy')

    const body = (await blocked.json()) as { type: string; error: { type: string } }
    expect(body.type).toBe('error')
    expect(body.error.type).toBe('rate_limit_error')

    // The API key was never spent on a request that should not have happened.
    expect(upstream.calls).toHaveLength(3)
  })

  it('charges quota to the token subject, not the connection', async () => {
    upstream = stubUpstream(() => messagesResponse())

    for (let n = 0; n < 3; n++) {
      await callWorker(await messagesRequest({ body: BODY, keyId: 'device-x', tier: 'free' }))
    }

    // A different device still has its own full allowance.
    const other = await callWorker(
      await messagesRequest({ body: BODY, keyId: 'device-y', tier: 'free' }),
    )
    expect(other.status).toBe(200)
  })

  it('records the quota position in the metadata log', async () => {
    const logged = vi.spyOn(console, 'log').mockImplementation(() => {})
    upstream = stubUpstream(() => messagesResponse())

    await callWorker(await messagesRequest({ body: BODY, keyId: 'device-z', tier: 'free' }))

    const entry = logged.mock.calls
      .map(([line]) => JSON.parse(String(line)) as Record<string, unknown>)
      .find((e) => e.route === '/v1/messages')

    expect(entry).toMatchObject({ quotaUsed: 1, quotaLimit: 3, model: 'deepseek-v4-pro' })
  })
})
