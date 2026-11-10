/**
 * Per-device monthly request quota (KV counters).
 *
 * KV has no atomic increment and is eventually consistent across colos, so
 * this is a **soft** cap: a device issuing concurrent requests from several
 * edge locations can overshoot by roughly the number of in-flight requests.
 * That is an acceptable trade for Phase 0 — the purpose here is to stop a
 * leaked token from running up an unbounded bill, not to bill to the request.
 *
 * Upgrade path when the cap must be exact (IMPLEMENTATION.md §4.2 lists both
 * options): move `consume` onto a Durable Object keyed by device, which
 * serialises reads and writes. The call signature below is designed to port
 * unchanged.
 */

import { monthlyLimit, type Env, type Tier } from './env'
import { rateLimited } from './errors'

export const quotaKvKey = (keyId: string, period: string) => `q:${keyId}:${period}`

/** `YYYY-MM` in UTC. Quota windows are calendar months. */
export function billingPeriod(now = new Date()): string {
  return `${now.getUTCFullYear()}-${String(now.getUTCMonth() + 1).padStart(2, '0')}`
}

/** Seconds until the next UTC month boundary — the `retry-after` for a 429. */
export function secondsUntilPeriodEnd(now = new Date()): number {
  const next = Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1)
  return Math.max(1, Math.ceil((next - now.getTime()) / 1000))
}

export interface QuotaUsage {
  used: number
  limit: number
  period: string
}

/**
 * Reserves one request against the device's monthly allowance.
 * Throws `ProxyError(429)` when the allowance is exhausted.
 */
export async function consume(
  env: Env,
  keyId: string,
  tier: Tier,
  now = new Date(),
): Promise<QuotaUsage> {
  const limit = monthlyLimit(env, tier)
  const period = billingPeriod(now)
  const key = quotaKvKey(keyId, period)

  const stored = await env.QUOTA.get(key)
  const used = Number.parseInt(stored ?? '0', 10)
  const current = Number.isFinite(used) && used > 0 ? used : 0

  if (current >= limit) {
    throw rateLimited(
      `monthly request quota exhausted (${current}/${limit} for ${period})`,
      secondsUntilPeriodEnd(now),
    )
  }

  // Expire two months out so counters self-clean without a cron job.
  await env.QUOTA.put(key, String(current + 1), { expirationTtl: 60 * 60 * 24 * 62 })
  return { used: current + 1, limit, period }
}
